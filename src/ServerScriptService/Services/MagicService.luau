local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage").Shared
local Config = require(Shared.Config.MagicConfig)
local Composer = require(Shared.Magic.SpellComposer)
local Ability = require(script.Parent.AbilityService)
local Gate = require(script.Parent.GateService)
local State = require(script.Parent.CombatStateService)
local Character = require(script.Parent.CharacterService)
local Data = require(script.Parent.DataService)
local Remote = require(script.Parent.RemoteService)
local Targeting = require(script.Parent.TargetingService)
local Service = {}

local function cast(character, player, profile, recipe, aim)
    if not character or not character:IsDescendantOf(workspace) then return false, "Character unavailable" end
    local stats = Composer.Stats(profile)
    local spell, reason = Composer.Resolve(recipe, stats)
    if not spell then return false, reason end
    local gate = Gate:Register(character, stats.Stability)
    local holder = player or character
    if not player and holder:GetAttribute("Mana") == nil then
        local capacity = holder:GetAttribute("MaxMana") or 100
        holder:SetAttribute("MaxMana", capacity)
        holder:SetAttribute("Mana", capacity)
    end
    local function available()
        if gate.Overloaded then return false, "Gate overloaded" end
        if (holder:GetAttribute("Mana") or 0) < spell.ManaCost then return false, "Not enough mana" end
        return true
    end
    local ready, why = available()
    if not ready then return false, why end
    local overloaded = false
    local function pay()
        local ok, message = available()
        if not ok then return false, message end
        if player then
            if not Character:SpendMana(player, spell.ManaCost) then return false, "Not enough mana" end
        else
            holder:SetAttribute("Mana", holder:GetAttribute("Mana") - spell.ManaCost)
        end
        overloaded = Gate:Charge(character, spell.GateWear)
        return true
    end
    return Ability:Start(character, spell, aim, pay, function()
        if overloaded then State:ApplyStun(character, Config.Gate.OverloadStun, "GateOverload") end
    end)
end

function Service:CastNPC(character, elements, form, aim)
    if not character or Players:GetPlayerFromCharacter(character) then return false, "NPC required" end
    return cast(character, nil, nil, { Elements = elements, Form = form }, aim)
end

function Service:Init()
    Remote:OnEvent("MagicRequest", {
        RateLimit = 5,
        Validate = function(recipe, aim, ...)
            return select("#", ...) == 0 and type(recipe) == "table" and Targeting.ValidDirection(aim)
        end,
    }, function(player, recipe, aim)
        local profile = Data:GetProfile(player)
        if not profile then return end
        local ok, reason = cast(player.Character, player, profile, recipe, aim)
        if not ok then Remote:GetEvent("AbilityResult"):FireClient(player, player.Character, "Error", reason) end
    end)
end
return Service
