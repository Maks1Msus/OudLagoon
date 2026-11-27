return {
    Elements = {
        Fire = { Power = 21, Pressure = 5, Speed = 48, Mana = 6, Wear = 10, Color = Color3.fromRGB(249, 127, 67) },
        Wind = { Power = 15, Pressure = 10, Speed = 72, Mana = 5, Wear = 9, Color = Color3.fromRGB(133, 222, 198) },
    },
    Forms = {
        Projectile = { Mana = 1, Wear = 1, Power = 1, Range = 65 },
        Forward = { Mana = 0.9, Wear = 0.85, Power = 0.95, Range = 12 },
        Area = { Mana = 1.25, Wear = 1.35, Power = 0.35, Range = 40 },
        Self = { Mana = 0.85, Wear = 0.85, Power = 0.8, Range = 0 },
    },
    Intensity = {
        { Prefix = "", Power = 1, Wear = 1, Mana = 1, Size = 1, Speed = 1 },
        { Prefix = "El ", Power = 1.4, Wear = 1.65, Mana = 1.45, Size = 1.25, Speed = 1.1 },
    },
    Gate = { Max = 100, Throughput = 20, Stability = 10, Recovery = 15, Delay = 0.85,
        LockDuration = 2.5, UnlockWear = 70, OverloadStun = 0.5, OverloadRecoveryScale = 0.6 },
    ManaRecovery = 1, ManaDelay = 5,
}
