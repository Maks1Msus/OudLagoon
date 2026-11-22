-- Единый источник правил прокачки.
-- XP до следующего уровня = floor(BaseExperience * Level ^ ExperienceExponent)

local ProgressionConfig = {}

ProgressionConfig.MaxLevel = 100

ProgressionConfig.StartingLevel = 1
ProgressionConfig.StartingExperience = 0

ProgressionConfig.StatPointsPerLevel = 5

ProgressionConfig.StartingStatPoints = 0

ProgressionConfig.MaxStatValue = 100
ProgressionConfig.BaseAttributeValue = 10
ProgressionConfig.MaxProficiency = 100
ProgressionConfig.MaxDamageBonusRatio = 0.5

ProgressionConfig.BaseExperience = 100
ProgressionConfig.ExperienceExponent = 1.5

ProgressionConfig.StatOrder = {
    "Strength",
    "Vitality",
    "Endurance",
    "Dexterity",
    "Willpower",
}

ProgressionConfig.AllocatableStats = {}
ProgressionConfig.StartingAttributes = {}
for _, attribute in ipairs(ProgressionConfig.StatOrder) do
    ProgressionConfig.AllocatableStats[attribute] = true
    ProgressionConfig.StartingAttributes[attribute] = ProgressionConfig.BaseAttributeValue
end

ProgressionConfig.ProficiencyOrder = { "Sword", "Unarmed", "Magic" }

function ProgressionConfig:GetExperienceForNextLevel(level)
    return math.floor(
        self.BaseExperience * (level ^ self.ExperienceExponent)
    )
end

return ProgressionConfig
