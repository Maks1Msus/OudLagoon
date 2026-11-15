-- Глобальные параметры защиты, уклонения и оглушения.
-- Все значения предварительные, для тестирования. Время в секундах, расстояния в studs.
-- Параметры конкретного оружия (длительность фаз атаки, кулдаун) лежат в CombatConfig.

local CombatStateConfig = {}

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
    ParryDuration = 0.75,
    AbilityDuration = 0.80,

    MaxDuration = 1.50,
    PostStunImmunity = 0.30,
}

CombatStateConfig.Dodge = {
    Duration = 0.35,        -- длительность рывка
    IFrameDuration = 0.20,  -- неуязвимость: только начало рывка
    Distance = 8,
    Cooldown = 1.0,         -- отсчитывается от начала уклонения
}


return CombatStateConfig
