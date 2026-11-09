-- Глобальные параметры защиты, уклонения и оглушения.
-- Все значения предварительные, для тестирования. Время в секундах, расстояния в studs.
-- Параметры конкретного оружия (длительность фаз атаки, кулдаун) лежат в CombatConfig.

local CombatStateConfig = {}

CombatStateConfig.Block = {
    DamageReduction = 0.70, -- доля поглощаемого урона при обычном блоке
    ParryWindow = 0.25,     -- сколько после начала блока действует окно парирования
}

CombatStateConfig.Dodge = {
    Duration = 0.35,        -- длительность рывка
    IFrameDuration = 0.20,  -- неуязвимость: только начало рывка
    Distance = 8,
    Cooldown = 1.0,         -- отсчитывается от начала уклонения
}

CombatStateConfig.Stun = {
    DefaultDuration = 1.0,
    MaxDuration = 5.0,
}

return CombatStateConfig
