-- Color communicates combat state; short reactions temporarily tint that state.
local CombatVFXConfig = {
    Enabled = true,
    ActorTag = "CombatVFXActor",
    RenderDistance = 100,
    BroadcastDistance = 120,
    MaxImpactAge = 0.6,
    MaxHighlights = 16,
    MaxTrails = 16,

    Attributes = {
        State = "CombatVFXState",
        Phase = "CombatVFXPhase",
        AttackId = "CombatVFXAttackId",
        ActiveEndsAt = "CombatVFXActiveEndsAt",
        WeaponId = "CombatVFXWeaponId",
        DodgeIFrameEndsAt = "CombatVFXDodgeIFrameEndsAt",
        DodgeEndsAt = "CombatVFXDodgeEndsAt",
    },

    Reactions = {
        Hit = {
            Color = Color3.fromRGB(224, 104, 94),
            Duration = 0.18,
            Priority = 1,
        },
        Blocked = {
            Color = Color3.fromRGB(136, 199, 236),
            Duration = 0.16,
            Priority = 2,
        },
        Parried = {
            Color = Color3.fromRGB(246, 214, 121),
            Duration = 0.28,
            Priority = 3,
        },
    },
    States = {
        Blocking = Color3.fromRGB(125, 178, 211),
        Stunned = Color3.fromRGB(218, 159, 94),
        Dodging = Color3.fromRGB(130, 205, 192),
    },
    DodgeInvulnerability = {
        Color = Color3.fromRGB(153, 236, 218),
        FillTransparency = 0.94,
        OutlineTransparency = 0.35,
    },
    AttackPhases = {
        Startup = Color3.fromRGB(207, 176, 113),
        Active = Color3.fromRGB(235, 214, 174),
        Recovery = Color3.fromRGB(151, 166, 177),
    },
    HighlightFillTransparency = 0.98,
    HighlightOutlineTransparency = 0.70,
    ReactionFillTransparency = 0.88,
    ReactionOutlineTransparency = 0.15,
    ColorBlendTime = 0.05,

    DashDust = {
        Enabled = true,
        RenderDistance = 75,
        Interval = 0.001,
        ParticlesPerBurst = 3,
        MaxParticles = 256,
        Lifetime = 0.28,
        MinSize = 1,
        MaxSize = 2,
        MinSpeed = 4,
        BackwardSpeed = 3,
        UpSpeed = 3.5,
        Spread = 0.1,
        Gravity = 18,
        Color = Color3.fromRGB(184, 168, 140),
        SurfaceTint = 0.55,
        GroundProbePadding = 0.65,
        MinGroundNormal = 0.6,
    },
    Trail = {
        Color = Color3.fromRGB(210, 225, 234),
        Lifetime = 0.08,
        Transparency = 0.9,
        Width = 0.35,
    },
}

return CombatVFXConfig
