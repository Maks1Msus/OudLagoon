local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConstants = require(
    ReplicatedStorage.Shared.Constants.GameConstants
)

local DataService = require(script.Parent.DataService)
local RemoteService = require(script.Parent.RemoteService)
local PlayerService = require(script.Parent.PlayerService)
local CharacterService = require(script.Parent.CharacterService)

local DebugService = {}

local Check = RemoteService.Check

-- ВРЕМЕННАЯ формула опыта. Позже переедет в ProgressionService.
local function XpToNextLevel(level)
    return 100 * level
end

local function GetHumanoid(player)
    local character = player.Character

    return character and character:FindFirstChildOfClass("Humanoid")
end

-- Все действия выполняются на сервере над серверным профилем.
-- Клиент присылает только название действия и число.
local Actions = {}

function Actions.AddXP(player, profile, amount)
    profile.Experience += math.floor(amount or 50)

    while profile.Level < GameConstants.MaxLevel
        and profile.Experience >= XpToNextLevel(profile.Level)
    do
        profile.Experience -= XpToNextLevel(profile.Level)
        profile.Level += 1
    end

    CharacterService:RefreshAttributes(player, profile)
    PlayerService:PushProfile(player)
end

function Actions.AddGold(player, profile, amount)
    profile.Resources.Gold += math.floor(amount or 100)

    PlayerService:PushProfile(player)
end

function Actions.DamageSelf(player, _profile, amount)
    local humanoid = GetHumanoid(player)

    if humanoid then
        humanoid:TakeDamage(amount or 20)
    end
end

function Actions.SpendMana(player, _profile, amount)
    CharacterService:SpendMana(player, amount or 30)
end

function Actions.RestoreAll(player, _profile)
    local humanoid = GetHumanoid(player)

    if humanoid then
        humanoid.Health = humanoid.MaxHealth
    end

    CharacterService:RestoreMana(player)
end

function Actions.SaveNow(player, _profile)
    DataService:SaveProfile(player)
end

function DebugService:Init()
    -- В опубликованной игре обработчика нет вообще: вызовы клиента просто игнорируются.
    if not RunService:IsStudio() then
        return
    end

    RemoteService:OnEvent("DebugRequest", {
        RateLimit = 5,
        Validate = function(action, amount)
            return Check.String(action, 32)
                and (amount == nil or Check.Number(amount, 1, 100000))
        end,
    }, function(player, action, amount)
        local handler = Actions[action]

        if not handler then
            return
        end

        local profile = DataService:GetProfile(player)

        if not profile then
            return
        end

        handler(player, profile, amount)
    end)

    print("[DebugService] Studio debug actions enabled")
end

return DebugService