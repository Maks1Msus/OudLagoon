
local ProgressionConfig = {}

ProgressionConfig.MaxLevel = 100

ProgressionConfig.StartingLevel = 1
ProgressionConfig.StartingExperience = 0

ProgressionConfig.StatPointsPerLevel = 5

ProgressionConfig.StartingStatPoints = 0

ProgressionConfig.MaxStatValue = 1000

ProgressionConfig.BaseExperience = 100
ProgressionConfig.ExperienceExponent = 1.5

ProgressionConfig.AllocatableStats = {
    Strength = true,
    Vitality = true,
    Agility = true,
    Intelligence = true,
    Mana = true,
    Spirit = true,
}

function ProgressionConfig:GetExperienceForNextLevel(level)
    return math.floor(
        self.BaseExperience * (level ^ self.ExperienceExponent)
    )
end

return ProgressionConfig
