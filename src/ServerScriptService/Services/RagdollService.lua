-- Physical projection of CombatStateService.Ragdolled; owns no combat timers/state.
local CombatStateService = require(script.Parent.CombatStateService)
local States = require(game:GetService("ReplicatedStorage").Shared.Constants.CombatStates)
local RagdollService = {}
local Entries = {}
local initialized = false
local BodyNames = {
    Head = true, Torso = true, ["Right Arm"] = true, ["Left Arm"] = true,
    ["Right Leg"] = true, ["Left Leg"] = true,
    UpperTorso = true, LowerTorso = true,
    RightUpperArm = true, RightLowerArm = true, RightHand = true,
    LeftUpperArm = true, LeftLowerArm = true, LeftHand = true,
    RightUpperLeg = true, RightLowerLeg = true, RightFoot = true,
    LeftUpperLeg = true, LeftLowerLeg = true, LeftFoot = true,
}

local function Restore(character, destroyed)
    local entry = Entries[character]
    if not entry then return end
    Entries[character] = nil
    entry.Connection:Disconnect()
    if destroyed then return end
    for motor, enabled in pairs(entry.Motors) do
        if motor.Parent then motor.Enabled = enabled end
    end
    for _, object in ipairs(entry.Created) do object:Destroy() end
    for part, canCollide in pairs(entry.Collisions) do
        if part.Parent then part.CanCollide = canCollide end
    end
    local humanoid = entry.Humanoid
    if humanoid.Parent then
        humanoid.RequiresNeck = entry.RequiresNeck
        humanoid.PlatformStand = entry.PlatformStand
        humanoid.AutoRotate = entry.AutoRotate
        if humanoid.Health > 0 and not entry.PlatformStand then
            humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
        end
    end
    if entry.Root.Parent and entry.OwnershipSaved then
        pcall(function()
            if entry.AutomaticOwnership then entry.Root:SetNetworkOwnershipAuto()
            else entry.Root:SetNetworkOwner(entry.Owner) end
        end)
    end
end

local function Start(character)
    if Entries[character] then return end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
    local data = CombatStateService:GetRagdollData(character)
    if not humanoid or not root or not data then return end
    local entry = {
        Humanoid = humanoid, Root = root, Motors = {}, Created = {}, Collisions = {},
        RequiresNeck = humanoid.RequiresNeck, PlatformStand = humanoid.PlatformStand,
        AutoRotate = humanoid.AutoRotate,
    }
    Entries[character] = entry
    entry.Connection = character.Destroying:Connect(function() Restore(character, true) end)
    entry.OwnershipSaved = pcall(function()
        entry.AutomaticOwnership = root:GetNetworkOwnershipAuto()
        entry.Owner = root:GetNetworkOwner()
        root:SetNetworkOwner(nil)
    end)
    humanoid.RequiresNeck = false -- disable before disconnecting the Neck motor
    humanoid.AutoRotate = false
    humanoid.PlatformStand = true
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if animator then
        for _, track in ipairs(animator:GetPlayingAnimationTracks()) do track:Stop(0.05) end
    end
    local function Create(class, parent)
        local object = Instance.new(class)
        object.Name = "CombatRagdoll"
        object.Parent = parent
        table.insert(entry.Created, object)
        return object
    end
    local bodies = {}
    for _, part in ipairs(character:GetChildren()) do
        if part:IsA("BasePart") and BodyNames[part.Name] then
            table.insert(bodies, part)
            entry.Collisions[part] = part.CanCollide
            part.CanCollide = true
        end
    end
    -- Keep the root/torso joint and weapon grip intact. Only body joints become physical.
    for _, motor in ipairs(character:GetDescendants()) do
        local p0, p1
        if motor:IsA("Motor6D") then p0, p1 = motor.Part0, motor.Part1 end
        if p0 and p1 and p0.Parent == character and p1.Parent == character
            and BodyNames[p0.Name] and BodyNames[p1.Name] and motor.Enabled then
            local a0, a1 = Create("Attachment", p0), Create("Attachment", p1)
            a0.CFrame = p0.CFrame:ToObjectSpace(p1.CFrame * motor.C1)
            a1.CFrame = motor.C1
            local socket = Create("BallSocketConstraint", p0)
            socket.Attachment0, socket.Attachment1 = a0, a1
            socket.LimitsEnabled = true
            socket.UpperAngle = 65
            socket.TwistLimitsEnabled = true
            socket.TwistLowerAngle, socket.TwistUpperAngle = -45, 45
            entry.Motors[motor] = motor.Enabled
            motor.Enabled = false
        end
    end
    -- Collide with the arena, but never let the character's own body parts fight each other.
    for i, a in ipairs(bodies) do
        for j = i + 1, #bodies do
            local constraint = Create("NoCollisionConstraint", a)
            constraint.Part0, constraint.Part1 = a, bodies[j]
        end
    end
    local seen = {}
    table.insert(bodies, root)
    for _, part in ipairs(bodies) do
        local assembly = part.AssemblyRootPart or part
        if not seen[assembly] and not assembly.Anchored then
            seen[assembly] = true
            pcall(function() assembly:SetNetworkOwner(nil) end)
            assembly:ApplyImpulse((data.Velocity - assembly.AssemblyLinearVelocity) * assembly.AssemblyMass)
        end
    end
end

function RagdollService:Init()
    if initialized then return end
    initialized = true
    CombatStateService:OnStateChanged(function(character, state)
        if state == States.Ragdolled then Start(character)
        elseif state ~= States.Dead then Restore(character, false) end
        -- A corpse stays physical until removed; an old ragdoll timer cannot revive it.
    end)
end

return RagdollService
