-- Templates stay in Studio under ReplicatedStorage/VFX. All offsets are local to Anchor.
local Config = {
    Enabled = true,
    FolderName = "VFX",
    RenderDistance = 100,
    MaxEffects = 32,
    MaxTemplateDescendants = 128,
    MaxTail = 6,
    MaxAge = 0.6,
    DefaultEmitCount = 12,
    Effects = {
        Light1 = { Template = "Punch-01", Anchor = "Root", AllowDead = true, HideCarrier = true, Duration = 0.12 },
        Light2 = { Template = "Punch-02", Anchor = "Root", AllowDead = true, HideCarrier = true, Duration = 0.12 },
        Light3 = { Template = "Punch-03", Anchor = "Root", AllowDead = true, HideCarrier = true, Duration = 0.14 },
        Dash = { Template = "Dash", Anchor = "Root", HideCarrier = true, Sustain = true, FaceVelocity = true, Duration = 0.3, Offset = CFrame.Angles(0, math.rad(-90), 0), },
        Block = { Template = "Block", Anchor = "Root", HideCarrier = true,
            Offset = CFrame.new(0, 0, 0), Loop = true },
        Parry = { Template = "Parry", Anchor = "Root", Duration = 0.3,
            SpinDegrees = Vector3.new(0, 0, 0), SpinDuration = 0.3,
            OffsetA = CFrame.new(0, 0, -1.5),
            OffsetB = CFrame.Angles(0,math.rad(90),0) },
    },
    -- Confirmed Hit only, on the victim. Sword has no impact assets assigned yet.
    Attacks = { Unarmed = { Light1 = "Light1", Light2 = "Light2", Light3 = "Light3", DashLight = "Light1" } },
}
return Config
