local EnemyConfig = {
    Enabled = true,
    FolderName = "Enemies",
    TickInterval = 0.10,
    ChaseStopPadding = 0.75, -- approach inside attack range before stopping; resume beyond attack range
    Types = {
        TrainingEnemy = {
            MaxPosture = 100, PostureRecovery = 18,
            MaxHealth = 150, DetectionRange = 35, AttackRange = 5,
            WalkSpeed = 10, Strength = 10, AttackCooldown = 1.4,
            BlockChance = 0.20, ParryChance = 0.10,
            BlockDuration = 0.8, ParryDuration = 0.18,
            DecisionInterval = 0.35, ReactionTime = 0.25,
            MaxAttackAngle = 25, TurnResponsiveness = 12,
            LeashRange = 60, RespawnTime = 4, CorpseLifetime = 2,
            PerfectParryLead = 0.12,
        },
    },
    Profiles = {
        Passive = { Chase = false, Attack = false, BlockChance = 0, ParryChance = 0 },
        Blocking = { Chase = false, Attack = false, BlockChance = 1, ParryChance = 0 },
        Parry = { Chase = false, Attack = false, BlockChance = 0, ParryChance = 1 },
        Aggressive = { Chase = true, Attack = true, BlockChance = 0, ParryChance = 0 },
        Mixed = { Chase = true, Attack = true }, -- chances from the enemy type
        PerfectParry = { Chase = false, Attack = false, PerfectParry = true }, -- debug only
    },
    Spawns = {
        {
            Id = "TrainingEnemy1", EnemyType = "TrainingEnemy", AIProfile = "Mixed", Respawn = true,
            -- Optional absolute ground position: Position = Vector3.new(x, y, z).
            SpawnOffset = Vector3.new(0, 0, -18), Yaw = 180,
        },
    },
}

function EnemyConfig.Validate()
    local function finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
    assert(finite(EnemyConfig.TickInterval) and EnemyConfig.TickInterval > 0, "Invalid enemy tick interval")
    assert(finite(EnemyConfig.ChaseStopPadding) and EnemyConfig.ChaseStopPadding >= 0,
        "Invalid enemy chase stop padding")
    local ids = {}
    for id, config in pairs(EnemyConfig.Types) do
        for _, key in ipairs({ "MaxHealth", "DetectionRange", "AttackRange", "WalkSpeed", "AttackCooldown",
            "BlockDuration", "ParryDuration", "DecisionInterval", "TurnResponsiveness", "LeashRange", "RespawnTime" }) do
            assert(finite(config[key]) and config[key] > 0, "Invalid enemy " .. id .. "." .. key)
        end
        assert(config.LeashRange >= config.DetectionRange, "Enemy leash is smaller than detection radius")
        assert(finite(config.Strength) and config.Strength >= 0 and finite(config.CorpseLifetime) and config.CorpseLifetime >= 0
            and finite(config.ReactionTime) and config.ReactionTime >= 0 and finite(config.PerfectParryLead)
            and config.PerfectParryLead > 0 and finite(config.MaxAttackAngle) and config.MaxAttackAngle >= 0
            and config.MaxAttackAngle <= 180, "Invalid enemy combat timing/strength")
        assert(finite(config.BlockChance) and finite(config.ParryChance)
            and config.BlockChance >= 0 and config.ParryChance >= 0 and config.BlockChance + config.ParryChance <= 1,
            "Invalid enemy defense chances")
    end
    for name, profile in pairs(EnemyConfig.Profiles) do
        assert(type(profile.Chase) == "boolean" and type(profile.Attack) == "boolean", "Invalid enemy profile " .. name)
        local block = profile.BlockChance or 0
        local parry = profile.ParryChance or 0
        assert(finite(block) and finite(parry) and block >= 0 and parry >= 0 and block + parry <= 1,
            "Invalid enemy profile chances " .. name)
    end
    for _, spawn in ipairs(EnemyConfig.Spawns) do
        assert(type(spawn.Id) == "string" and not ids[spawn.Id], "Duplicate or missing enemy spawn ID")
        ids[spawn.Id] = true
        assert(EnemyConfig.Types[spawn.EnemyType] and EnemyConfig.Profiles[spawn.AIProfile], "Unknown enemy type/profile")
    end
end

return EnemyConfig
