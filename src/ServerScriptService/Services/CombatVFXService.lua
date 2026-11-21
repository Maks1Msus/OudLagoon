-- Publishes cosmetic state and confirmed impacts for players and NPCs.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Config = require(ReplicatedStorage.Shared.Config.CombatVFXConfig)
local CombatStates = require(ReplicatedStorage.Shared.Constants.CombatStates)
local WeaponRegistry = require(ReplicatedStorage.Shared.Weapons.WeaponRegistry)
local CombatStateService = require(script.Parent.CombatStateService)
local RemoteService = require(script.Parent.RemoteService)

local CombatVFXService = {}
local initialized = false
local Attributes = Config.Attributes

local function GetRoot(character)
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function Publish(character)
    if not character.Parent then
        return
    end

    local state = CombatStateService:GetState(character)
    character:SetAttribute(Attributes.State, state)
    local dodge = CombatStateService:GetDodgeAnimationState(character)
    character:SetAttribute(Attributes.DodgeIFrameEndsAt, dodge and dodge.IFrameEndsAt)
    character:SetAttribute(Attributes.DodgeEndsAt, dodge and dodge.EndsAt)
    if state == CombatStates.Idle or state == CombatStates.Dead then
        CollectionService:RemoveTag(character, Config.ActorTag)
        character:SetAttribute(Attributes.AttackId, nil)
        character:SetAttribute(Attributes.Phase, nil)
        character:SetAttribute(Attributes.ActiveEndsAt, nil)
        character:SetAttribute(Attributes.WeaponId, nil)
        return
    end

    local attack = CombatStateService:GetAttackAnimationState(character)
    character:SetAttribute(Attributes.AttackId, attack and attack.AttackId)
    character:SetAttribute(Attributes.Phase, attack and attack.Phase)
    character:SetAttribute(Attributes.ActiveEndsAt,
        attack and attack.Phase == CombatStates.AttackPhases.Active
            and type(attack.StartedAt) == "number" and type(attack.Duration) == "number"
            and (attack.StartedAt + attack.Duration) or nil)
    character:SetAttribute(Attributes.WeaponId,
        state == CombatStates.Attacking and WeaponRegistry.ResolveFromCharacter(character) or nil)
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

    local event = RemoteService:GetEvent("CombatVFX")
    CombatStateService:OnStateChanged(function(character)
        Publish(character)
    end)
    CombatStateService:OnAttackPhaseChanged(function(character, _phase, attackId)
        if CombatStateService:GetAttackId(character) == attackId then
            Publish(character)
        end
    end)
    CombatStateService:OnDamageApplied(function(character, outcome)
        if not Config.Reactions[outcome.Result] then
            return
        end
        local root = GetRoot(character)
        if not root then
            return
        end

        local position = root.Position
        local payload = {
            Result = outcome.Result,
            Target = character,
            ServerTime = workspace:GetServerTimeNow(),
        }
        for _, player in ipairs(Players:GetPlayers()) do
            local observerRoot = GetRoot(player.Character)
            if observerRoot and (observerRoot.Position - position).Magnitude <= Config.BroadcastDistance then
                event:FireClient(player, payload)
            end
        end
    end)
end

return CombatVFXService
