local Shared = script.Parent.Parent
local ProgressionConfig = require(Shared.Config.ProgressionConfig)
local GameConstants = require(Shared.Constants.GameConstants)

local PostureConfig = require(Shared.Config.PostureConfig)

local StatRules = {}

function StatRules.GetAllocationCost(stats, availablePoints, changes)
    if type(changes) ~= "table" then
        return nil, "InvalidAllocation"
    end

    local total = 0
    local cap = ProgressionConfig.MaxStatValue

    for statName, amount in pairs(changes) do
        if type(statName) ~= "string" or not ProgressionConfig.AllocatableStats[statName]
            or type(amount) ~= "number" or amount < 1 or amount > cap or amount % 1 ~= 0 then
            return nil, "InvalidAllocation"
        end

        local current = stats[statName]
        if type(current) ~= "number" or current % 1 ~= 0 then
            return nil, "InvalidAllocation"
        end
        if current + amount > cap then
            return nil, "StatCap"
        end

        total += amount
    end

    if total == 0 then
        return nil, "InvalidAllocation"
    end
    if total > availablePoints then
        return nil, "NotEnoughPoints"
    end

    return total
end

-- Tiers are continuous: crossing a threshold only reduces the marginal benefit.
function StatRules.GetEffectivePoints(value)
    value = math.max(0, value)
    return math.min(value, 25)
        + math.clamp(value - 25, 0, 25) * 0.7
        + math.clamp(value - 50, 0, 25) * 0.4
        + math.max(value - 75, 0) * 0.2
end

local function GetAttributeBonus(value)
    local baseline = ProgressionConfig.BaseAttributeValue
    return StatRules.GetEffectivePoints(math.clamp(value or baseline, baseline, ProgressionConfig.MaxStatValue))
        - StatRules.GetEffectivePoints(baseline)
end

function StatRules.GetMaxHealth(vitality)
    return math.round(GameConstants.DefaultHealth
        + GetAttributeBonus(vitality) * GameConstants.HealthPerEffectiveVitality)
end

function StatRules.GetMaxPosture(endurance)
    return math.round(GameConstants.DefaultPosture
        + GetAttributeBonus(endurance) * GameConstants.PosturePerEffectiveEndurance)
end

function StatRules.GetPostureRecovery(endurance)
    return PostureConfig.Recovery.BasePerSecond + GetAttributeBonus(endurance) * GameConstants.PostureRecoveryPerEffectiveEndurance
end

function StatRules.GetSpentPoints(attributes)
    local spent = 0
    for name, baseline in pairs(ProgressionConfig.StartingAttributes) do
        spent += math.max(0, attributes[name] - baseline)
    end
    return spent
end

function StatRules.GetBaseDamage(weapon, strength)
    local damage = weapon.BaseDamage + strength * weapon.Scaling
    return math.max(1, math.floor(damage + 0.5))
end

function StatRules.GetPlayerBaseDamage(weapon, attributes, proficiency)
    local base = StatRules.GetBaseDamage(weapon, ProgressionConfig.BaseAttributeValue)
    local scaling = weapon.AttributeScaling
    if not scaling then
        return base
    end
    local effectiveProficiency = StatRules.GetEffectivePoints(math.clamp(proficiency or 0, 0,
        ProgressionConfig.MaxProficiency))
    local bonus = GetAttributeBonus(attributes.Strength) * scaling.Strength
        + GetAttributeBonus(attributes.Dexterity) * scaling.Dexterity
        + effectiveProficiency * scaling.Proficiency
    local limit = base * ProgressionConfig.MaxDamageBonusRatio
    return math.floor(base + limit * bonus / (limit + bonus) + 0.5)
end

return StatRules
