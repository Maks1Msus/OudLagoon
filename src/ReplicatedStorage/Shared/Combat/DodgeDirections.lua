-- Shared eight-way input vocabulary and horizontal direction helpers.
local DodgeDirections = {}
local vectors = {
    Forward = Vector3.new(0, 0, -1), Backward = Vector3.new(0, 0, 1),
    Left = Vector3.new(-1, 0, 0), Right = Vector3.new(1, 0, 0),
    ForwardLeft = Vector3.new(-1, 0, -1).Unit,
    ForwardRight = Vector3.new(1, 0, -1).Unit,
    BackwardLeft = Vector3.new(-1, 0, 1).Unit,
    BackwardRight = Vector3.new(1, 0, 1).Unit,
}

function DodgeDirections.IsValidId(id)
    return type(id) == "string" and vectors[id] ~= nil
end

function DodgeDirections.ToWorld(cframe, id)
    local vector = vectors[id]
    if not vector then return nil end
    local world = cframe:VectorToWorldSpace(vector)
    local flat = Vector3.new(world.X, 0, world.Z)
    return flat.Magnitude > 0.001 and flat.Unit or nil
end

-- Preserve the selected dash type relative to a horizontally projected camera heading.
function DodgeDirections.FromFacing(facing, id)
    local vector = vectors[id]
    if not vector then return nil end
    local flat = Vector3.new(facing.X, 0, facing.Z)
    if flat.Magnitude < 0.001 then return nil end
    local forward = flat.Unit
    local right = Vector3.new(-forward.Z, 0, forward.X)
    return (right * vector.X - forward * vector.Z).Unit
end

-- Limit angular speed per step, not the total turn since the dash started.
function DodgeDirections.TurnToward(current, desired, settings, deltaTime)
    local flat = Vector3.new(desired.X, 0, desired.Z)
    if flat.Magnitude < 0.001 or deltaTime <= 0 then return current end
    local heading = math.atan2(current.X, -current.Z)
    local target = math.atan2(flat.X, -flat.Z)
    local difference = (target - heading + math.pi) % (2 * math.pi) - math.pi
    local step = difference * (1 - math.exp(-settings.Responsiveness * deltaTime))
    local limit = math.rad(settings.MaxTurnRate) * deltaTime
    heading = heading + math.clamp(step, -limit, limit)
    return Vector3.new(math.sin(heading), 0, -math.cos(heading))
end

function DodgeDirections.FromLocalVector(vector)
    if vector.Magnitude < 0.05 then return "Forward" end
    local angle = math.atan2(vector.X, -vector.Z)
    local sector = math.floor(angle / (math.pi / 4) + 0.5) % 8
    return ({ "Forward", "ForwardRight", "Right", "BackwardRight",
        "Backward", "BackwardLeft", "Left", "ForwardLeft" })[sector + 1]
end

function DodgeDirections.AnimationSlot(id)
    if id == "ForwardLeft" or id == "ForwardRight" then return "DodgeForward" end
    if id == "BackwardLeft" or id == "BackwardRight" then return "DodgeBackward" end
    return DodgeDirections.IsValidId(id) and ("Dodge" .. id) or "DodgeForward"
end

return DodgeDirections
