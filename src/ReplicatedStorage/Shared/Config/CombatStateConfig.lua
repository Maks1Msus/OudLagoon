-- Глобальные параметры защиты, уклонения и оглушения.
-- Все значения предварительные, для тестирования. Время в секундах, расстояния в studs.
-- Параметры конкретного оружия (длительность фаз атаки, кулдаун) лежат в CombatConfig.

local CombatStateConfig = {}

CombatStateConfig.Movement = {
    BaseSpeedAttribute = "CombatBaseWalkSpeed",
    StateAttribute = "CombatMovementState",
    States = {
        Ragdolled = { WalkSpeedMultiplier = 0, CanSprint = false, CanJump = false, LockRotation = true },
        Attacking = { WalkSpeedMultiplier = 0.5, CanSprint = false, CanJump = false },
        Blocking = { WalkSpeedMultiplier = 0.4, CanSprint = false, CanJump = false },
        Dodging = { WalkSpeedMultiplier = 1, CanSprint = true, CanJump = false, LockRotation = false },
    },
}

CombatStateConfig.Block = {
    DamageReduction = 0.70, -- доля поглощаемого урона при обычном блоке
    ParryWindow = 0.25,     -- сколько после начала блока действует окно парирования
    DirectionAngle = 120,   -- ширина защищаемого сектора спереди, градусы (весь сектор:
                            -- +-60 от направления взгляда); используется при обработке урона
}
CombatStateConfig.Stun = {
    DefaultDuration = 0.20,

    LightHitDuration = 0.20,
    HeavyHitDuration = 0.45,
    PostureBreakDuration = 1.0,
    ParryDuration = 0.75,
    AbilityDuration = 0.80,

    MaxDuration = 1.50,
    PostStunImmunity = 0.30,
}

-- Dash timing, distances and cooldowns are configured in DashConfig.lua.



return CombatStateConfig
