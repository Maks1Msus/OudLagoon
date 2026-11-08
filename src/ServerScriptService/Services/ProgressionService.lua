local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProgressionConfig = require(
    ReplicatedStorage.Shared.Config.ProgressionConfig
)

local DataService = require(script.Parent.DataService)
local CharacterService = require(script.Parent.CharacterService)
local PlayerService = require(script.Parent.PlayerService)
local RemoteService = require(script.Parent.RemoteService)

local ProgressionService = {}

local MAX_EXPERIENCE_PER_CALL = 1000000
local MAX_POINTS_PER_REQUEST = 100

local function GetRequiredExperience(level)
    return ProgressionConfig:GetExperienceForNextLevel(level)
end

local function IsWholePositiveNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value > 0
        and value % 1 == 0
end

-- Начисление опыта. Вызывать только с сервера.
-- Возвращает: успех, повысился ли уровень.
function ProgressionService:AddExperience(player, amount)
    local profile = DataService:GetProfile(player)

    if not profile then
        return false
    end

    if not IsWholePositiveNumber(amount) then
        return false
    end

    amount = math.min(amount, MAX_EXPERIENCE_PER_CALL)

    if profile.Level >= ProgressionConfig.MaxLevel then
        return false
    end

    profile.Experience += amount

    local leveledUp = false

    while profile.Level < ProgressionConfig.MaxLevel do
        local required = GetRequiredExperience(profile.Level)

        if profile.Experience < required then
            break
        end

        profile.Experience -= required
        profile.Level += 1

        profile.StatPoints +=
            ProgressionConfig.StatPointsPerLevel

        leveledUp = true

        print(
            "[ProgressionService] Level up:",
            player.Name,
            profile.Level
        )
    end

    -- На максимальном уровне опыт больше не накапливается.
    if profile.Level >= ProgressionConfig.MaxLevel then
        profile.Experience = 0
    end

    -- Обновляет Level, Experience, StatPoints и т.д. Здоровье и ману не трогает.
    CharacterService:RefreshAttributes(player, profile)

    PlayerService:PushProfile(player)

    return true, leveledUp
end

-- Распределение очков характеристик.
function ProgressionService:AllocateStatPoints(
    player,
    statName,
    amount
)
    local profile = DataService:GetProfile(player)

    if not profile then
        return false
    end

    if type(statName) ~= "string"
        or not ProgressionConfig.AllocatableStats[statName] then
        return false
    end

    if not IsWholePositiveNumber(amount)
        or amount > MAX_POINTS_PER_REQUEST then
        return false
    end

    local currentValue = profile.Stats[statName]

    if type(currentValue) ~= "number" then
        return false
    end

    if profile.StatPoints < amount then
        return false
    end

    if currentValue + amount > ProgressionConfig.MaxStatValue then
        return false
    end

    profile.Stats[statName] += amount
    profile.StatPoints -= amount

    -- Пересчитываем здоровье, скорость и ману БЕЗ полного восстановления:
    -- иначе вложение очка работало бы как лечение.
    local character = player.Character
    local humanoid = character
        and character:FindFirstChildOfClass("Humanoid")

    if humanoid then
        CharacterService:UpdateDerivedStats(player, humanoid, profile)
    else
        CharacterService:RefreshAttributes(player, profile)
    end

    PlayerService:PushProfile(player)

    print(
        "[ProgressionService] Allocated:",
        player.Name,
        statName,
        amount
    )

    return true
end

function ProgressionService:Init()
    -- Через RemoteService: лимит частоты и проверка аргументов.
    RemoteService:OnEvent("StatAllocationRequest", {
        RateLimit = 10,
        Validate = function(statName, amount)
            return RemoteService.Check.String(statName, 16)
                and RemoteService.Check.Number(
                    amount,
                    1,
                    MAX_POINTS_PER_REQUEST
                )
        end,
    }, function(player, statName, amount)
        self:AllocateStatPoints(player, statName, amount)
    end)

    print("[ProgressionService] Initialized")
end

return ProgressionService