local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config.ProgressionConfig)
local StatRules = require(Shared.Progression.StatRules)
local Theme = require(script.Parent.Theme)

local Pages = {}
local Colors = Theme.Colors
local px = UDim2.fromOffset
local WIDTH = 610

function Pages.heading(parent, name, y)
    local title = Theme.label(parent, "Heading", name, px(0, y or 0), px(WIDTH, 44), 34)
    title.Font = Enum.Font.Garamond
end

local function row(parent, label, y)
    local frame = Theme.frame(parent, label, px(0, y), px(WIDTH, 44), Colors.Surface)
    Theme.outline(frame)
    Theme.label(frame, "Name", label, px(14, 0), px(210, 44), 15)
    local value = Theme.label(frame, "Value", "—", px(224, 0), px(WIDTH - 238, 44), 14)
    value.TextXAlignment = Enum.TextXAlignment.Right
    value.TextTruncate = Enum.TextTruncate.AtEnd
    return value
end

local function caption(parent, text, y)
    local label = Theme.label(parent, "Caption", text, px(0, y), px(WIDTH, 28), 14)
    label.TextColor3 = Colors.Muted
end

local function attributePreview(profile, draft)
    local attributes = table.clone(profile.Stats.Attributes)
    for name, amount in pairs(draft) do
        attributes[name] += amount
    end
    return attributes
end

local function previewNumber(current, nextValue)
    if current == nextValue then
        return tostring(current)
    end
    return string.format("%s → %s", current, nextValue)
end

function Pages.proficiencies(parent)
    Pages.heading(parent, "Proficiencies")
    caption(parent, "Mastery gain and technique unlocks are not active yet.", 47)
    local values = {}
    for index, name in ipairs(Config.ProficiencyOrder) do
        values[name] = row(parent, name, 88 + (index - 1) * 53)
    end
    return function(state)
        for name, value in pairs(values) do
            value.Text = state.Profile and string.format("%d / %d",
                state.Profile.Proficiencies[name], Config.MaxProficiency) or "—"
        end
    end
end

function Pages.derived(parent)
    Pages.heading(parent, "Total Stats")
    local health = row(parent, "Max Health", 59)
    local stamina = row(parent, "Stamina Capacity", 112)
    local damage = row(parent, "Base Attack Damage", 165)
    local guard = row(parent, "Guard Strength", 218)
    caption(parent, "Stamina spending and guard scaling are pending integration.", 266)

    Pages.heading(parent, "Magic", 301)
    local mana = row(parent, "Mana Capacity", 358)
    local throughput = row(parent, "Gate Throughput", 411)
    local stability = row(parent, "Gate Stability", 464)
    return function(state)
        local profile = state.Profile
        if not profile then
            return
        end
        local current = profile.Stats.Attributes
        local proposed = attributePreview(profile, state.Draft)
        local proficiency = profile.Proficiencies[state.WeaponId]
        health.Text = previewNumber(StatRules.GetMaxHealth(current.Vitality),
            StatRules.GetMaxHealth(proposed.Vitality))
        stamina.Text = previewNumber(StatRules.GetMaxStamina(current.Endurance),
            StatRules.GetMaxStamina(proposed.Endurance))
        damage.Text = state.Weapon.DisplayName .. " · " .. previewNumber(
            StatRules.GetPlayerBaseDamage(state.Weapon, current, proficiency),
            StatRules.GetPlayerBaseDamage(state.Weapon, proposed, proficiency))
        guard.Text = "Pending"
        mana.Text = tostring(profile.Magic.ManaCapacity)
        throughput.Text = profile.Magic.GateThroughput and tostring(profile.Magic.GateThroughput) or "Not configured"
        stability.Text = profile.Magic.GateStability and tostring(profile.Magic.GateStability) or "Not configured"
    end
end

local function identityText(list)
    local entries = {}
    for name, value in pairs(list) do
        if type(value) == "string" then
            local text = type(name) == "string" and (name .. " (" .. value .. ")") or value
            table.insert(entries, text)
        end
    end
    table.sort(entries)
    return #entries > 0 and table.concat(entries, ", ") or "None assigned"
end

function Pages.identity(parent)
    Pages.heading(parent, "Identity")
    local affinities = row(parent, "Magic Affinities", 59)
    local traits = row(parent, "Traits", 112)
    local direction = row(parent, "Sin / Virtue", 165)
    return function(state)
        local profile = state.Profile
        if profile then
            affinities.Text = identityText(profile.Magic.Affinities)
            traits.Text = identityText(profile.Identity.Traits)
            direction.Text = profile.Identity.DominantDirection or "None assigned"
        end
    end
end

return Pages
