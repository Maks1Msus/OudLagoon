-- Predicts owner movement only. Combat state and invulnerability remain server-owned.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config.DashConfig)
local MovementConfig = require(Shared.Config.CombatStateConfig).Movement
local Directions = require(Shared.Combat.DodgeDirections)
local Motion = require(Shared.Combat.DashMotion)
local MovementSettings = require(Shared.Config.MovementAnimationConfig).Settings
local player = Players.LocalPlayer
local Request = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Events"):WaitForChild("CombatStateRequest")
local Controller = {}
local active, pending, latest, lunge
local lastLungeAttackId
local serial = 0
local cooldowns = {}

local function LocomotionVelocity(record)
    local humanoid = record.Humanoid
    local move = humanoid.MoveDirection
    local direction = Vector3.new(move.X, 0, move.Z)
    if direction.Magnitude < 0.05 then return Vector3.new(0, 0, 0) end
    local state = humanoid:GetAttribute(MovementConfig.StateAttribute)
    if state == "Attacking" or state == "Stunned" or state == "Dead" then
        return Vector3.new(0, 0, 0)
    end
    local base = humanoid:GetAttribute(MovementConfig.BaseSpeedAttribute) or 16
    local speed = humanoid:GetAttribute(Config.LocomotionSpeedAttribute) or base
    if not record.PreserveSprint then speed = math.min(speed, base) end
    return direction.Unit * speed
end

local function Stop(record, completed)
    if active ~= record then return end
    active = nil
    record.StopVelocity = record.Root.AssemblyLinearVelocity
    record.Finished = true
    if record.ServerId then Request:FireServer("DashEnd", record.ServerId) end
    if record.Humanoid.Parent then
        record.Humanoid:SetAttribute(Config.MotionFinishedAttribute, completed == true)
        record.Humanoid:SetAttribute(Config.PredictionAttribute, nil)
        record.Humanoid:SetAttribute(Config.PreserveSprintAttribute, nil)
    end
    if record.Root.Parent and not record.Root.Anchored then
        local v = record.Root.AssemblyLinearVelocity
        local target = completed and LocomotionVelocity(record) or Vector3.new(0, 0, 0)
        record.Root.AssemblyLinearVelocity = Vector3.new(target.X, v.Y, target.Z)
    end
end

local function Start(record, direction)
    local character = record.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not humanoid or humanoid.Health <= 0 or not root or root.Anchored or humanoid.Sit then return false end
    direction = direction or Directions.ToWorld(root.CFrame, record.DirectionId)
    if not direction then return false end
    local v = root.AssemblyLinearVelocity
    record.Root, record.Humanoid = root, humanoid
    record.Direction = direction
    record.StartSpeed = math.clamp(v.X * direction.X + v.Z * direction.Z,
        0, 2 * record.Profile.Distance / record.Profile.Duration)
    record.Elapsed, record.Distance = 0, 0
    record.LastPosition = root.Position
    record.Raycast = RaycastParams.new()
    record.Raycast.FilterType = Enum.RaycastFilterType.Exclude
    record.Raycast.FilterDescendantsInstances = { character }
    record.Raycast.RespectCanCollide = true
    record.Raycast.IgnoreWater = true
    record.Raycast.CollisionGroup = root.CollisionGroup
    record.PreserveSprint = record.DirectionId == "Forward"
        and humanoid:GetAttribute(MovementConfig.StateAttribute) ~= "Blocking"
        and humanoid:GetAttribute(MovementConfig.StateAttribute) ~= "Attacking"
        and humanoid:GetAttribute(Config.SprintIntentAttribute) == true
    humanoid:SetAttribute(Config.PreserveSprintAttribute, record.PreserveSprint)
    humanoid:SetAttribute(Config.MotionFinishedAttribute, nil)
    active = record
    humanoid:SetAttribute(Config.PredictionAttribute, true)
    return true
end

function Controller.Request(directionId, predict)
    if active or pending or lunge or not Directions.IsValidId(directionId) then return nil end
    local profile = Config.GetProfile(directionId)
    if os.clock() < (cooldowns[profile.CooldownGroup] or 0) then return nil end
    serial = serial % 2147483646 + 1
    local record = {
        RequestId = serial, Character = player.Character, DirectionId = directionId,
        Profile = profile, RequestedAt = os.clock(), Predicted = predict == true,
    }
    if predict and not Start(record) then return nil end
    pending = record
    latest = record
    cooldowns[profile.CooldownGroup] = os.clock() + profile.Cooldown
    return serial
end

function Controller.GetAttackRequestId()
    if latest and latest.Character == player.Character and latest.DirectionId == "Forward" then
        return latest.RequestId
    end
    return nil
end

local function StopLunge(record, completed)
    if lunge ~= record then return end
    lunge = nil
    if record.Humanoid.Parent then record.Humanoid:SetAttribute(Config.DashAttackAttribute, nil) end
    if record.Root.Parent and not record.Root.Anchored then
        local target = Vector3.new(0, 0, 0)
        if completed then
            local move = record.Humanoid.MoveDirection
            local flat = Vector3.new(move.X, 0, move.Z)
            local base = record.Humanoid:GetAttribute(MovementConfig.BaseSpeedAttribute) or 16
            if flat.Magnitude > 0.05 then target = flat.Unit * base * MovementConfig.States.Attacking.WalkSpeedMultiplier end
        end
        local v = record.Root.AssemblyLinearVelocity
        record.Root.AssemblyLinearVelocity = Vector3.new(target.X, v.Y, target.Z)
    end
end

local function StartLunge(payload, momentum)
    if payload.AttackId == lastLungeAttackId then return end
    lastLungeAttackId = payload.AttackId
    if lunge then StopLunge(lunge) end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not humanoid or humanoid.Health <= 0 or not root or root.Anchored then return end
    local state = humanoid:GetAttribute(MovementConfig.StateAttribute)
    if state == "Stunned" or state == "Dead" then return end
    local elapsed = math.max(0, workspace:GetServerTimeNow() - payload.AttackAnimation.StartedAt)
    if elapsed >= momentum.Duration then return end
    local velocity = momentum.Velocity
    if latest and latest.Character == character and latest.ServerId == momentum.DodgeId and latest.StopVelocity then
        local v = latest.StopVelocity
        local speed = math.sqrt(v.X*v.X + v.Z*v.Z)
        if speed == speed and speed < math.huge then
            local scale = speed > 0 and math.min(1, momentum.MaxSpeed / speed) * momentum.Retention or 0
            velocity = Vector3.new(v.X * scale, 0, v.Z * scale)
        end
    end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { character }
    params.RespectCanCollide = true
    params.IgnoreWater = true
    params.CollisionGroup = root.CollisionGroup
    lunge = { Character = character, Root = root, Humanoid = humanoid, Id = payload.AttackId,
        Velocity = velocity, Elapsed = elapsed, Duration = momentum.Duration, Raycast = params }
    humanoid:SetAttribute(Config.DashAttackAttribute, true)
end

function Controller.OnPayload(payload)
    if type(payload) ~= "table" then return end
    if payload.Character and payload.Character ~= player.Character then return end
    local reply = payload.DashReply
    if reply and pending and reply.Character == player.Character and reply.RequestId == pending.RequestId then
        local record = pending
        pending = nil
        cooldowns[record.Profile.CooldownGroup] = os.clock() + math.max(0, reply.CooldownRemaining or 0)
        if not reply.Accepted then
            Stop(record)
            return
        end
        record.ServerId = reply.DashId
        record.Accepted = true
        record.SeenDodge = true
        if record.Finished then Request:FireServer("DashEnd", reply.DashId) end
        -- A delayed confirmation must never replay movement which already finished locally.
        if not active and not record.Finished and record.Character == player.Character then
            Start(record, reply.Direction)
        end
    end
    local momentum = payload.AttackAnimation and payload.AttackAnimation.DashMomentum
    if payload.State == "Attacking" and payload.MoveId == "DashLight" and momentum then
        if active then Stop(active) end
        StartLunge(payload, momentum)
        return
    end
    if lunge and payload.State and (payload.State ~= "Attacking" or payload.AttackId ~= lunge.Id) then
        StopLunge(lunge)
    end
    local record = active
    if not record then return end
    if payload.State == "Dodging" and payload.DodgeAnimation then
        record.ServerId = payload.DodgeAnimation.Id
        record.SeenDodge = true
    elseif payload.State == "Stunned" or payload.State == "Dead" or payload.State == "Attacking"
        or (payload.State == "Idle" and record.SeenDodge) then
        Stop(record, payload.State == "Idle")
    end
end

function Controller.IsMoving()
    return active ~= nil
end

RunService.PreSimulation:Connect(function(deltaTime)
    if pending and os.clock() - pending.RequestedAt > Config.PredictionTimeout then
        Stop(pending)
        pending = nil
    end
    if lunge then
        local record = lunge
        local root, humanoid = record.Root, record.Humanoid
        local state = humanoid:GetAttribute(MovementConfig.StateAttribute)
        if record.Character ~= player.Character or not root.Parent or root.Anchored or not humanoid.Parent
            or humanoid.Health <= 0 or state == "Stunned" or state == "Dead" then
            StopLunge(record)
        elseif record.Elapsed >= record.Duration then
            StopLunge(record, true)
        else
            local t = math.clamp(record.Elapsed / record.Duration, 0, 1)
            local velocity = record.Velocity * (1 - t)
            local step = velocity * math.max(0, deltaTime)
            local direction = velocity.Magnitude > 0.001 and velocity.Unit or Vector3.new(0, 0, 0)
            if velocity.Magnitude > 0.001 and workspace:Blockcast(root.CFrame, root.Size * 0.8,
                step + direction * Config.CollisionPadding, record.Raycast) then
                StopLunge(record)
            else
                local v = root.AssemblyLinearVelocity
                root.AssemblyLinearVelocity = Vector3.new(velocity.X, v.Y, velocity.Z)
                record.Elapsed = record.Elapsed + math.max(0, deltaTime)
            end
        end
    end
    local record = active
    if not record then return end
    local root, humanoid = record.Root, record.Humanoid
    local state = humanoid:GetAttribute(MovementConfig.StateAttribute)
    if record.Character ~= player.Character or not root.Parent or root.Anchored
        or not humanoid.Parent or humanoid.Health <= 0 or state == "Stunned" or state == "Dead"
        or (state == "Attacking" and record.Predicted) then
        Stop(record)
        return
    end
    if record.Elapsed >= record.Profile.Duration then
        Stop(record, true)
        return
    end
    local delta = root.Position - record.LastPosition
    record.Distance = record.Distance + Vector3.new(delta.X, 0, delta.Z).Magnitude
    record.LastPosition = root.Position
    local remaining = record.Profile.Distance - record.Distance
    local settings = record.Profile.Steering
    if settings.Enabled then
        local shiftLock = player:GetAttribute(MovementSettings.ShiftLockAttribute)
        if type(shiftLock) ~= "boolean" then
            shiftLock = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
        end
        local desired
        local camera = workspace.CurrentCamera
        if shiftLock and camera then
            desired = Directions.FromFacing(camera.CFrame.LookVector, record.DirectionId)
        else
            local move = humanoid.MoveDirection
            local flat = Vector3.new(move.X, 0, move.Z)
            if flat.Magnitude > 0.05 then desired = flat.Unit end
        end
        if desired then
            record.Direction = Directions.TurnToward(record.Direction, desired, settings, deltaTime)
        end
    end
    local speed = Motion.SpeedForStep(record.Profile, Config.SpeedProfile, record.Elapsed, deltaTime, record.StartSpeed)
    record.Elapsed = record.Elapsed + math.max(0, deltaTime)
    local duration = math.min(Config.HandoffDuration, record.Profile.Duration)
    local progress = math.clamp((record.Elapsed - (record.Profile.Duration - duration)) / duration, 0, 1)
    local weight = progress * progress * (3 - 2 * progress)
    local locomotion = LocomotionVelocity(record)
    if locomotion.Magnitude < 0.05 then weight = 0 end
    local velocity = record.Direction * speed * (1 - weight) + locomotion * weight
    local step = velocity * math.max(0, deltaTime)
    if (remaining <= 0.001 and weight == 0) or workspace:Blockcast(root.CFrame, root.Size * 0.8,
        step + (velocity.Magnitude > 0.001 and velocity.Unit or record.Direction) * Config.CollisionPadding,
        record.Raycast) then
        Stop(record)
    else
        local current = root.AssemblyLinearVelocity
        root.AssemblyLinearVelocity = Vector3.new(velocity.X, current.Y, velocity.Z)
    end
end)

player.CharacterAdded:Connect(function()
    if active then Stop(active) end
    if lunge then StopLunge(lunge) end
    latest = nil
    lastLungeAttackId = nil
    pending = nil
    cooldowns = {}
end)

return Controller
