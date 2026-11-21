-- Bounded server-side extrapolation of the attacker's replicated horizontal position.
-- No client-supplied pose, hit result, timestamp or ping is accepted.
local Config = require(script.Parent.Parent.Config.CombatConfig).HitboxPrediction
local HitboxPose = {}

local function Finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

function HitboxPose.Resolve(character, root, player)
    local frame = root.CFrame
    if not Config.Enabled or not player or player.Character ~= character or root.Parent ~= character
        or root.Anchored then return frame end
    local ok, ping = pcall(function() return player:GetNetworkPing() end)
    if not ok or not Finite(ping) or ping <= 0 then return frame end
    -- GetNetworkPing reports round-trip latency; use half as a bounded estimate of inbound delay.
    local leadTime = math.min(ping * 0.5, Config.MaxTime)
    local velocity = root.AssemblyLinearVelocity
    if not Finite(velocity.X) or not Finite(velocity.Z) then return frame end
    local speed = math.sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z)
    if not Finite(speed) or speed < 0.001 then return frame end
    local scale = math.min(1, Config.MaxSpeed / speed)
    local distance = math.min(speed * scale * leadTime, Config.MaxDistance)
    local offset = Vector3.new(velocity.X / speed * distance, 0, velocity.Z / speed * distance)
    return frame + offset
end

function HitboxPose.Validate()
    assert(type(Config.Enabled) == "boolean", "Invalid HitboxPrediction.Enabled")
    for _, key in ipairs({ "MaxTime", "MaxDistance", "MaxSpeed" }) do
        assert(Finite(Config[key]) and Config[key] >= 0, "Invalid HitboxPrediction." .. key)
    end
end

return HitboxPose
