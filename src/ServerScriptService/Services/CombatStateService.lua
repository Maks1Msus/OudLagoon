-- CombatStateService контролирует, что персонажу РАЗРЕШЕНО делать прямо сейчас.
-- Он хранит состояние, фазу атаки, кулдауны и защищает от устаревших таймеров.
-- Сам он боевых действий не выполняет (поиск целей, урон: это CombatService)
-- и не зависит от CombatService, поэтому циклических зависимостей нет.
--
-- ЭТАП 1 (фундамент): хранение, переходы, защита от устаревших таймеров,
-- проверки CanAttack/CanBlock/CanDodge, SetDead/ResetCharacter, подписки на события.
-- ЭТАП 2 (атака): StartAttack (Startup -> Active -> Recovery -> Idle), строгий порядок фаз,
-- учёт попаданий (RegisterHit), проверка окна попаданий (IsAttackActive).
-- Следующие этапы добавят: ApplyStun, StartBlock/StopBlock, StartDodge, ApplyDamage.
-- Они строятся на Transition() и Delay() из этого файла.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(
    ReplicatedStorage.Shared.Config.CombatConfig
)

local CombatStateConfig = require(
    ReplicatedStorage.Shared.Config.CombatStateConfig
)

local CombatStates = require(
    ReplicatedStorage.Shared.Constants.CombatStates
)

local CombatStateService = {}

local State = CombatStates
local Phase = CombatStates.AttackPhases

local function Log(...)
    if CombatConfig.DebugLogging then
        print("[CombatStateService]", ...)
    end
end

-- ТАБЛИЦЫ ---------------------------------------------------------------

local function ToSet(list)
    local set = {}

    for _, value in pairs(list) do
        set[value] = true
    end

    return set
end

local ValidStates = {}

for _, value in pairs(CombatStates) do
    if type(value) == "string" then
        ValidStates[value] = true
    end
end

local ValidPhases = ToSet(Phase)

-- Фазы идут строго по порядку: перескочить через фазу или вернуться назад нельзя.
local NextPhase = {
    [Phase.Startup] = Phase.Active,
    [Phase.Active] = Phase.Recovery,
}

-- Допустимые переходы. Из Dead выхода нет: только ResetCharacter (новый персонаж).
-- Переход в то же состояние не допускается (повторное оглушение обновляет таймер
-- отдельной логикой на этапе 3, а не переходом).
-- Blocking -> Dodging разрешён: уклонение сразу завершает блок, отпускать его не нужно.
-- Dodging -> Blocking во время рывка и Blocking -> Attacking запрещены (сначала закончить блок).
local AllowedTransitions = {
    [State.Idle] = ToSet({ State.Attacking, State.Blocking, State.Dodging, State.Stunned, State.Dead }),
    [State.Attacking] = ToSet({ State.Idle, State.Blocking, State.Dodging, State.Stunned, State.Dead }),
    [State.Blocking] = ToSet({ State.Idle, State.Dodging, State.Stunned, State.Dead }),
    [State.Dodging] = ToSet({ State.Idle, State.Stunned, State.Dead }),
    [State.Stunned] = ToSet({ State.Idle, State.Dead }),
    [State.Dead] = ToSet({}),
}

-- В какое поле записи складываются данные состояния
local SubRecordKey = {
    [State.Attacking] = "Attack",
    [State.Blocking] = "Block",
    [State.Dodging] = "Dodge",
    [State.Stunned] = "Stun",
}

-- ХРАНИЛИЩЕ -------------------------------------------------------------

-- [character] = запись. Слабые ключи: запись исчезает вместе с удалённым персонажем.
-- Ключ именно персонаж (а не игрок), поэтому после респавна состояние снова Idle.
local Records = setmetatable({}, { __mode = "k" })

-- Идентификаторы глобальные, а не по персонажам: так таймер, созданный до сброса или
-- респавна, никогда не совпадёт с идентификатором новой записи.
local transitionCounter = 0
local attackCounter = 0

local function NewRecord()
    transitionCounter += 1

    return {
        State = State.Idle,
        StateStartedAt = os.clock(),
        StateEndsAt = nil,

        -- Подзаписи существуют только пока активно соответствующее состояние
        Attack = nil, -- { AttackId, Phase, PhaseStartedAt, PhaseEndsAt, HitTargets, ... }
        Block = nil,
        Dodge = nil,
        Stun = nil,

        -- Кулдауны переживают смену состояния
        Cooldowns = { Dodge = 0 },

        TransitionId = transitionCounter,
    }
end

local function GetRecord(character)
    assert(character ~= nil, "[CombatStateService] character is required")

    local record = Records[character]

    if not record then
        record = NewRecord()
        Records[character] = record
    end

    return record
end

-- СОБЫТИЯ ---------------------------------------------------------------

local function CreateSignal()
    local listeners = {}
    local signal = {}

    function signal.Connect(callback)
        table.insert(listeners, callback)

        return function()
            local index = table.find(listeners, callback)

            if index then
                table.remove(listeners, index)
            end
        end
    end

    function signal.Fire(...)
        -- Копия списка: подписчик может отписаться прямо во время обработки
        for _, listener in ipairs(table.clone(listeners)) do
            local ok, err = pcall(listener, ...)

            if not ok then
                warn("[CombatStateService] Listener error:", err)
            end
        end
    end

    return signal
end

local StateChanged = CreateSignal()
local AttackPhaseChanged = CreateSignal()

-- callback(character, newState, oldState, transitionId). Возвращает функцию отписки.
function CombatStateService:OnStateChanged(callback)
    return StateChanged.Connect(callback)
end

-- callback(character, phase, attackId). Возвращает функцию отписки.
function CombatStateService:OnAttackPhaseChanged(callback)
    return AttackPhaseChanged.Connect(callback)
end

-- ПРОВЕРКИ --------------------------------------------------------------

-- Можно ли сейчас перейти в newState. Возвращает true либо false, <причина>.
local function CanEnter(record, newState, now)
    local allowed = AllowedTransitions[record.State]

    if not allowed or not allowed[newState] then
        return false, "TransitionNotAllowed"
    end

    -- Во время атаки блок и уклонение разрешены только в Recovery и только если
    -- это разрешено настройками оружия (копируются в запись при начале атаки).
    if record.State == State.Attacking
        and (newState == State.Blocking or newState == State.Dodging)
    then
        local attack = record.Attack

        if not attack or attack.Phase ~= Phase.Recovery then
            return false, "AttackPhase"
        end

        local permitted = (newState == State.Blocking and attack.CanBlockDuringRecovery)
            or (newState == State.Dodging and attack.CanDodgeDuringRecovery)

        if not permitted then
            return false, "WeaponForbids"
        end
    end

    if newState == State.Dodging and now < record.Cooldowns.Dodge then
        return false, "Cooldown"
    end

    return true
end

-- Все Can* возвращают true либо false, <причина>.
function CombatStateService:CanAttack(character)
    return CanEnter(GetRecord(character), State.Attacking, os.clock())
end

function CombatStateService:CanBlock(character)
    return CanEnter(GetRecord(character), State.Blocking, os.clock())
end

function CombatStateService:CanDodge(character)
    return CanEnter(GetRecord(character), State.Dodging, os.clock())
end

function CombatStateService:GetState(character)
    return GetRecord(character).State
end

-- Фаза текущей атаки или nil, если персонаж не атакует.
function CombatStateService:GetAttackPhase(character)
    local attack = GetRecord(character).Attack

    return attack and attack.Phase or nil
end

function CombatStateService:GetAttackId(character)
    local attack = GetRecord(character).Attack

    return attack and attack.AttackId or nil
end

-- ТАЙМЕРЫ ---------------------------------------------------------------

-- Выполняет callback через seconds, но только если персонаж всё ещё находится в том же
-- состоянии, в котором был при вызове (тот же вход в состояние). Любой переход
-- (оглушение, смерть, конец атаки) или сброс делает все такие таймеры недействительными,
-- поэтому устаревший таймер не может нанести урон или изменить новое состояние.
function CombatStateService:Delay(character, seconds, callback)
    local record = GetRecord(character)
    local transitionId = record.TransitionId

    task.delay(seconds, function()
        if Records[character] == record and record.TransitionId == transitionId then
            callback()
        end
    end)
end

-- ПЕРЕХОДЫ --------------------------------------------------------------

-- Единственное место, где меняется State.
-- options (необязательно):
--   Duration - через сколько секунд состояние само завершится переходом в Idle
--              (для Stunned и Dodging; Blocking держится, Attacking завершают фазы);
--   Data     - данные подзаписи (для Attacking: Phase, CanBlockDuringRecovery,
--              CanDodgeDuringRecovery, ...).
-- Возвращает true, <TransitionId> либо false, <причина>.
function CombatStateService:Transition(character, newState, options)
    if not ValidStates[newState] then
        return false, "UnknownState"
    end

    local record = GetRecord(character)
    local now = os.clock()

    local allowed, reason = CanEnter(record, newState, now)

    if not allowed then
        return false, reason
    end

    options = options or {}

    local oldState = record.State
    local oldKey = SubRecordKey[oldState]

    if oldKey then
        record[oldKey] = nil
    end

    transitionCounter += 1

    record.TransitionId = transitionCounter
    record.State = newState
    record.StateStartedAt = now
    record.StateEndsAt = options.Duration and (now + options.Duration) or nil

    local newKey = SubRecordKey[newState]

    if newKey then
        local data = options.Data and table.clone(options.Data) or {}

        if newState == State.Attacking then
            attackCounter += 1

            data.AttackId = attackCounter
            data.Phase = data.Phase or Phase.Startup
            data.PhaseStartedAt = now
            data.PhaseEndsAt = nil
            data.HitTargets = {} -- кого уже поразил этот удар (используется на этапе 2)
        end

        record[newKey] = data
    end

    -- Кулдаун уклонения отсчитывается от его начала и не зависит от состояния
    if newState == State.Dodging then
        record.Cooldowns.Dodge = now + CombatStateConfig.Dodge.Cooldown
    end

    if options.Duration then
        self:Delay(character, options.Duration, function()
            self:Transition(character, State.Idle)
        end)
    end

    Log(character.Name, oldState, "->", newState, "#" .. record.TransitionId)

    StateChanged.Fire(character, newState, oldState, record.TransitionId)

    return true, record.TransitionId
end

-- Меняет фазу текущей атаки. attackId защищает от устаревших вызовов: если атака уже
-- прервана или началась другая, фаза не меняется и возвращается false.
-- Допустим только следующий по порядку шаг: Startup -> Active -> Recovery.
function CombatStateService:SetAttackPhase(character, attackId, phase, duration)
    local record = Records[character]
    local attack = record and record.Attack

    if not attack or record.State ~= State.Attacking or attack.AttackId ~= attackId then
        return false, "StaleAttack"
    end

    if not ValidPhases[phase] then
        return false, "UnknownPhase"
    end

    if NextPhase[attack.Phase] ~= phase then
        return false, "InvalidPhaseOrder"
    end

    local now = os.clock()

    attack.Phase = phase
    attack.PhaseStartedAt = now
    attack.PhaseEndsAt = duration and (now + duration) or nil

    Log(character.Name, "attack", attackId, "phase", phase)

    AttackPhaseChanged.Fire(character, phase, attackId)

    return true
end

local function IsFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Параметры фаз (CombatConfig.Weapons[...].AttackTiming): Active обязана быть > 0.
local function IsValidTiming(timing)
    return type(timing) == "table"
        and IsFiniteNumber(timing.Startup) and timing.Startup >= 0
        and IsFiniteNumber(timing.Active) and timing.Active > 0
        and IsFiniteNumber(timing.Recovery) and timing.Recovery >= 0
end

-- Запускает атаку: Attacking (Startup) -> Active -> Recovery -> Idle.
-- Всей последовательностью управляет сервер. Таймеры привязаны к входу в состояние,
-- поэтому любое прерывание (оглушение, смерть, уклонение из Recovery) обрывает цепочку,
-- а устаревшие шаги ничего не меняют и не наносят урона.
-- Возвращает true, <AttackId> либо false, <причина>.
function CombatStateService:StartAttack(character, timing)
    if not IsValidTiming(timing) then
        return false, "InvalidTiming"
    end

    local ok, reason = self:Transition(character, State.Attacking, {
        Data = {
            Phase = Phase.Startup,
            CanBlockDuringRecovery = timing.CanBlockDuringRecovery == true,
            CanDodgeDuringRecovery = timing.CanDodgeDuringRecovery == true,
        },
    })

    if not ok then
        return false, reason
    end

    local attack = Records[character].Attack
    local attackId = attack.AttackId

    attack.PhaseEndsAt = os.clock() + timing.Startup

    self:Delay(character, timing.Startup, function()
        if not self:SetAttackPhase(character, attackId, Phase.Active, timing.Active) then
            return
        end

        self:Delay(character, timing.Active, function()
            if not self:SetAttackPhase(character, attackId, Phase.Recovery, timing.Recovery) then
                return
            end

            self:Delay(character, timing.Recovery, function()
                self:Transition(character, State.Idle)
            end)
        end)
    end)

    return true, attackId
end

-- true, пока атака attackId идёт и находится в фазе Active (окно регистрации попаданий).
function CombatStateService:IsAttackActive(character, attackId)
    local record = Records[character]
    local attack = record and record.Attack

    return attack ~= nil
        and record.State == State.Attacking
        and attack.AttackId == attackId
        and attack.Phase == Phase.Active
end

-- Фиксирует попадание по цели. Возвращает true только для ПЕРВОГО попадания по этой
-- цели в рамках данного удара и только в фазе Active; иначе false, <причина>.
function CombatStateService:RegisterHit(character, attackId, target)
    if not self:IsAttackActive(character, attackId) then
        return false, "NotActive"
    end

    local hitTargets = Records[character].Attack.HitTargets

    if hitTargets[target] then
        return false, "AlreadyHit"
    end

    hitTargets[target] = true

    return true
end

-- Набор целей, уже поражённых ударом attackId ([model] = true), либо nil, если удар
-- уже не актуален. Используется, чтобы пропускать их при поиске целей.
function CombatStateService:GetHitTargets(character, attackId)
    local record = Records[character]
    local attack = record and record.Attack

    if not attack or attack.AttackId ~= attackId then
        return nil
    end

    return attack.HitTargets
end

-- Dead: абсолютный приоритет, прерывает всё. Выход только через ResetCharacter.
function CombatStateService:SetDead(character)
    return self:Transition(character, State.Dead)
end

-- Полный сброс записи (новый персонаж, повторное использование NPC).
-- Все ранее созданные таймеры становятся недействительными.
function CombatStateService:ResetCharacter(character)
    local oldRecord = Records[character]
    local oldState = oldRecord and oldRecord.State or State.Idle

    Records[character] = nil

    local record = GetRecord(character)

    if oldState ~= State.Idle then
        StateChanged.Fire(character, State.Idle, oldState, record.TransitionId)
    end
end

function CombatStateService:Init()
    Players.PlayerRemoving:Connect(function(player)
        local character = player.Character

        if character then
            Records[character] = nil
        end
    end)

    print("[CombatStateService] Initialized")
end

return CombatStateService
