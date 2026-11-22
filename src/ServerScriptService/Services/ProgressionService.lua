local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProgressionConfig = require(
    ReplicatedStorage.Shared.Config.ProgressionConfig
)
local StatRules = require(ReplicatedStorage.Shared.Progression.StatRules)

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

local function PublishAttributeChange(player, profile)
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid then
        CharacterService:UpdateDerivedStats(player, humanoid, profile)
    else
        CharacterService:RefreshAttributes(player, profile)
    end
    return PlayerService:PushProfile(player)
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
    if type(statName) ~= "string" or not IsWholePositiveNumber(amount) or amount > MAX_POINTS_PER_REQUEST then
        return false
    end

    local profile = self:CommitStatAllocation(player, { [statName] = amount })
    return profile ~= nil
end

function ProgressionService:CommitStatAllocation(player, changes)
    local profile = DataService:GetProfile(player)
    if not profile then
        return nil, "ProfileUnavailable"
    end

    local attributes = profile.Stats.Attributes
    local cost, reason = StatRules.GetAllocationCost(attributes, profile.StatPoints, changes)
    if not cost then
        return nil, reason
    end

    -- Validate the whole draft before mutating the profile. Nothing yields between validation and debit.
    for statName, amount in pairs(changes) do
        attributes[statName] += amount
    end
    profile.StatPoints -= cost

    return PublishAttributeChange(player, profile)
end

function ProgressionService:ResetAttributes(player)
    local profile = DataService:GetProfile(player)
    if not profile then
        return nil, "ProfileUnavailable"
    end

    local refund = StatRules.GetSpentPoints(profile.Stats.Attributes)
    if refund == 0 then
        return nil, "NothingToReset"
    end

    profile.Stats.Attributes = table.clone(ProgressionConfig.StartingAttributes)
    profile.StatPoints += refund
    return PublishAttributeChange(player, profile)
end

function ProgressionService:Init()
    RemoteService:OnFunction("CommitStatAllocation", { RateLimit = 4 }, function(player, changes)
        local profile, reason = self:CommitStatAllocation(player, changes)
        return { Profile = profile, Reason = reason }
    end)

    RemoteService:OnFunction("ResetAttributes", { RateLimit = 2 }, function(player)
        local profile, reason = self:ResetAttributes(player)
        return { Profile = profile, Reason = reason }
    end)

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
