local Config = require(script.Parent.Parent.Config.MagicConfig)
local Composer = {}

-- The same resolver drives preview and server execution. Only the server supplies caster stats.
function Composer.Resolve(recipe, stats)
    if type(recipe) ~= "table" or type(recipe.Elements) ~= "table" then return nil, "Invalid recipe" end
    for key in pairs(recipe) do
        if key ~= "Elements" and key ~= "Form" then return nil, "Invalid recipe" end
    end
    local form = Config.Forms[recipe.Form]
    if not form then return nil, "Choose a form" end
    local elementId, intensity = next(recipe.Elements)
    local element = Config.Elements[elementId]
    if not element then return nil, "Choose Fire or Wind" end
    if next(recipe.Elements, elementId) then return nil, "Choose one element" end
    if type(intensity) ~= "number" or (intensity ~= 1 and intensity ~= 2) then return nil, "Maximum intensity is 2" end
    local scale = Config.Intensity[intensity]
    local power = element.Power * scale.Power * (1 + math.max(0, stats.Willpower - 10) * 0.009
        + stats.Magic * 0.003)
    local affinity = stats.Affinities[elementId] == true or table.find(stats.Affinities, elementId) ~= nil
    local rawWear = element.Wear * scale.Wear * form.Wear
    local excess = math.max(0, power - stats.Throughput)
    local wear = (rawWear + excess * 0.45) * (affinity and 0.93 or 1)
        / math.clamp(1 + (stats.Stability - Config.Gate.Stability) * 0.01, 0.75, 1.6)
    local id = elementId .. ":" .. intensity .. ":" .. recipe.Form
    return {
        Id = id, Name = scale.Prefix .. elementId .. " " .. recipe.Form, Category = "Magic",
        DominantElement = elementId, Intensity = intensity, Color = element.Color,
        ManaCost = math.ceil(element.Mana * scale.Mana * form.Mana * (affinity and 0.95 or 1)),
        GateWear = math.ceil(wear), RequiredThroughput = power,
        Cast = { Startup = 0.30 + 0.10 * intensity, Active = 0.12, Recovery = 0.35 + 0.06 * intensity },
        Targeting = { Type = recipe.Form, Range = form.Range, Width = 6 * scale.Size,
            Radius = (recipe.Form == "Projectile" and 0.55 or 6) * scale.Size,
            Speed = element.Speed * scale.Speed, Duration = 1.5 + 0.5 * intensity, TickRate = 0.5 },
        Combat = { Damage = math.round(power * form.Power), PostureDamage = element.Pressure * scale.Power * form.Power,
            HitStun = recipe.Form == "Area" and 0.08 or 0.18,
            Restore = recipe.Form == "Self" and elementId == "Wind" },
    }
end

function Composer.Stats(profile)
    local magic = profile and profile.Magic or {}
    return {
        Willpower = profile and profile.Stats.Attributes.Willpower or 10,
        Magic = profile and profile.Proficiencies.Magic or 0,
        Throughput = magic.GateThroughput or Config.Gate.Throughput,
        Stability = magic.GateStability or Config.Gate.Stability,
        Affinities = magic.Affinities or {},
    }
end

return Composer
