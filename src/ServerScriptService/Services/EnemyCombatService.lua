-- AI decisions only. All attacks, defense and stun eligibility use the common combat pipeline.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Config = require(ReplicatedStorage.Shared.Config.EnemyConfig)
local MovementAnimations = require(ReplicatedStorage.Shared.Config.MovementAnimationConfig)
local CombatStates = require(ReplicatedStorage.Shared.Constants.CombatStates)
local CombatService = require(script.Parent.CombatService)
local CombatStateService = require(script.Parent.CombatStateService)

local EnemyCombatService = {}
local Entries = {}
local initialized = false
local random = Random.new()

local function StopMove(entry)
    if entry.Humanoid.Parent and entry.Root.Parent then
        entry.Humanoid.AutoRotate = false
        if entry.Moving then entry.Humanoid:MoveTo(entry.Root.Position) end
    end
    entry.Moving = false
    entry.MoveTarget = nil
    entry.NextMoveAt = 0
end

local function MoveTo(entry, position, targetPart)
    local now = os.clock()
    if not entry.Moving or entry.MoveTarget ~= targetPart or now >= (entry.NextMoveAt or 0) then
        entry.Humanoid.AutoRotate = true
        entry.Humanoid:MoveTo(position, targetPart) -- engine follows a moving target between AI decisions
        entry.Moving = true
        entry.MoveTarget = targetPart
        entry.NextMoveAt = now + 0.25
    end
    entry.FacingTarget = nil
end

local function Face(entry, position, deltaTime)
    local root = entry.Root
    local flat = Vector3.new(position.X, root.Position.Y, position.Z)
    if (flat - root.Position).Magnitude > 0.05 then
        root.CFrame = root.CFrame:Lerp(CFrame.lookAt(root.Position, flat),
            1 - math.exp(-entry.Config.TurnResponsiveness * deltaTime))
    end
end

local function InFront(entry, position)
    local offset = position - entry.Root.Position
    local flat = Vector3.new(offset.X, 0, offset.Z)
    local look = entry.Root.CFrame.LookVector
    look = Vector3.new(look.X, 0, look.Z)
    return flat.Magnitude < 0.05 or (look.Magnitude > 0.001
        and flat.Unit:Dot(look.Unit) >= math.cos(math.rad(entry.Config.MaxAttackAngle)))
end

local function FindTarget(entry)
    local nearest, distance = nil, entry.Config.DetectionRange
    for _, player in ipairs(Players:GetPlayers()) do
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if character and character.Parent and humanoid and humanoid.Health > 0 and root then
            local candidate = (root.Position - entry.Root.Position).Magnitude
            if candidate <= distance and (root.Position - entry.Home.Position).Magnitude <= entry.Config.LeashRange then
                nearest, distance = root, candidate
            end
        end
    end
    return nearest, distance
end

local function SetLocomotion(entry, moving)
    local state = CombatStateService:GetState(entry.Model)
    local mode = (state == CombatStates.Ragdolled or state == CombatStates.Dead)
        and "None" or (moving and "Walk" or "Idle")
    if entry.Mode == mode then return end
    entry.Mode = mode
    for name, track in pairs(entry.Tracks) do
        if name == mode then track:Play(0.12) else track:Stop(0.12) end
    end
    if moving and entry.Tracks.Walk then entry.Tracks.Walk:AdjustSpeed(entry.Config.WalkSpeed / 16) end
end

local function Tick(entry)
    local model, humanoid, root, settings = entry.Model, entry.Humanoid, entry.Root, entry.Config
    if not model.Parent or not root.Parent or humanoid.Health <= 0 then
        EnemyCombatService:Unregister(model)
        return
    end
    local profileName = model:GetAttribute("AIProfile") or "Mixed"
    local profile = Config.Profiles[profileName] or Config.Profiles.Mixed
    local state = CombatStateService:GetState(model)
    local now = os.clock()
    if profileName ~= entry.ProfileName then
        entry.ProfileName = profileName
        entry.BlockEndsAt = nil
        entry.NextDecisionAt = now + settings.ReactionTime
        if state == CombatStates.Blocking then CombatStateService:StopBlock(model); state = CombatStateService:GetState(model) end
    end
    if state == CombatStates.Stunned and profile.PerfectParry then
        if CombatStateService:TryComboParry(model) then
            entry.BlockEndsAt = now + settings.ParryDuration
            state = CombatStates.Blocking
        end
    end
    if state == CombatStates.Blocking then
        model:SetAttribute("AIState", "Blocking")
        entry.BlockEndsAt = entry.BlockEndsAt or now + settings.BlockDuration
        if now >= entry.BlockEndsAt then
            CombatStateService:StopBlock(model)
            entry.BlockEndsAt = nil
        end
        return
    end
    entry.BlockEndsAt = nil
    if state ~= CombatStates.Idle then
        model:SetAttribute("AIState", state)
        StopMove(entry)
        SetLocomotion(entry, false)
        return
    end
    if (root.Position - entry.Home.Position).Magnitude > settings.LeashRange then entry.Returning = true end
    if entry.Returning then
        if (root.Position - entry.Home.Position).Magnitude > 2 then
            model:SetAttribute("AIState", "Return")
            MoveTo(entry, entry.Home.Position)
            SetLocomotion(entry, true)
            return
        end
        entry.Returning = false
    end
    local target, distance = FindTarget(entry)
    if not target or profileName == "Passive" then
        model:SetAttribute("AIState", "Idle")
        entry.FacingTarget = nil
        StopMove(entry)
        SetLocomotion(entry, false)
        return
    end
    local _, weapon = CombatService:GetWeapon(model)
    local attackDistance = math.min(settings.AttackRange, weapon.AttackRange)
    local stopDistance = math.max(0.5, attackDistance - Config.ChaseStopPadding)
    local shouldChase = distance > attackDistance or (entry.Moving and distance > stopDistance)
    if shouldChase then
        model:SetAttribute("AIState", profile.Chase and "Chase" or "Idle")
        if profile.Chase then
            MoveTo(entry, target.Position, target)
        else
            StopMove(entry)
            entry.FacingTarget = target
        end
        SetLocomotion(entry, profile.Chase == true)
        entry.NextDecisionAt = math.max(entry.NextDecisionAt, now + settings.ReactionTime)
        return
    end
    model:SetAttribute("AIState", "Combat")
    StopMove(entry)
    entry.FacingTarget = target
    SetLocomotion(entry, false)
    if profile.PerfectParry then
        local snapshot = CombatStateService:GetAttackAnimationState(target.Parent)
        if snapshot and snapshot.Phase == CombatStates.AttackPhases.Startup
            and snapshot.StartedAt + snapshot.Duration - workspace:GetServerTimeNow() <= settings.PerfectParryLead
            and InFront(entry, target.Position) and CombatStateService:StartBlock(model) then
            entry.BlockEndsAt = now + settings.ParryDuration
        end
        return
    end
    if now < entry.NextDecisionAt or not InFront(entry, target.Position) then return end
    entry.NextDecisionAt = now + settings.DecisionInterval
    local parry = profile.ParryChance
    if parry == nil then parry = settings.ParryChance end
    local block = profile.BlockChance
    if block == nil then block = settings.BlockChance end
    local roll = random:NextNumber()
    if roll < parry + block then
        if CombatStateService:StartBlock(model) then
            entry.BlockEndsAt = now + (roll < parry and settings.ParryDuration or settings.BlockDuration)
        end
    elseif profile.Attack and now >= entry.NextAttackAt then
        if CombatService:PerformNPCAttack(model, { Strength = settings.Strength }) then
            entry.NextAttackAt = now + settings.AttackCooldown
        end
    end
end

function EnemyCombatService:Register(model, settings, home)
    if Entries[model] then return end
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    local entry = { Model = model, Humanoid = humanoid, Root = model:FindFirstChild("HumanoidRootPart"),
        Home = home, Config = settings, Tracks = {}, Animations = {}, NextMoveAt = 0,
        NextAttackAt = 0, NextDecisionAt = os.clock() + settings.ReactionTime }
    local animator = humanoid:FindFirstChildOfClass("Animator")
    for mode, slot in pairs({ Idle = "Idle", Walk = "WalkForward" }) do
        local id = MovementAnimations.GetAnimationId(slot)
        if animator and MovementAnimations.IsAssigned(slot) then
            local animation = Instance.new("Animation")
            animation.AnimationId = id
            local ok, track = pcall(function() return animator:LoadAnimation(animation) end)
            if ok then
                track.Looped = true
                track.Priority = mode == "Idle" and Enum.AnimationPriority.Idle or Enum.AnimationPriority.Movement
                entry.Tracks[mode] = track
                table.insert(entry.Animations, animation)
            else animation:Destroy() end
        end
    end
    Entries[model] = entry
    SetLocomotion(entry, false)
end

function EnemyCombatService:Unregister(model)
    local entry = Entries[model]
    if not entry then return end
    Entries[model] = nil
    StopMove(entry)
    for _, track in pairs(entry.Tracks) do track:Stop(0); track:Destroy() end
    for _, animation in ipairs(entry.Animations) do animation:Destroy() end
end

function EnemyCombatService:Init()
    if initialized then return end
    initialized = true
    CombatStateService:OnStateChanged(function(model, state)
        local entry = Entries[model]
        if not entry then return end
        if state ~= CombatStates.Idle then
            StopMove(entry)
            SetLocomotion(entry, false)
        end
        if state ~= CombatStates.Blocking then entry.BlockEndsAt = nil end
        if state == CombatStates.Idle then
            entry.NextDecisionAt = math.max(entry.NextDecisionAt, os.clock() + entry.Config.ReactionTime)
        end
    end)
    local elapsed = 0
    RunService.Heartbeat:Connect(function(deltaTime)
        elapsed = elapsed + deltaTime
        local think = elapsed >= Config.TickInterval
        if think then elapsed = 0 end
        for _, entry in pairs(Entries) do
            if think then Tick(entry) end
            -- Writing RootPart.CFrame cancels MoveTo. Only rotate manually while stationary.
            local target = entry.FacingTarget
            if Entries[entry.Model] == entry and not entry.Moving and target and target.Parent
                and CombatStateService:GetState(entry.Model) == CombatStates.Idle then
                Face(entry, target.Position, deltaTime)
            end
        end
    end)
end

return EnemyCombatService
