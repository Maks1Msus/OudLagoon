-- Integrated smooth speed profile, independent of the physics frame rate.
local DashMotion = {}

local function SmoothIntegral(t)
    return t * t * t - 0.5 * t * t * t * t
end

function DashMotion.DistanceAt(profile, curve, elapsed, startSpeed)
    local t = math.clamp(elapsed / profile.Duration, 0, 1)
    local acceleration = curve.AccelerationFraction
    local braking = curve.DecelerationFraction
    startSpeed = math.clamp(startSpeed or 0, 0, 2 * profile.Distance / profile.Duration)
    local peak = (profile.Distance / profile.Duration - 0.5 * acceleration * startSpeed)
        / (1 - 0.5 * (acceleration + braking))
    local area
    if t < acceleration then
        area = startSpeed * t + (peak - startSpeed) * acceleration * SmoothIntegral(t / acceleration)
    else
        area = acceleration * (startSpeed + peak) * 0.5
        if t <= 1 - braking then
            area = area + peak * (t - acceleration)
        else
            local u = (t - (1 - braking)) / braking
            area = area + peak * (1 - braking - acceleration)
                + peak * braking * (u - SmoothIntegral(u))
        end
    end
    return area * profile.Duration
end

-- Use the mean speed of this physics step, preserving the integral even at low FPS.
function DashMotion.SpeedForStep(profile, curve, elapsed, deltaTime, startSpeed)
    if deltaTime <= 0 then return 0 end
    local before = DashMotion.DistanceAt(profile, curve, elapsed, startSpeed)
    local after = DashMotion.DistanceAt(profile, curve, elapsed + deltaTime, startSpeed)
    return math.max(0, (after - before) / deltaTime)
end

return DashMotion
