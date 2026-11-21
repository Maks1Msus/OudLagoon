-- Owner executes predicted movement. Server validates state, displacement and collision.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CombatStateService = require(script.Parent.CombatStateService)
local CombatStates = require(ReplicatedStorage.Shared.Constants.CombatStates)
local Config = require(ReplicatedStorage.Shared.Config.DashConfig)
local Directions = require(ReplicatedStorage.Shared.Combat.DodgeDirections)
local MovementConfig = require(ReplicatedStorage.Shared.Config.CombatStateConfig).Movement
local MovementSettings = require(ReplicatedStorage.Shared.Config.MovementAnimationConfig).Settings
local WeaponRegistry = require(ReplicatedStorage.Shared.Weapons.WeaponRegistry)

local DashService = {}
local Active = {}
local initialized = false

function DashService.IsValidDirection(id)
    return Directions.IsValidId(id)
end

local function Finish(character, record)
    if Active[character] == record then Active[character] = nil end
    -- Normal completion is handled locally, without changing network ownership.
end

local function Stop(character, record)
    Finish(character, record)
    if record.Id then CombatStateService:EndDodge(character, record.Id) end
end

local function RejectMovement(character, record)
    local root = record.Root
    if root.Parent and not root.Anchored then
        -- Exceptional correction only: excess distance or crossing collidable geometry.
        root:SetNetworkOwner(nil)
        local current = root.Position
        root.CFrame = root.CFrame + Vector3.new(record.LastPosition.X - current.X, 0,
            record.LastPosition.Z - current.Z)
        root.AssemblyLinearVelocity = Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
        task.delay(0.1, function()
            if root.Parent and not root.Anchored and not Active[character]
                and record.Player.Parent == Players then
                pcall(function() root:SetNetworkOwnershipAuto() end)
            end
        end)
    end
    Stop(character, record)
end

function DashService:GetDirection(character)
    local record = Active[character]
    return record and record.Direction
end

function DashService:EndMovement(player, dashId)
    local character = player.Character
    local record = character and Active[character]
    if not record or record.Id ~= dashId then return false, "StaleDodge" end
    -- Client completion cannot shorten authoritative combat restrictions.
    if workspace:Blockcast(record.Root.CFrame, record.Root.Size * 0.8,
        record.Direction * Config.CollisionPadding, record.Raycast) then
        Stop(character, record)
        return true
    end
    return false, "DashStillActive"
end

function DashService:Steer(player, directionId)
    if not Directions.IsValidId(directionId) then return false, "InvalidDirection" end
    local character = player.Character
    local record = character and Active[character]
    if not record or not record.Started or CombatStateService:GetDodgeId(character) ~= record.Id then
        return false, "NoActiveDash"
    end
    if os.clock() < record.NextSteerAt then return false, "RateLimited" end
    record.NextSteerAt = os.clock() + Config.SteeringRequestInterval
    record.Direction = Directions.ToWorld(record.Root.CFrame, directionId) or record.Direction
    return true
end

function DashService:PerformDodge(player, directionId, requestId)
    if not Directions.IsValidId(directionId) then return false, "InvalidDirection" end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not character or not character.Parent or not humanoid or humanoid.Health <= 0
        or not root or root.Anchored or humanoid.Sit then
        return false, "CharacterUnavailable"
    end
    local allowed, reason = CombatStateService:CanDodge(character, directionId)
    if not allowed then return false, reason end
    if not root:CanSetNetworkOwnership() then return false, "PhysicsUnavailable" end
    local direction = Directions.ToWorld(root.CFrame, directionId)
    if not direction then return false, "InvalidDirection" end
    local profile = Config.GetProfile(directionId)
    -- Normal locomotion can resume before the replicated Dodging state ends.
    local baseSpeed = humanoid:GetAttribute(MovementConfig.BaseSpeedAttribute) or humanoid.WalkSpeed
    local locomotionAllowance = baseSpeed * math.max(1, MovementSettings.SprintSpeedMultiplier) * profile.Duration
    local record = {
        Root = root, Player = player, Profile = profile, Direction = direction,
        DirectionId = directionId, RequestId = requestId,
        WeaponId = WeaponRegistry.ResolveFromCharacter(character),
        Distance = 0, LocomotionAllowance = locomotionAllowance,
        LastPosition = root.Position, NextSteerAt = 0,
    }
    local prepared, errorMessage = pcall(function()
        if root:GetNetworkOwner() ~= player then root:SetNetworkOwner(player) end
        record.Raycast = RaycastParams.new()
        record.Raycast.FilterType = Enum.RaycastFilterType.Exclude
        record.Raycast.FilterDescendantsInstances = { character }
        record.Raycast.RespectCanCollide = true
        record.Raycast.IgnoreWater = true
        record.Raycast.CollisionGroup = root.CollisionGroup
    end)
    if not prepared then
        Finish(character, record)
        warn("[DashService] Could not prepare dash:", errorMessage)
        return false, "PhysicsUnavailable"
    end

    local started, id = CombatStateService:StartDodge(character, directionId)
    if not started or CombatStateService:GetDodgeId(character) ~= id then
        Finish(character, record)
        return false, started and "DodgeInterrupted" or id
    end
    record.Id = id
    record.Started = true
    record.EndsAt = os.clock() + profile.Duration
    Active[character] = record
    return true, id
end

function DashService:CanConvertToAttack(character, dashId)
    local record = Active[character]
    if not record or record.Id ~= dashId or record.DirectionId ~= "Forward"
        or record.Consumed or record.Player.Character ~= character then
        return false, "NoForwardDash"
    end
    if WeaponRegistry.ResolveFromCharacter(character) ~= record.WeaponId then
        return false, "WeaponChanged"
    end
    local allowed, reason = CombatStateService:CanDashAttack(character, dashId)
    if not allowed then return false, reason end
    return true, record.WeaponId
end

function DashService:GetMomentum(character, dashId, duration)
    local record = Active[character]
    if not record or record.Id ~= dashId then return nil end
    local config = Config.Forward.AttackConversion
    local v = record.Root.AssemblyLinearVelocity
    local x, z = v.X, v.Z
    if x ~= x or z ~= z or math.abs(x) == math.huge or math.abs(z) == math.huge then x, z = 0, 0 end
    local speed = math.sqrt(x*x + z*z)
    local scale = speed > 0 and math.min(1, config.MomentumMaxSpeed / speed) * config.MomentumRetention or 0
    return {
        DodgeId = dashId, Duration = duration,
        Retention = config.MomentumRetention, MaxSpeed = config.MomentumMaxSpeed,
        Velocity = Vector3.new(x * scale, 0, z * scale),
    }
end

function DashService:RequestAttack(player, requestId, convert, late)
    local character = player.Character
    local record = character and Active[character]
    local config = Config.Forward.AttackConversion
    if not record or record.RequestId ~= requestId or record.DirectionId ~= "Forward"
        or not config.Enabled or record.Consumed then return false, "NoForwardDash" end
    if record.ConversionQueued or record.LateAttack then return false, "AlreadyBuffered" end
    if WeaponRegistry.ResolveFromCharacter(character) ~= record.WeaponId then return false, "WeaponChanged" end
    local elapsed = CombatStateService:GetDodgeElapsed(character, record.Id)
    if not elapsed then return false, "StaleDodge" end
    if elapsed > config.WindowEnd + 0.000001 then
        record.LateAttack = late
        return true, "AttackAfterDash"
    end
    local delay = math.max(0, config.WindowStart - elapsed)
    if delay > config.Buffer then return false, "TooEarly" end
    record.ConversionQueued = true
    local function run()
        if Active[character] ~= record or player.Character ~= character then return false, "StaleDodge" end
        local ok, reason = convert(record.Id)
        if not ok then record.ConversionQueued = false end
        return ok, reason
    end
    if delay > 0.000001 then
        task.delay(delay, run)
        return true, "BufferedDashAttack"
    end
    return run()
end

function DashService:Init()
    if initialized then return end
    initialized = true
    Config.Validate()
    CombatStateService:OnStateChanged(function(character, state)
        if state ~= CombatStates.Dodging and Active[character] then
            local record = Active[character]
            record.Consumed = state == CombatStates.Attacking
            Finish(character, record) -- only a successful state transition consumes the dash
            if state == CombatStates.Idle and record.LateAttack then
                task.defer(function()
                    if record.Player.Parent == Players and record.Player.Character == character
                        and character.Parent and CombatStateService:GetState(character) == CombatStates.Idle
                        and WeaponRegistry.ResolveFromCharacter(character) == record.WeaponId then
                        record.LateAttack()
                    end
                end)
            end
        end
    end)
    RunService.PreSimulation:Connect(function(deltaTime)
        for character, record in pairs(Active) do
            local root = record.Root
            local humanoid = character:FindFirstChildOfClass("Humanoid")
            if not character.Parent or not root.Parent or root.Anchored or not humanoid
                or humanoid.Health <= 0 or os.clock() >= record.EndsAt
                or CombatStateService:GetDodgeId(character) ~= record.Id then
                Stop(character, record)
            else
                local delta = root.Position - record.LastPosition
                local horizontal = Vector3.new(delta.X, 0, delta.Z)
                local distance = horizontal.Magnitude
                local total = record.Distance + distance
                local blocked = distance > 0.001 and workspace:Blockcast(
                    root.CFrame + (record.LastPosition - root.Position), root.Size * 0.8,
                    horizontal, record.Raycast)
                if total > record.Profile.Distance + record.LocomotionAllowance + Config.DistanceTolerance or blocked then
                    RejectMovement(character, record)
                else
                    record.Distance = total
                    record.LastPosition = root.Position
                    if distance > 0.001 then record.Direction = horizontal.Unit end
                end
            end
        end
    end)
end

return DashService
