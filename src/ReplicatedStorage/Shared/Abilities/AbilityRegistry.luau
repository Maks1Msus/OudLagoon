return {
    SwordUppercut = {
        Id = "SwordUppercut", Name = "Sword Uppercut", Category = "Physical", Weapon = "Sword", AnimationSlot = "Light3", Cooldown = 6,
        Cast = { Startup = 0.30, Active = 0.12, Recovery = 0.45 },
        Targeting = { Type = "Forward", Range = 8, Width = 5 },
        Combat = { DamageMultiplier = 1.4, PostureDamage = 22, HitStun = 0.35, ParryCaster = true },
        Color = Color3.fromRGB(223, 215, 181),
    },
}
