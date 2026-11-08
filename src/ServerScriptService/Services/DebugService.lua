local RunService = game:GetService("RunService")

local DataService = require(script.Parent.DataService)
local RemoteService = require(script.Parent.RemoteService)
local PlayerService = require(script.Parent.PlayerService)
local CharacterService = require(script.Parent.CharacterService)
local ProgressionService = require(script.Parent.ProgressionService)

local DebugService = {}

local Check = RemoteService.Check

local function GetHumanoid(player)
    local character = player.Character

    return character and character:FindFirstChildOfClass("Humanoid")
end

-- Все действия выполняются на сервере над серверным профилем.
-- Клиент присылает только название действия и число.
local Actions = {}

-- Опыт начисляется через ProgressionService, поэтому работает
-- настоящая кривая уровней и выдаются очки характеристик.
function Actions.AddXP(player, _profile, amount)
    ProgressionService:AddExperience(player, math.floor(amount or 50))
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