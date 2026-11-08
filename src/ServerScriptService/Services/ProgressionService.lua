local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local ProgressionConfig = require(
    ReplicatedStorage.Shared.Config.ProgressionConfig
)

local DataService = require(script.Parent.DataService)
local CharacterService = require(script.Parent.CharacterService)
local RemoteService = require(script.Parent.RemoteService)

local ProgressionService = {}

local function GetRequiredExperience(level)
    return ProgressionConfig:GetExperienceForNextLevel(level)
end

local function SendProfileUpdate(player, profile)
    RemoteService:GetEvent("ProfileUpdated"):FireClient(player, {
        Level = profile.Level,
        Experience = profile.Experience,
        StatPoints = profile.StatPoints,
        Stats = profile.Stats,
        Resources = profile.Resources,
    })
end

-- Начисление опыта. Вызывать только с сервера.
function ProgressionService:AddExperience(player, amount)
    local profile = DataService:GetProfile(player)

    if not profile then
        return false
    end

    if type(amount) ~= "number"
        or amount ~= amount
        or amount <= 0
        or amount == math.huge
        or amount % 1 ~= 0 then
        return false
    end

    amount = math.min(amount, 1000000)

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

    player:SetAttribute("Level", profile.Level)
    player:SetAttribute("Experience", profile.Experience)
    player:SetAttribute("StatPoints", profile.StatPoints)

    SendProfileUpdate(player, profile)

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

    if type(amount) ~= "number"
        or amount ~= amount
        or amount == math.huge
        or amount % 1 ~= 0
        or amount <= 0
        or amount > 100 then
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

    player:SetAttribute("StatPoints", profile.StatPoints)

    -- Обновляем характеристики персонажа.
    if player.Character then
        CharacterService:ApplyStats(
            player,
            player.Character,
            profile
        )
    end

    SendProfileUpdate(player, profile)

    print(
        "[ProgressionService] Allocated:",
        player.Name,
        statName,
        amount
    )

    return true
end

function ProgressionService:Init()
    local allocationEvent = RemoteService:GetEvent(
        "StatAllocationRequest"
    )

    allocationEvent.OnServerEvent:Connect(function(
        player,
        statName,
        amount
    )
        self:AllocateStatPoints(
            player,
            statName,
            amount
        )
    end)

    Players.PlayerAdded:Connect(function(player)
        player:SetAttribute("StatPoints", 0)
    end)

    print("[ProgressionService] Initialized")
end

return ProgressionService
