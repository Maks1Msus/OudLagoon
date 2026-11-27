-- Server confirms when and where a sound happens. Clients resolve only configured clip keys.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config.CombatSFXConfig)
local States = require(ReplicatedStorage.Shared.Constants.CombatStates)
local WeaponRegistry = require(ReplicatedStorage.Shared.Weapons.WeaponRegistry)
local CombatStateService = require(script.Parent.CombatStateService)
local RemoteService = require(script.Parent.RemoteService)
local PostureService = require(script.Parent.PostureService)
local Service = {}
local initialized = false
local sequence = 0

local function Play(character, key, identity)
    if not Config.Enabled or not Config.Get(key) then return end
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then return end
    sequence = sequence + 1
    local payload = { Character = character, Key = key, Id = sequence, ServerTime = workspace:GetServerTimeNow(),
        AttackId = identity and identity.AttackId, DashRequestId = identity and identity.DashRequestId,
        DodgeId = identity and identity.DodgeId }
    local event = RemoteService:GetEvent("CombatSFX")
    for _, player in ipairs(Players:GetPlayers()) do
        local observerRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
        if observerRoot and (observerRoot.Position - root.Position).Magnitude <= Config.BroadcastDistance then
            event:FireClient(player, payload)
        end
    end
end

function Service:Init()
    if initialized then return end
    Config.Validate()
    initialized = true
    if not Config.Enabled then return end
    PostureService:OnChanged(function(character, value, _, reason)
        if reason == "Parried" and value > 0 then Play(character, "ParryPressure") end
    end)
    PostureService:OnBroken(function(character) Play(character, "PostureBreak") end)
    CombatStateService:OnStateChanged(function(character, state, oldState)
        -- Attacking -> Attacking is a combo link, not another state-entry sound.
        if state == oldState then return end
        if oldState == States.Blocking and state == States.Idle then Play(character, "BlockEnd") end
        if state == States.Stunned then
            local stun = CombatStateService:GetStunAnimationState(character)
            if stun and stun.Source == "PostureBreak" then return end
        end
        if state == States.Attacking then
            local _, moveId = CombatStateService:GetAttackIdentity(character)
            if moveId == "Heavy" then Play(character, "HeavyWindup") end
        end
        local dodge = state == States.Dodging and CombatStateService:GetDodgeAnimationState(character)
        Play(character, Config.States[state], dodge and { DashRequestId = dodge.RequestId, DodgeId = dodge.Id })
    end)
    CombatStateService:OnAttackPhaseChanged(function(character, phase, attackId)
        if phase ~= States.AttackPhases.Active or CombatStateService:GetAttackId(character) ~= attackId then return end
        local _, moveId = CombatStateService:GetAttackIdentity(character)
        local attack = CombatStateService:GetAttackAnimationState(character)
        local weaponId = attack.WeaponId or WeaponRegistry.ResolveFromCharacter(character)
        local moves = Config.Attacks[weaponId]
        Play(character, moves and moves[moveId or "Light1"], { AttackId = attackId })
    end)
    CombatStateService:OnDamageApplied(function(character, outcome, _position, impact)
        if outcome.Result == States.DamageResults.Hit and outcome.Damage > 0 then
            local moves = impact and Config.Hits[impact.WeaponId]
            Play(character, moves and moves[impact.MoveId or "Light1"] or "Hit1")
        elseif outcome.Result == States.DamageResults.Blocked and not outcome.PostureBroken then
            Play(character, impact and impact.MoveId == "Heavy" and "HeavyBlock" or "BlockHit")
        elseif outcome.Result == States.DamageResults.Parried then
            Play(character, "Parry")
        end
    end)
end

return Service
