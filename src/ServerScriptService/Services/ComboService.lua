local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponComboConfig = require(
    ReplicatedStorage.Shared.Config.WeaponComboConfig
)

local WeaponRegistry = require(
    ReplicatedStorage.Shared.Weapons.WeaponRegistry
)

local ComboService = {}

-- Состояние хранится по Character, а не Player.
--
-- Это важно:
-- после смерти и появления нового Character старая серия не переносится
-- на новый персонаж.
--
-- Слабые ключи не удерживают удалённые модели в памяти.
local Combos = setmetatable({}, { __mode = "k" })

local function NewRecord()
    return {
        WeaponId = nil,

        MoveId = nil,
        ComboIndex = 0,

        -- Было ли попадание, позволяющее продолжить текущую серию.
        HitConfirmed = false,

        -- AttackId, к которому относится последнее подтверждение.
        -- На следующем этапе это защитит от устаревшего результата старой атаки.
        AttackId = nil,

        -- Один будущий input buffer.
        BufferedAttack = false,

        -- Когда серия должна быть сброшена, если не получила продолжения.
        ExpiresAt = 0,

        -- Время первого успешного попадания серии.
        -- Позже используется для MaxComboLockDuration.
        LockStartedAt = nil,

        -- Для отладки.
        ResetReason = "Initial",
    }
end

local function GetRecord(character)
    local record = Combos[character]

    if not record then
        record = NewRecord()
        Combos[character] = record
    end

    return record
end

local function IsCharacterAlive(character)
    if typeof(character) ~= "Instance"
        or not character:IsA("Model")
        or character.Parent == nil
    then
        return false
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")

    return humanoid ~= nil and humanoid.Health > 0
end

-- -----------------------------------------------------------------------
-- READ API
-- -----------------------------------------------------------------------

function ComboService:GetComboState(character)
    local record = GetRecord(character)

    -- Не возвращаем внутреннюю таблицу напрямую:
    -- внешний код не должен иметь возможность случайно изменить состояние ComboService.
    return {
        WeaponId = record.WeaponId,
        MoveId = record.MoveId,
        ComboIndex = record.ComboIndex,
        HitConfirmed = record.HitConfirmed,
        AttackId = record.AttackId,
        BufferedAttack = record.BufferedAttack,
        ExpiresAt = record.ExpiresAt,
        LockStartedAt = record.LockStartedAt,
        ResetReason = record.ResetReason,
    }
end

function ComboService:GetCurrentMove(character)
    local record = GetRecord(character)

    if not record.WeaponId or not record.MoveId then
        return nil, nil
    end

    return record.MoveId,
        WeaponComboConfig.GetMove(record.WeaponId, record.MoveId)
end

function ComboService:GetNextMove(character)
    local record = GetRecord(character)

    if not record.WeaponId or not record.MoveId then
        return nil, nil
    end

    local currentMove =
        WeaponComboConfig.GetMove(record.WeaponId, record.MoveId)

    if not currentMove or not currentMove.Next then
        return nil, nil
    end

    return currentMove.Next,
        WeaponComboConfig.GetMove(
            record.WeaponId,
            currentMove.Next
        )
end

function ComboService:IsExpired(character, now)
    local record = GetRecord(character)

    if record.ComboIndex == 0 then
        return false
    end

    now = now or os.clock()

    return record.ExpiresAt > 0
        and now >= record.ExpiresAt
end

-- -----------------------------------------------------------------------
-- RESET
-- -----------------------------------------------------------------------

function ComboService:Reset(character, reason)
    if typeof(character) ~= "Instance" then
        return false, "InvalidCharacter"
    end

    local record = GetRecord(character)

    record.WeaponId = nil
    record.MoveId = nil
    record.ComboIndex = 0

    record.HitConfirmed = false
    record.AttackId = nil
    record.BufferedAttack = false

    record.ExpiresAt = 0
    record.LockStartedAt = nil

    record.ResetReason = reason or "Reset"

    return true
end

-- -----------------------------------------------------------------------
-- SERIES FOUNDATION
-- -----------------------------------------------------------------------

-- Начинает новую логическую серию.
--
-- На ЭТАПЕ 1 этот метод ещё НЕ запускает CombatService и НЕ меняет CombatState.
-- Он только готовит combo state.
function ComboService:BeginSeries(character, weaponId, attackId)
    if not IsCharacterAlive(character) then
        return false, "CharacterUnavailable"
    end

    local weaponCombo = WeaponComboConfig.GetWeapon(weaponId)

    if not weaponCombo then
        return false, "UnknownWeapon"
    end

    local moveId, move =
        WeaponComboConfig.GetStartMove(weaponId)

    if not move then
        return false, "NoStartMove"
    end

    local record = GetRecord(character)

    record.WeaponId = weaponId
    record.MoveId = moveId
    record.ComboIndex = move.Index

    record.HitConfirmed = false
    record.AttackId = attackId
    record.BufferedAttack = false

    record.LockStartedAt = nil
    record.ResetReason = nil

    local resetAfter = weaponCombo.ResetAfter
        or WeaponComboConfig.Settings.DefaultResetAfter

    record.ExpiresAt = os.clock() + resetAfter

    return true, moveId, move
end

-- Помечает текущую атаку как подтверждённую попаданием.
--
-- Пока не подключён к CombatService.
function ComboService:ConfirmHit(character, attackId)
    local record = GetRecord(character)

    if record.ComboIndex == 0 then
        return false, "NoCombo"
    end

    if record.AttackId ~= nil
        and attackId ~= nil
        and record.AttackId ~= attackId
    then
        return false, "StaleAttack"
    end

    record.HitConfirmed = true

    if not record.LockStartedAt then
        record.LockStartedAt = os.clock()
    end

    return true
end

-- Сохраняет одно нажатие следующей атаки.
--
-- На ЭТАПЕ 2 этот метод будет вызываться из серверной обработки CombatRequest.
function ComboService:BufferAttack(character)
    local record = GetRecord(character)

    if record.BufferedAttack then
        return false, "AlreadyBuffered"
    end

    record.BufferedAttack = true

    return true
end

function ComboService:ConsumeBufferedAttack(character)
    local record = GetRecord(character)

    if not record.BufferedAttack then
        return false
    end

    record.BufferedAttack = false

    return true
end

-- Переводит логическую серию на следующее звено.
--
-- ВАЖНО:
-- этот метод НЕ переводит CombatState и НЕ запускает атаку.
-- На ЭТАПЕ 3 вызов будет происходить только после успешного
-- StartComboAttack() в CombatStateService.
function ComboService:Advance(character, nextAttackId)
    local record = GetRecord(character)

    if record.ComboIndex == 0 then
        return false, "NoCombo"
    end

    if self:IsExpired(character) then
        self:Reset(character, "Expired")

        return false, "Expired"
    end

    if not record.HitConfirmed then
        return false, "NotConfirmed"
    end

    local weaponCombo =
        WeaponComboConfig.GetWeapon(record.WeaponId)

    local currentMove =
        WeaponComboConfig.GetMove(
            record.WeaponId,
            record.MoveId
        )

    if not weaponCombo or not currentMove then
        self:Reset(character, "InvalidConfig")

        return false, "InvalidConfig"
    end

    if not currentMove.Next then
        return false, "ComboComplete"
    end

    local nextMove =
        WeaponComboConfig.GetMove(
            record.WeaponId,
            currentMove.Next
        )

    if not nextMove then
        self:Reset(character, "InvalidNextMove")

        return false, "InvalidNextMove"
    end

    if nextMove.Index > weaponCombo.MaxChain then
        self:Reset(character, "MaxChain")

        return false, "MaxChain"
    end

    record.MoveId = currentMove.Next
    record.ComboIndex = nextMove.Index

    record.HitConfirmed = false
    record.AttackId = nextAttackId
    record.BufferedAttack = false

    local resetAfter = weaponCombo.ResetAfter
        or WeaponComboConfig.Settings.DefaultResetAfter

    record.ExpiresAt = os.clock() + resetAfter

    return true, record.MoveId, nextMove
end

-- -----------------------------------------------------------------------
-- WEAPON CONSISTENCY
-- -----------------------------------------------------------------------

-- Серия не может продолжаться другим оружием.
function ComboService:ValidateWeapon(character)
    local record = GetRecord(character)

    if record.ComboIndex == 0 then
        return true
    end

    local weaponId =
        WeaponRegistry.ResolveFromCharacter(character)

    if weaponId ~= record.WeaponId then
        self:Reset(character, "WeaponChanged")

        return false, "WeaponChanged"
    end

    return true
end

-- -----------------------------------------------------------------------
-- LIFECYCLE
-- -----------------------------------------------------------------------

function ComboService:Init()
    WeaponComboConfig.Validate()

    Players.PlayerRemoving:Connect(function(player)
        local character = player.Character

        if character then
            Combos[character] = nil
        end
    end)

    print("[ComboService] Initialized")
end

return ComboService