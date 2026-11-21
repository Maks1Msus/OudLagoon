-- CombatStateService контролирует, что персонажу РАЗРЕШЕНО делать прямо сейчас.
-- Он хранит состояние, фазу атаки, кулдауны и защищает от устаревших таймеров.
-- Сам он боевых действий не выполняет (поиск целей, урон: это CombatService)
-- и не зависит от CombatService, поэтому циклических зависимостей нет.
--
-- ЭТАП 1 (фундамент): хранение, переходы, защита от устаревших таймеров,
-- проверки CanAttack/CanBlock/CanDodge, SetDead/ResetCharacter, подписки на события.
-- ЭТАП 2 (атака): StartAttack (Startup -> Active -> Recovery -> Idle), строгий порядок фаз,
-- учёт попаданий (RegisterHit), проверка окна попаданий (IsAttackActive).
-- ЭТАП 3.1 (блок): StartBlock, StopBlock, IsBlocking, IsParryActive.
-- ЭТАП 3.2 (урон): ApplyDamage (направление блока, парирование, снижение урона).
-- Следующие этапы добавят: ApplyStun, StartDodge.
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

local WeaponComboConfig = require(ReplicatedStorage.Shared.Config.WeaponComboConfig)

local DashConfig = require(ReplicatedStorage.Shared.Config.DashConfig)

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
    [State.Idle] = ToSet({ State.Attacking, State.Blocking, State.Dodging, State.Stunned, State.Ragdolled, State.Dead }),
    [State.Attacking] = ToSet({ State.Idle, State.Blocking, State.Dodging, State.Stunned, State.Ragdolled, State.Dead }),
    [State.Blocking] = ToSet({ State.Idle, State.Dodging, State.Stunned, State.Ragdolled, State.Dead }),
    [State.Dodging] = ToSet({ State.Idle, State.Stunned, State.Ragdolled, State.Dead }),
    [State.Stunned] = ToSet({ State.Idle, State.Ragdolled, State.Dead }),
    [State.Ragdolled] = ToSet({ State.Idle, State.Dead }),
    [State.Dead] = ToSet({}),
}

-- В какое поле записи складываются данные состояния
local SubRecordKey = {
    [State.Attacking] = "Attack",
    [State.Blocking] = "Block",
    [State.Dodging] = "Dodge",
    [State.Stunned] = "Stun",
    [State.Ragdolled] = "Ragdoll",
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
        StunImmuneUntil = 0,
        ComboLockImmuneUntil = 0,
        ComboLock = nil,
        AttackRestrictions = setmetatable({}, { __mode = "k" }),
        -- Кулдауны переживают смену состояния
        Cooldowns = { ForwardDash = 0, MobilityDash = 0, DashLight = 0 },

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

local RecoveryFinished = CreateSignal()
local StateChanged = CreateSignal()
local AttackPhaseChanged = CreateSignal()
local DamageApplied = CreateSignal()
local StunUpdated = CreateSignal()

-- callback(character, outcome, sourcePosition): outcome - результат ApplyDamage
-- ({ Result, Damage, Absorbed }). Вызывается для всех исходов, кроме Ignored.
-- Так сервисы (например, анимации NPC) реагируют на удары, не зная о CombatService.
-- Возвращает функцию отписки.
function CombatStateService:OnDamageApplied(callback)
    return DamageApplied.Connect(callback)
end

-- callback(character, newState, oldState, transitionId). Возвращает функцию отписки.
function CombatStateService:OnStunUpdated(callback)
    return StunUpdated.Connect(callback)
end

function CombatStateService:OnStateChanged(callback)
    return StateChanged.Connect(callback)
end

-- callback(character, phase, attackId). Возвращает функцию отписки.
function CombatStateService:OnRecoveryFinished(callback)
    return RecoveryFinished.Connect(callback)
end

function CombatStateService:OnAttackPhaseChanged(callback)
    return AttackPhaseChanged.Connect(callback)
end

-- ПРОВЕРКИ --------------------------------------------------------------

-- Можно ли сейчас перейти в newState. Возвращает true либо false, <причина>.
local function IsRestrictionCurrent(attacker, restriction)
    local source = Records[attacker]
    local humanoid = attacker:FindFirstChildOfClass("Humanoid")
    local attack = source and source.Attack
    return attacker.Parent and humanoid and humanoid.Health > 0
        and source and source.State == State.Attacking and attack == restriction.Attack
        and not (restriction.UntilRecovery and attack.Phase == Phase.Recovery)
end

local function IsComboAttackRestricted(record)
    local now = os.clock()
    for attacker, restriction in pairs(record.AttackRestrictions) do
        local current = IsRestrictionCurrent(attacker, restriction)
        if current and (not restriction.ExpiresAt or now < restriction.ExpiresAt) then
            return true
        end
        if current and restriction.ComboLock and restriction.ExpiresAt
            and now >= restriction.ExpiresAt
        then
            restriction.ComboLock.Exhausted = true
        end
        record.AttackRestrictions[attacker] = nil
    end
    return false
end

local function GetComboParryWindow(record, now)
    for attacker, restriction in pairs(record.AttackRestrictions) do
        local window = restriction.ParryWindow
        local source = Records[attacker]
        local humanoid = attacker:FindFirstChildOfClass("Humanoid")
        if window and not window.Consumed and now < window.EndsAt
            and (not restriction.ExpiresAt or now < restriction.ExpiresAt)
            and attacker.Parent and humanoid and humanoid.Health > 0
            and source and source.State == State.Attacking
            and source.Attack == window.Attack and restriction.Attack == window.Attack
            and source.Attack.Phase == Phase.Startup
        then
            return window
        end
    end
    return nil
end

local function CanEnter(record, newState, now)
    if newState == State.Attacking and IsComboAttackRestricted(record) then
        return false, "ComboDefenseOnly"
    end
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

    return true
end

-- Все Can* возвращают true либо false, <причина>.
function CombatStateService:CanAttack(character)
    return CanEnter(GetRecord(character), State.Attacking, os.clock())
end

function CombatStateService:CanBlock(character)
    return CanEnter(GetRecord(character), State.Blocking, os.clock())
end

local DodgeDirections = require(ReplicatedStorage.Shared.Combat.DodgeDirections)

function CombatStateService:StartDodge(character, directionId, requestId)
    directionId = directionId or "Forward"
    if not DodgeDirections.IsValidId(directionId) then return false, "InvalidDirection" end
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not character or not character.Parent or not humanoid or humanoid.Health <= 0 then
        return false, "CharacterUnavailable"
    end
    return self:Transition(character, State.Dodging, {
        Data = { DirectionId = directionId, RequestId = requestId },
    })
end

function CombatStateService:GetDodgeId(character)
    local record = Records[character]
    return record and record.Dodge and record.Dodge.DodgeId or nil
end

function CombatStateService:GetDodgeElapsed(character, dodgeId)
    local record = Records[character]
    if not record or record.State ~= State.Dodging or not record.Dodge
        or record.Dodge.DodgeId ~= dodgeId then return nil end
    return math.max(0, os.clock() - record.StateStartedAt)
end

function CombatStateService:CanDashAttack(character, dodgeId)
    local record = Records[character]
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local elapsed = self:GetDodgeElapsed(character, dodgeId)
    local conversion = DashConfig.Forward.AttackConversion
    if not humanoid or humanoid.Health <= 0 or not character.Parent or elapsed == nil
        or record.Dodge.DirectionId ~= "Forward" or not conversion.Enabled then
        return false, "DashConversionUnavailable"
    end
    if elapsed + 0.000001 < conversion.WindowStart or elapsed - 0.000001 > conversion.WindowEnd then
        return false, "DashConversionWindow"
    end
    if IsComboAttackRestricted(record) then return false, "ComboDefenseOnly" end
    if os.clock() < record.Cooldowns.DashLight then return false, "DashLightCooldown" end
    return true
end

function CombatStateService:GetDashLightCooldownRemaining(character)
    local record = character and Records[character]
    return record and math.max(0, record.Cooldowns.DashLight - os.clock()) or 0
end

function CombatStateService:GetDodgeAnimationState(character)
    local record = Records[character]
    local dodge = record and record.Dodge
    if not dodge or record.State ~= State.Dodging or not record.StateEndsAt then return nil end
    return {
        Id = dodge.DodgeId, Revision = 1, DirectionId = dodge.DirectionId, Kind = dodge.Kind,
        RequestId = dodge.RequestId,
        StartedAt = dodge.AnimationStartedAt,
        EndsAt = dodge.AnimationStartedAt + (record.StateEndsAt - record.StateStartedAt),
        IFrameEndsAt = dodge.AnimationStartedAt + (dodge.IFrameEndsAt - record.StateStartedAt),
    }
end

function CombatStateService:IsDodgeInvulnerable(character)
    local record = Records[character]
    return record ~= nil and record.State == State.Dodging and record.Dodge ~= nil
        and os.clock() < record.Dodge.IFrameEndsAt
end

function CombatStateService:CanDodge(character, directionId)
    directionId = directionId or "Forward"
    if not DodgeDirections.IsValidId(directionId) then return false, "InvalidDirection" end
    local record = GetRecord(character)
    local now = os.clock()
    local allowed, reason = CanEnter(record, State.Dodging, now)
    if not allowed then return false, reason end
    local profile = DashConfig.GetProfile(directionId)
    if now < record.Cooldowns[profile.CooldownGroup] then return false, "Cooldown" end
    return true
end

-- Movement can end early, but only the state owner may complete the matching dash.
function CombatStateService:EndDodge(character, dodgeId)
    if self:GetDodgeId(character) ~= dodgeId or self:GetState(character) ~= State.Dodging then
        return false, "StaleDodge"
    end
    return self:Transition(character, State.Idle)
end

function CombatStateService:GetDodgeCooldownRemaining(character, directionId)
    if not character or not DodgeDirections.IsValidId(directionId) then return 0 end
    local record = GetRecord(character)
    local profile = DashConfig.GetProfile(directionId)
    return math.max(0, record.Cooldowns[profile.CooldownGroup] - os.clock())
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
local function ScheduleStateEnd(self, character, record, duration)
    local token = {}
    record.DurationToken = token
    self:Delay(character, duration, function()
        if record.DurationToken == token then
            self:Transition(character, State.Idle)
        end
    end)
end

local function Transition(self, character, newState, options, previousAttackId, comboParry, dashId)
    if not ValidStates[newState] then
        return false, "UnknownState"
    end

    local record = GetRecord(character)
    local now = os.clock()

    local dashProfile
    if newState == State.Dodging then
        local directionId = options and options.Data and options.Data.DirectionId or "Forward"
        local permitted, why = self:CanDodge(character, directionId)
        if not permitted then return false, why end
        dashProfile = DashConfig.GetProfile(directionId)
        options = table.clone(options or {})
        options.Data = { DirectionId = directionId, Kind = DashConfig.GetKind(directionId),
            RequestId = options.Data and options.Data.RequestId }
        options.Duration = dashProfile.Duration
    end

    local allowed, reason
    if comboParry then
        local canDefend = record.State == State.Idle or record.State == State.Blocking
            or (record.State == State.Stunned and record.Stun and record.Stun.Source == "Hit")
        allowed = newState == State.Blocking and canDefend
            and GetComboParryWindow(record, now) == comboParry
        reason = "ComboParryUnavailable"
    elseif dashId then
        allowed, reason = self:CanDashAttack(character, dashId)
        allowed = allowed and newState == State.Attacking
    elseif previousAttackId then
        if IsComboAttackRestricted(record) then
            return false, "ComboDefenseOnly"
        end
        local attack = record.Attack
        allowed = newState == State.Attacking and record.State == State.Attacking
            and attack and attack.AttackId == previousAttackId and attack.Phase == Phase.Recovery
        reason = "InvalidComboTransition"
    else
        allowed, reason = CanEnter(record, newState, now)
    end

    if not allowed then
        return false, reason
    end

    options = options or {}

    local oldState = record.State
    local oldAttack = record.Attack
    local oldKey = SubRecordKey[oldState]

    if oldState == State.Stunned then
        record.StunImmuneUntil = now + CombatStateConfig.Stun.PostStunImmunity
        record.StunImmuneSource = record.Stun and record.Stun.Source
        record.StunImmuneSeriesId = record.Stun and record.Stun.SeriesId
    end

    if oldKey then
        record[oldKey] = nil
    end

    transitionCounter += 1

    record.TransitionId = transitionCounter
    record.DurationToken = nil
    record.State = newState
    record.StateStartedAt = now
    record.StateEndsAt = options.Duration and (now + options.Duration) or nil

    local newKey = SubRecordKey[newState]

    if newKey then
        local data = options.Data and table.clone(options.Data) or {}

        if newState == State.Attacking then
            attackCounter += 1

            data.AttackId = attackCounter
            data.SeriesId = previousAttackId and (oldAttack.SeriesId or oldAttack.AttackId)
                or data.AttackId
            data.Phase = data.Phase or Phase.Startup
            data.AnimationPhaseStartedAt = workspace:GetServerTimeNow()
            data.PhaseStartedAt = now
            data.PhaseEndsAt = nil
            data.HitTargets = {} -- кого уже поразил этот удар (используется на этапе 2)
        elseif newState == State.Blocking then
            data.StartedAt = now
            data.ParryEndsAt = now + CombatStateConfig.Block.ParryWindow
        elseif newState == State.Dodging then
            data.DirectionId = data.DirectionId or "Forward"
            data.AnimationStartedAt = workspace:GetServerTimeNow()
            data.DodgeId = record.TransitionId
            data.IFrameEndsAt = now + dashProfile.IFrameDuration
        elseif newState == State.Stunned then
            data.AnimationStartedAt = workspace:GetServerTimeNow()
            data.ReactionStartedAt = data.AnimationStartedAt
            data.Revision = 1
        end

        record[newKey] = data

        if previousAttackId and oldAttack.ComboRestrictedTargets then
            data.ComboRestrictedTargets = oldAttack.ComboRestrictedTargets
            for target in pairs(data.ComboRestrictedTargets) do
                local targetRecord = Records[target]
                local restriction = targetRecord and targetRecord.AttackRestrictions[character]
                if restriction and restriction.Attack == oldAttack then
                    if restriction.HitAttackId == oldAttack.AttackId then
                        restriction.Attack = data
                        restriction.UntilRecovery = true
                        restriction.ParryWindow = nil
                    else
                        targetRecord.AttackRestrictions[character] = nil
                    end
                end
            end
        end
    end

    -- Кулдаун уклонения отсчитывается от его начала и не зависит от состояния
    if newState == State.Dodging then
        record.Cooldowns[dashProfile.CooldownGroup] = now + dashProfile.Cooldown
    end
    if dashId and newState == State.Attacking then
        record.Cooldowns.DashLight = now + DashConfig.Forward.AttackConversion.Cooldown
    end

    if options.Duration then
        ScheduleStateEnd(self, character, record, options.Duration)
    end

    Log(character.Name, oldState, "->", newState, "#" .. record.TransitionId)

    local transitionId = record.TransitionId
    StateChanged.Fire(character, newState, oldState, transitionId)

    return true, transitionId
end

function CombatStateService:Transition(character, newState, options)
    return Transition(self, character, newState, options)
end

function CombatStateService:GetStunAnimationState(character)
    local record = character and Records[character]
    local stun = record and record.Stun
    if not stun or record.State ~= State.Stunned or not record.StateEndsAt then
        return nil
    end

    return {
        Id = record.TransitionId,
        Revision = stun.Revision or 1,
        Source = stun.Source,
        StartedAt = stun.ReactionStartedAt or workspace:GetServerTimeNow(),
        EndsAt = workspace:GetServerTimeNow() + (record.StateEndsAt - os.clock()),
    }
end

function CombatStateService:GetAttackAnimationState(character)
    local record = character and Records[character]
    local attack = record and record.Attack
    if not attack then
        return nil
    end

    return {
        AttackId = attack.AttackId,
        Phase = attack.Phase,
        StartedAt = attack.AnimationPhaseStartedAt,
        Duration = attack.AnimationPhaseDuration,
        Timing = attack.AnimationTiming and table.clone(attack.AnimationTiming),
        DashMomentum = attack.Phase == Phase.Startup and attack.DashMomentum
            and table.clone(attack.DashMomentum) or nil,
    }
end

function CombatStateService:GetAttackIdentity(character)
    local record = Records[character]
    local attack = record and record.Attack
    if attack then
        return attack.AttackId, attack.MoveId, attack.ComboIndex
    end
    return nil, nil, nil
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
    attack.AnimationPhaseStartedAt = workspace:GetServerTimeNow()
    attack.AnimationPhaseDuration = duration
    attack.PhaseStartedAt = now
    attack.PhaseEndsAt = duration and (now + duration) or nil

    Log(character.Name, "attack", attackId, "phase", phase)

    AttackPhaseChanged.Fire(character, phase, attackId)

    return true
end

local function IsFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end
-- A finisher may only knock down a live target registered by the current Active hit.
-- The state owns the duration; RagdollService only applies/restores physical joints.
function CombatStateService:GetRagdollData(character)
    local record = Records[character]
    return record and record.Ragdoll and table.clone(record.Ragdoll) or nil
end

function CombatStateService:ApplyComboRagdoll(character, attacker, attackId)
    local source = Records[attacker]
    local attack = source and source.Attack
    if not self:IsAttackActive(attacker, attackId) or not attack.HitTargets[character] then
        return false, "UnconfirmedHit"
    end
    local move = WeaponComboConfig.GetMove(attack.WeaponId, attack.MoveId)
    local finisher = move and move.Finisher
    if not finisher then return false, "NotFinisher" end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
    local sourceRoot = attacker:FindFirstChild("HumanoidRootPart")
    if not character.Parent or not humanoid or humanoid.Health <= 0
        or not root or root.Anchored or not sourceRoot then
        return false, "CharacterUnavailable"
    end
    local delta = root.Position - sourceRoot.Position
    local flat = Vector3.new(delta.X, 0, delta.Z)
    if flat.Magnitude < 0.01 then
        local look = sourceRoot.CFrame.LookVector
        flat = Vector3.new(look.X, 0, look.Z)
    end
    if flat.Magnitude < 0.01 then flat = Vector3.new(0, 0, -1) end
    return self:Transition(character, State.Ragdolled, {
        Duration = finisher.RagdollDuration,
        Data = { Velocity = flat.Unit * finisher.KnockbackSpeed
            + Vector3.new(0, finisher.UpwardSpeed, 0) },
    })
end

-- Оглушает персонажа на заданное время.
-- Стан прерывает любое разрешённое текущее боевое состояние.
-- Повторный стан не продлевает действующий и не обходит иммунитет.
function CombatStateService:ApplyStun(character, duration, source)
    local record = GetRecord(character)

    if record.State == State.Dead then
        return false, "Dead"
    end

    if record.State == State.Stunned then
        return false, "AlreadyStunned"
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")

    if not humanoid or humanoid.Health <= 0 then
        return false, "CharacterUnavailable"
    end

    local now = os.clock()

    -- A successful parry must interrupt the attacker even during post-hit immunity.
    if now < record.StunImmuneUntil and source ~= "Parry" then
        return false, "StunImmune"
    end

    duration = duration or CombatStateConfig.Stun.DefaultDuration

    if not IsFiniteNumber(duration) or duration <= 0 then
        return false, "InvalidDuration"
    end

    duration = math.min(
        duration,
        CombatStateConfig.Stun.MaxDuration
    )

    return self:Transition(character, State.Stunned, {
        Duration = duration,

        Data = {
            Source = source or "Unknown",
            Duration = duration,
        },
    })
end

-- A victim shares one deadline across all overlapping combo pressure.
local function FinishComboLock(self, character, record, lock)
    if Records[character] ~= record or record.ComboLock ~= lock then
        return
    end

    local hitStunned = record.State == State.Stunned and record.Stun
        and record.Stun.Source == "Hit" and record.Stun.ComboLock == lock
    local controlled = hitStunned or lock.Exhausted
    for attacker, restriction in pairs(record.AttackRestrictions) do
        if restriction.ComboLock == lock then
            controlled = IsRestrictionCurrent(attacker, restriction) or controlled
            record.AttackRestrictions[attacker] = nil
        end
    end
    record.ComboLock = nil

    if hitStunned then
        self:Transition(character, State.Idle)
    end
    if controlled then
        record.ComboLockImmuneUntil = os.clock() + CombatStateConfig.Stun.PostStunImmunity
        record.StunImmuneUntil = math.max(record.StunImmuneUntil, record.ComboLockImmuneUntil)
        record.StunImmuneSource = "ComboLock"
        record.StunImmuneSeriesId = nil
    end
end

local function GetComboLock(self, character, record)
    local now = os.clock()
    local lock = record.ComboLock
    if lock and now >= lock.EndsAt then
        FinishComboLock(self, character, record, lock)
        lock = nil
    end
    if now < record.ComboLockImmuneUntil then
        return nil
    end

    -- A fresh budget requires a real gap in control and expired stun immunity.
    if lock and record.State ~= State.Stunned
        and not IsComboAttackRestricted(record) and now >= record.StunImmuneUntil
    then
        record.ComboLock = nil
        lock = nil
    end
    if not lock then
        local duration = WeaponComboConfig.Settings.MaxComboLockDuration
        if not IsFiniteNumber(duration) or duration <= 0 then
            return nil
        end
        lock = { StartedAt = now, EndsAt = now + duration }
        record.ComboLock = lock
        task.delay(duration, function()
            FinishComboLock(self, character, record, lock)
        end)
    end
    return lock
end

-- Only a server-confirmed hit from the current Active attack may refresh combo HitStun.
function CombatStateService:ApplyComboHitStun(character, duration, attacker, attackId)
    if not IsFiniteNumber(duration) or duration < 0 then
        return false, "InvalidDuration"
    end
    if not self:IsAttackActive(attacker, attackId) then
        return false, "StaleAttack"
    end

    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local attackerHumanoid = attacker:FindFirstChildOfClass("Humanoid")
    if not character or not character.Parent or not humanoid or humanoid.Health <= 0
        or not attacker.Parent or not attackerHumanoid or attackerHumanoid.Health <= 0
    then
        return false, "CharacterUnavailable"
    end

    local record = GetRecord(character)
    if record.State == State.Dead then
        return false, "Dead"
    end
    local lock = GetComboLock(self, character, record)
    if not lock then
        return false, "ComboLockImmune"
    end

    local now = os.clock()
    local seriesId = Records[attacker].Attack.SeriesId
    local stun = record.Stun
    if record.State == State.Stunned then
        if not stun or stun.Source ~= "Hit" or stun.ComboLock ~= lock
            or stun.SeriesId ~= seriesId
        then
            return false, "OtherStun"
        end
    elseif now < record.StunImmuneUntil
        and not (record.StunImmuneSource == "Hit" and record.StunImmuneSeriesId == seriesId)
    then
        return false, "StunImmune"
    end

    local endsAt = math.min(now + math.min(duration, CombatStateConfig.Stun.MaxDuration), lock.EndsAt)
    if endsAt <= now then
        return false, "NoHitStun"
    end
    if record.State == State.Stunned then
        record.StateEndsAt = math.min(math.max(record.StateEndsAt or now, endsAt), lock.EndsAt)
        stun.Duration = record.StateEndsAt - record.StateStartedAt
        stun.Revision = (stun.Revision or 1) + 1
        stun.ReactionStartedAt = workspace:GetServerTimeNow()
        ScheduleStateEnd(self, character, record, record.StateEndsAt - now)
        StunUpdated.Fire(character)
        return true, "Refreshed"
    end

    if duration == 0 then
        return false, "NoHitStun"
    end
    return self:Transition(character, State.Stunned, {
        Duration = endsAt - now,
        Data = {
            Source = "Hit",
            Duration = endsAt - now,
            SeriesId = seriesId,
            ComboLock = lock,
        },
    })
end

-- Параметры фаз (CombatConfig.Weapons[...].AttackTiming): Active обязана быть > 0.
local function IsValidTiming(timing)
    return type(timing) == "table"
        and IsFiniteNumber(timing.Startup) and timing.Startup >= 0
        and IsFiniteNumber(timing.Active) and timing.Active > 0
        and IsFiniteNumber(timing.Recovery) and timing.Recovery >= 0
        and (timing.RecoveryOnHit == nil
            or (IsFiniteNumber(timing.RecoveryOnHit) and timing.RecoveryOnHit >= 0))
end

-- Запускает атаку: Attacking (Startup) -> Active -> Recovery -> Idle.
-- Всей последовательностью управляет сервер. Таймеры привязаны к входу в состояние,
-- поэтому любое прерывание (оглушение, смерть, уклонение из Recovery) обрывает цепочку,
-- а устаревшие шаги ничего не меняют и не наносят урона.
-- Возвращает true, <AttackId> либо false, <причина>.
local function StartAttack(self, character, timing, data, previousAttackId, dashId)
    if not IsValidTiming(timing) then
        return false, "InvalidTiming"
    end

    local ok, transitionId = Transition(self, character, State.Attacking, {
        Data = {
            Phase = Phase.Startup,
            AnimationPhaseDuration = timing.Startup,
            AnimationTiming = {
                Startup = timing.Startup,
                Active = timing.Active,
                Recovery = timing.Recovery,
            },
            DashMomentum = data and data.DashMomentum,
            WeaponId = data and data.WeaponId,
            MoveId = data and data.MoveId,
            ComboIndex = data and data.ComboIndex,
            CanBlockDuringRecovery = timing.CanBlockDuringRecovery == true,
            CanDodgeDuringRecovery = timing.CanDodgeDuringRecovery == true,
        },
    }, previousAttackId, nil, dashId)

    if not ok then
        return false, transitionId
    end

    local record = Records[character]
    if not record or record.TransitionId ~= transitionId then
        return false, "AttackInterrupted"
    end

    local attack = record.Attack
    local attackId = attack.AttackId

    attack.Recovery = timing.Recovery
    attack.RecoveryOnHit = timing.RecoveryOnHit
    attack.PhaseEndsAt = os.clock() + timing.Startup

    self:Delay(character, timing.Startup, function()
        if not self:SetAttackPhase(character, attackId, Phase.Active, timing.Active) then
            return
        end

        if not self:IsAttackActive(character, attackId) then
            return
        end

        self:Delay(character, timing.Active, function()
            if not self:SetAttackPhase(character, attackId, Phase.Recovery, attack.Recovery) then
                return
            end

            if self:GetAttackId(character) ~= attackId then
                return
            end

            self:Delay(character, attack.Recovery, function()
                -- Notify combat before falling back to Idle. A continuation
                -- replaces the attack and invalidates this recovery callback.
                RecoveryFinished.Fire(character, attackId)

                if self:GetAttackId(character) == attackId then
                    self:Transition(character, State.Idle)
                end
            end)
        end)
    end)

    return true, attackId
end

-- true, пока атака attackId идёт и находится в фазе Active (окно регистрации попаданий).
function CombatStateService:StartAttack(character, timing, data)
    return StartAttack(self, character, timing, data)
end

function CombatStateService:StartDashAttack(character, timing, data, dodgeId)
    if type(dodgeId) ~= "number" or not data or data.MoveId ~= "DashLight" then
        return false, "InvalidDashAttack"
    end
    local allowed, reason = self:CanDashAttack(character, dodgeId)
    if not allowed then return false, reason end
    return StartAttack(self, character, timing, data, nil, dodgeId)
end

function CombatStateService:StartComboAttack(character, timing, data, previousAttackId)
    if type(previousAttackId) ~= "number" then
        return false, "MissingAttackId"
    end
    return StartAttack(self, character, timing, data, previousAttackId)
end

function CombatStateService:UseHitRecovery(character, attackId)
    if self:IsAttackActive(character, attackId) then
        local attack = Records[character].Attack
        attack.Recovery = attack.RecoveryOnHit or attack.Recovery
        if attack.AnimationTiming then
            attack.AnimationTiming.Recovery = attack.Recovery
        end
    end
end

-- A landed combo hit reserves the gap for defensive actions.
-- The source attack identity releases the restriction on interruption/reset.
function CombatStateService:RestrictComboCounterattack(character, attackId, target, hasNextMove)
    if not self:IsAttackActive(character, attackId) then
        return false
    end

    local attack = Records[character].Attack
    local targetRecord = GetRecord(target)
    if not hasNextMove then
        targetRecord.AttackRestrictions[character] = nil
        return true
    end

    local lock = GetComboLock(self, target, targetRecord)
    if not lock then
        return false, "ComboLockImmune"
    end

    attack.ComboRestrictedTargets = attack.ComboRestrictedTargets
        or setmetatable({}, { __mode = "k" })
    attack.ComboRestrictedTargets[target] = true
    targetRecord.AttackRestrictions[character] = {
        Attack = attack,
        HitAttackId = attackId,
        UntilRecovery = false,
        ExpiresAt = lock.EndsAt,
        ComboLock = lock,
    }

    -- A prior hit-stun immunity must not leave a counterattack running.
    if targetRecord.State == State.Attacking then
        self:Transition(target, State.Idle)
    end
    return true
end

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

-- БЛОКИРОВАНИЕ ----------------------------------------------------------

-- Начинает блок. Допустимость (состояние, фаза собственной атаки, настройки оружия)
-- проверяет Transition: нельзя начать блок в Startup/Active своей атаки, в Recovery можно
-- только при CanBlockDuringRecovery, а из уклонения и оглушения нельзя вообще.
-- Окно парирования отсчитывается серверным временем от этого момента.
-- Повторный вызов во время блока отклоняется и окно парирования НЕ обновляет.
-- Возвращает true, <TransitionId> либо false, <причина>.
-- Grants only victims actually hit by the preceding move an input window.
function CombatStateService:OpenComboParryWindow(character, attackId, previousAttackId, duration)
    local record = Records[character]
    local attack = record and record.Attack
    if not attack or record.State ~= State.Attacking or attack.AttackId ~= attackId
        or attack.Phase ~= Phase.Startup or not IsFiniteNumber(duration) or duration <= 0
    then
        return false, "InvalidComboParryWindow"
    end

    local endsAt = math.min(os.clock() + duration, attack.PhaseEndsAt or os.clock())
    if endsAt <= os.clock() then
        return false, "NoStartupWindow"
    end

    for target in pairs(attack.ComboRestrictedTargets or {}) do
        local targetRecord = Records[target]
        local restriction = targetRecord and targetRecord.AttackRestrictions[character]
        if restriction and restriction.Attack == attack
            and restriction.HitAttackId == previousAttackId
        then
            restriction.ParryWindow = {
                Attacker = character,
                Attack = attack,
                EndsAt = endsAt,
                Consumed = false,
            }
            Log(target.Name, "combo parry window", character.Name, attackId, duration)
        end
    end
    return true
end

-- Only a fresh client press calls this. Ordinary BlockStart keeps its normal rules.
function CombatStateService:TryComboParry(character)
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not character or not character.Parent or not humanoid or humanoid.Health <= 0 then
        return false, "CharacterUnavailable"
    end

    local window = GetComboParryWindow(GetRecord(character), os.clock())
    if not window then
        return false, "NoComboParryWindow"
    end

    local started, reason = Transition(self, character, State.Blocking, {
        Data = { ComboParry = window },
    }, nil, window)
    if started then
        window.Consumed = true
    end
    return started, reason
end

function CombatStateService:StartBlock(character)
    return self:Transition(character, State.Blocking)
end

-- Завершает блок. Действует только если персонаж сейчас блокирует: если блок уже снят
-- уклонением, оглушением или смертью, состояние не меняется, поэтому запоздавший
-- BlockEnd от клиента безопасен. Возвращает true либо false, <причина>.
function CombatStateService:StopBlock(character)
    if GetRecord(character).State ~= State.Blocking then
        return false, "NotBlocking"
    end

    return self:Transition(character, State.Idle)
end

function CombatStateService:IsBlocking(character)
    return GetRecord(character).State == State.Blocking
end

-- true, пока идёт окно парирования: блок активен и с его начала прошло меньше ParryWindow.
-- Считается по серверному времени, отдельный таймер не нужен.
function CombatStateService:IsParryActive(character, attacker, attackId)
    local record = GetRecord(character)
    local block = record.Block

    if record.State ~= State.Blocking or not block then
        return false
    end

    local window = block.ComboParry
    local source = attacker and Records[attacker]
    if window and window.Attacker == attacker and source
        and source.State == State.Attacking and source.Attack == window.Attack
        and source.Attack.AttackId == attackId and source.Attack.Phase == Phase.Active
    then
        return true
    end

    return os.clock() < block.ParryEndsAt
end

-- ПОЛУЧЕНИЕ УРОНА -------------------------------------------------------

local DamageResult = CombatStates.DamageResults

-- Ближе этого расстояния (по горизонтали, studs) направление на источник не определить.
local BLOCK_ARC_MIN_DISTANCE = 0.1

-- Чистая геометрия на числах (а не на Vector3), чтобы её было легко тестировать.
-- look     - направление взгляда защищающегося (достаточно X и Z);
-- toSource - вектор от защищающегося к источнику урона (достаточно X и Z).
-- Защищаемый сектор: +-angleDegrees/2 от направления взгляда, в горизонтальной плоскости.
-- Если направление определить нельзя (источник вплотную или нет направления взгляда),
-- считается, что источник внутри сектора: иначе вплотную стоящий противник "обходил" бы блок.
function CombatStateService.IsInBlockArc(lookX, lookZ, toSourceX, toSourceZ, angleDegrees)
    if angleDegrees >= 360 then
        return true
    end

    local flatLook = math.sqrt(lookX * lookX + lookZ * lookZ)
    local flatDistance = math.sqrt(toSourceX * toSourceX + toSourceZ * toSourceZ)

    if flatDistance < BLOCK_ARC_MIN_DISTANCE or flatLook < 1e-3 then
        return true
    end

    local cosAngle = (lookX * toSourceX + lookZ * toSourceZ) / (flatLook * flatDistance)

    return cosAngle >= math.cos(math.rad(angleDegrees / 2))
end

-- Находится ли источник урона перед защищающимся персонажем (внутри сектора блока).
-- Без известной позиции источника направление не проверить: блок не применяется.
function CombatStateService:IsDamageFromFront(character, sourcePosition)
    if typeof(sourcePosition) ~= "Vector3" then
        return false
    end

    local root = character:FindFirstChild("HumanoidRootPart")

    if not root then
        return false
    end

    local offset = sourcePosition - root.Position
    local look = root.CFrame.LookVector

    return CombatStateService.IsInBlockArc(
        look.X,
        look.Z,
        offset.X,
        offset.Z,
        CombatStateConfig.Block.DirectionAngle
    )
end

-- Единственный путь нанесения боевого урона. Сервер сам решает, что произойдёт:
--   * не блокирует, либо источник вне сектора блока (сзади, сбоку) -> полный урон (Hit);
--   * блок и источник в секторе, окно парирования ещё идёт       -> урона нет (Parried);
--   * блок и источник в секторе, окно парирования прошло         -> урон снижен на
--     Block.DamageReduction (Blocked), но не меньше 1.
-- damage         - число > 0 (уже посчитанный урон атаки);
-- sourcePosition - Vector3 позиции атакующего (для проверки направления).
-- Возвращает { Result = DamageResults.*, Damage = нанесено, Absorbed = поглощено }.
-- Оглушение атакующего при парировании появится вместе с ApplyStun (следующий этап).
function CombatStateService:ApplyDamage(character, damage, sourcePosition, attacker, attackId)
    local function Outcome(result, applied)
        return {
            Result = result,
            Damage = applied,
            Absorbed = (IsFiniteNumber(damage) and damage > 0) and (damage - applied) or 0,
        }
    end

    if not IsFiniteNumber(damage) or damage <= 0 then
        return Outcome(DamageResult.Ignored, 0)
    end

    local humanoid = character and character:FindFirstChildOfClass("Humanoid")

    if not humanoid or humanoid.Health <= 0 then
        return Outcome(DamageResult.Ignored, 0)
    end

    if self:IsDodgeInvulnerable(character) then
        return Outcome(DamageResult.Ignored, 0)
    end

    local result = DamageResult.Hit
    local applied = damage

    if self:IsBlocking(character) and self:IsDamageFromFront(character, sourcePosition) then
        if self:IsParryActive(character, attacker, attackId) then
            result = DamageResult.Parried
            applied = 0
        else
            result = DamageResult.Blocked

            local reduced = math.floor(
                damage * (1 - CombatStateConfig.Block.DamageReduction) + 0.5
            )

            applied = math.min(damage, math.max(1, reduced))
        end
    end

    -- Snapshot the confirmed attack before damage/death listeners can clear its state.
    -- Cosmetic metadata only; this does not change damage or hit detection.
    local source = attacker and Records[attacker]
    local attack = source and source.Attack
    local impact
    if source and source.State == State.Attacking and attack and attack.AttackId == attackId
        and attack.Phase == Phase.Active and attack.HitTargets[character] then
        impact = { Attacker = attacker, AttackId = attackId,
            WeaponId = attack.WeaponId, MoveId = attack.MoveId }
    end
    if applied > 0 then
        humanoid:TakeDamage(applied)
    end

    Log(character.Name, "damage", damage, "->", applied, result)

    local outcome = Outcome(result, applied)

    DamageApplied.Fire(character, outcome, sourcePosition, impact)

    return outcome
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

-- Ошибки конфигурации должны проявляться при запуске, а не посреди боя.
local function ValidateConfig()
    DashConfig.Validate()
    local block = CombatStateConfig.Block

    assert(
        IsFiniteNumber(block.ParryWindow) and block.ParryWindow >= 0,
        "[CombatStateService] Block.ParryWindow must be a number >= 0"
    )

    assert(
        IsFiniteNumber(block.DamageReduction)
            and block.DamageReduction >= 0
            and block.DamageReduction <= 1,
        "[CombatStateService] Block.DamageReduction must be a number in [0, 1]"
    )

    assert(
        IsFiniteNumber(block.DirectionAngle)
            and block.DirectionAngle > 0
            and block.DirectionAngle <= 360,
        "[CombatStateService] Block.DirectionAngle must be a number in (0, 360]"
    )
    local stun = CombatStateConfig.Stun

    assert(
        IsFiniteNumber(stun.DefaultDuration)
            and stun.DefaultDuration > 0,
        "[CombatStateService] Stun.DefaultDuration must be > 0"
    )

    assert(
        IsFiniteNumber(stun.MaxDuration)
            and stun.MaxDuration > 0,
        "[CombatStateService] Stun.MaxDuration must be > 0"
    )

    assert(
        IsFiniteNumber(stun.PostStunImmunity)
            and stun.PostStunImmunity >= 0,
        "[CombatStateService] Stun.PostStunImmunity must be >= 0"
    )

    assert(stun.MaxDuration >= stun.DefaultDuration,
        "[CombatStateService] Stun.MaxDuration must be >= DefaultDuration")
end

function CombatStateService:Init()
    ValidateConfig()

    Players.PlayerRemoving:Connect(function(player)
        local character = player.Character

        if character then
            Records[character] = nil
        end
    end)

    print("[CombatStateService] Initialized")
end

return CombatStateService
