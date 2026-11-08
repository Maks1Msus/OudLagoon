-- Константы, не зависящие от баланса прокачки.
-- Правила прокачки (уровни, очки, опыт) живут в Config/ProgressionConfig.

local GameConstants = {}

GameConstants.DefaultHealth = 100
GameConstants.DefaultWalkSpeed = 16

-- Значение характеристики, при котором бонусы равны нулю (стартовые 10).
GameConstants.BaseStatValue = 10

-- Производные параметры персонажа
GameConstants.HealthPerVitality = 5      -- +5 HP за каждое очко Vitality выше базы
GameConstants.SpeedPerAgility = 0.1      -- +0.1 к скорости за каждое очко Agility выше базы
GameConstants.MinWalkSpeed = 8
GameConstants.MaxWalkSpeed = 30

-- Максимум маны = очки характеристики Mana * ManaPerPoint.
-- При старте (Mana = 10) получается 100.
GameConstants.ManaPerPoint = 10

return GameConstants