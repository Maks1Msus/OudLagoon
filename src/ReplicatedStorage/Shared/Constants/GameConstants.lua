-- Константы, не зависящие от баланса прокачки.
-- Правила прокачки (уровни, очки, опыт) живут в Config/ProgressionConfig.

local GameConstants = {}

GameConstants.DefaultHealth = 100
GameConstants.DefaultWalkSpeed = 16

-- Значение характеристики, при котором бонусы равны нулю (стартовые 10).
GameConstants.BaseStatValue = 10

GameConstants.DefaultStamina = 100
GameConstants.HealthPerEffectiveVitality = 1.25
GameConstants.StaminaPerEffectiveEndurance = 2

return GameConstants
