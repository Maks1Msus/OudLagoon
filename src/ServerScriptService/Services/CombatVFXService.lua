-- Publishes cosmetic state and confirmed impacts for players and NPCs.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Config = require(ReplicatedStorage.Shared.Config.CombatVFXConfig)
local CombatStates = require(ReplicatedStorage.Shared.Constants.CombatStates)
local WeaponRegistry = require(ReplicatedStorage.Shared.Weapons.WeaponRegistry)
local CombatStateService = require(script.Parent.CombatStateService)
local RemoteService = require(script.Parent.RemoteService)

local Directions = require(ReplicatedStorage.Shared.Combat.DodgeDirections)

local PostureService = require(script.Parent.PostureService)
local CombatVFXService = {}
local initialized = false
local Attributes = Config.Attributes

local function GetRoot(character)
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function Broadcast(character, payload)
    local root = GetRoot(character)
    if not root then return end
    payload.Target = character
    payload.ServerTime = workspace:GetServerTimeNow()
    local event = RemoteService:GetEvent("CombatVFX")
    for _, player in ipairs(Players:GetPlayers()) do
        local observerRoot = GetRoot(player.Character)
        if observerRoot and (observerRoot.Position - root.Position).Magnitude <= Config.BroadcastDistance then
            event:FireClient(player, payload)
        end
    end
end

local function Publish(character)
    if not character.Parent then
        return
    end

    local state = CombatStateService:GetState(character)
    local cast = state == CombatStates.UsingAbility and CombatStateService:GetAbility(character)
    character:SetAttribute(Attributes.CastColor, cast and cast.Color or nil)
    character:SetAttribute(Attributes.State, state)
    local dodge = CombatStateService:GetDodgeAnimationState(character)
    character:SetAttribute(Attributes.DodgeIFrameEndsAt, dodge and dodge.IFrameEndsAt)
    character:SetAttribute(Attributes.DodgeEndsAt, dodge and dodge.EndsAt)
    local attack = CombatStateService:GetAttackAnimationState(character)
    character:SetAttribute(Attributes.MoveId, attack and attack.MoveId)
    character:SetAttribute(Attributes.ArmorStartsAt, attack and attack.ArmorStartsAt)
    character:SetAttribute(Attributes.ArmorEndsAt, attack and attack.ArmorEndsAt)
    if state == CombatStates.Idle or state == CombatStates.Dead then
        CollectionService:RemoveTag(character, Config.ActorTag)
        character:SetAttribute(Attributes.AttackId, nil)
        character:SetAttribute(Attributes.Phase, nil)
        character:SetAttribute(Attributes.ActiveEndsAt, nil)
        character:SetAttribute(Attributes.WeaponId, nil)
        return
    end

    character:SetAttribute(Attributes.AttackId, attack and attack.AttackId)
    character:SetAttribute(Attributes.Phase, attack and attack.Phase)
    character:SetAttribute(Attributes.ActiveEndsAt,
        attack and attack.Phase == CombatStates.AttackPhases.Active
            and type(attack.StartedAt) == "number" and type(attack.Duration) == "number"
            and (attack.StartedAt + attack.Duration) or nil)
    character:SetAttribute(Attributes.WeaponId,
        attack and (attack.WeaponId or WeaponRegistry.ResolveFromCharacter(character)) or nil)
    CollectionService:AddTag(character, Config.ActorTag)
end

function CombatVFXService:Init()
    if initialized then
        return
    end
    initialized = true
    if not Config.Enabled then
        return
    end

    PostureService:OnBroken(function(character)
        Broadcast(character, { Result = "PostureBreak" })
    end)
    CombatStateService:OnStateChanged(function(character, state, oldState)
        Publish(character)
        if oldState == CombatStates.Dodging and state ~= CombatStates.Dodging then
            Broadcast(character, { Kind = "CustomAction", Action = "StopDash" })
        end
        if state == CombatStates.Dodging then
            local dodge = CombatStateService:GetDodgeAnimationState(character)
            local root = GetRoot(character)
            Broadcast(character, { Kind = "CustomAction", Action = "Dash",
                Duration = dodge and (dodge.EndsAt - dodge.StartedAt) or 0.3,
                Direction = dodge and root and Directions.ToWorld(root.CFrame, dodge.DirectionId) })
        end
    end)
    CombatStateService:OnAttackPhaseChanged(function(character, _phase, attackId)
        if CombatStateService:GetAttackId(character) == attackId then
            Publish(character)
        end
    end)
    CombatStateService:OnDamageApplied(function(character, outcome, _sourcePosition, impact)
        if outcome.PostureBroken or not Config.Reactions[outcome.Result] then
            return
        end
        local payload = { Result = outcome.Result }
        if impact and impact.MoveId == "Heavy" then
            if outcome.Result == CombatStates.DamageResults.Hit then payload.Reaction = "HeavyImpact" end
            if outcome.Result == CombatStates.DamageResults.Blocked then payload.Reaction = "HeavyBlock" end
        end
        if outcome.Result == CombatStates.DamageResults.Hit and outcome.Damage > 0 and impact then
            payload.Attacker = impact.Attacker
            payload.AttackId = impact.AttackId
            payload.WeaponId = impact.WeaponId
            payload.MoveId = impact.MoveId or "Light1" -- single NPC light attack
        end
        Broadcast(character, payload)
    end)
end

return CombatVFXService
