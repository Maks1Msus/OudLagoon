-- Combat dash with forward DashLight conversion. Evasive remains a separate future stage.
local DashConfig = {
    Forward = {
        Distance = 30, Duration = 0.4, Cooldown = 3.0,
        CooldownGroup = "ForwardDash", IFrameDuration = 0.06,
        Steering = { Enabled = true, Responsiveness = 18, MaxTurnRate = 720 },
        AttackConversion = {
            Enabled = true,
            Cooldown = 8.0, -- DashLight only; independent of Forward.Cooldown and M1 cooldown
            WindowStart = 0.07, WindowEnd = 0.24, Buffer = 0.08,
            MomentumRetention = 0.65, MomentumMaxSpeed = 80,
        },
    },
    Side = {
        Distance = 25, Duration = 0.24, Cooldown = 1.7,
        CooldownGroup = "MobilityDash", IFrameDuration = 0.08,
        Steering = { Enabled = true, Responsiveness = 18, MaxTurnRate = 900 },
        AttackConversion = { Enabled = false },
    },
    Backward = {
        Distance = 20, Duration = 0.24, Cooldown = 1.7,
        CooldownGroup = "MobilityDash", IFrameDuration = 0.08,
        Steering = { Enabled = true, Responsiveness = 14, MaxTurnRate = 720 },
        AttackConversion = { Enabled = false },
    },
    CollisionPadding = 0.5,
    SteeringRequestInterval = 0.10,
    DashAttackAttribute = "CombatDashAttackMoving",
    PredictionAttribute = "CombatDashPredicting", -- local movement restriction only
    PredictionTimeout = 1.0,
    HandoffDuration = 0.08,
    HandoffAnimationFade = 0.4,
    MotionFinishedAttribute = "CombatDashMotionFinished",
    PreserveSprintAttribute = "CombatDashPreserveSprint",
    SprintIntentAttribute = "CombatSprintIntent",
    LocomotionSpeedAttribute = "CombatLocomotionSpeed",
    ActiveMovementRestriction = {
        WalkSpeedMultiplier = 0, CanSprint = false, CanJump = false, LockRotation = false,
    },
    DistanceTolerance = 2.0, -- allowance for ordinary replication delay
    SpeedProfile = {
        AccelerationFraction = 0.12, -- first 12%: ease into the burst
        DecelerationFraction = 0.65, -- final 55%: ease out to zero
    },
}

function DashConfig.GetKind(directionId)
    if directionId == "Forward" then return "Forward" end
    if directionId == "Backward" then return "Backward" end
    -- All diagonals are lateral repositioning and share the Side profile.
    return "Side"
end

function DashConfig.GetProfile(directionId)
    return DashConfig[DashConfig.GetKind(directionId)]
end

function DashConfig.Validate()
    local function finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
    assert(type(DashConfig.PredictionAttribute) == "string" and #DashConfig.PredictionAttribute > 0,
        "Invalid dash prediction attribute")
    assert(finite(DashConfig.PredictionTimeout) and DashConfig.PredictionTimeout >= 0.5,
        "Invalid dash prediction timeout")
    assert(finite(DashConfig.DistanceTolerance) and DashConfig.DistanceTolerance >= 0,
        "Invalid dash distance tolerance")
    assert(finite(DashConfig.HandoffDuration) and DashConfig.HandoffDuration > 0,
        "Invalid dash handoff duration")
    assert(finite(DashConfig.HandoffAnimationFade) and DashConfig.HandoffAnimationFade >= 0,
        "Invalid dash handoff animation fade")
    local conversion = DashConfig.Forward.AttackConversion
    assert(finite(conversion.Cooldown) and conversion.Cooldown >= 0, "Invalid DashLight cooldown")
    assert(type(conversion.Enabled) == "boolean" and finite(conversion.WindowStart)
        and finite(conversion.WindowEnd) and conversion.WindowStart >= 0
        and conversion.WindowEnd > conversion.WindowStart and conversion.WindowEnd <= DashConfig.Forward.Duration,
        "Invalid forward dash conversion window")
    assert(finite(conversion.Buffer) and conversion.Buffer >= 0
        and finite(conversion.MomentumRetention) and conversion.MomentumRetention >= 0 and conversion.MomentumRetention <= 1
        and finite(conversion.MomentumMaxSpeed) and conversion.MomentumMaxSpeed > 0,
        "Invalid forward dash conversion buffer/momentum")
    local curve = DashConfig.SpeedProfile
    assert(finite(curve.AccelerationFraction) and curve.AccelerationFraction > 0
        and finite(curve.DecelerationFraction) and curve.DecelerationFraction > 0
        and curve.AccelerationFraction + curve.DecelerationFraction <= 1,
        "Invalid dash speed profile")
    for _, kind in ipairs({ "Forward", "Side", "Backward" }) do
        local p = DashConfig[kind]
        assert(finite(p.Distance) and p.Distance > 0, "Invalid dash distance: " .. kind)
        assert(finite(p.Duration) and p.Duration > 0, "Invalid dash duration: " .. kind)
        assert(finite(p.Cooldown) and p.Cooldown >= 0, "Invalid dash cooldown: " .. kind)
        assert(p.CooldownGroup == "ForwardDash" or p.CooldownGroup == "MobilityDash", "Invalid dash cooldown group")
        assert(finite(p.IFrameDuration) and p.IFrameDuration >= 0 and p.IFrameDuration < p.Duration,
            "Invalid dash iframe duration: " .. kind)
        local s = p.Steering
        assert(type(s.Enabled) == "boolean" and finite(s.Responsiveness) and s.Responsiveness > 0
            and finite(s.MaxTurnRate) and s.MaxTurnRate > 0, "Invalid dash steering: " .. kind)
    end
    assert(DashConfig.Side.Cooldown == DashConfig.Backward.Cooldown, "Mobility dash cooldown must be shared")
    assert(finite(DashConfig.CollisionPadding) and DashConfig.CollisionPadding >= 0, "Invalid dash padding")
    assert(finite(DashConfig.SteeringRequestInterval) and DashConfig.SteeringRequestInterval >= 0.1,
        "Invalid steering request interval")
end

return DashConfig
