local Config = {
    DefaultSlots = { Slot1 = "SwordUppercut", Slot2 = "", Slot3 = "", Slot4 = "" },
    Bindings = {
        Slot1 = "Z", Slot2 = "X", Slot3 = "C", Slot4 = "V", MagicMode = "G", CastMagic = "T",
        Fire = "One", Wind = "Three", Projectile = "Seven", Forward = "Eight", Area = "Nine", Self = "Zero",
    },
    ActionOrder = { "Slot1", "Slot2", "Slot3", "Slot4", "MagicMode", "CastMagic",
        "Fire", "Wind", "Projectile", "Forward", "Area", "Self" },
    CastSpeed = { Startup = 0.35, Active = 0.25, Recovery = 0.45 },
    TurnScale = 0.4,
    AimRadiansPerSecond = math.rad(200),
}
-- Exclude locomotion, combat, chat, character menu and Roblox system shortcuts.
local allowed = {}
for _, key in ipairs({ "Z","X","C","V","G","T","H","J","K","L","Y","U","I","O","P","N","M",
    "One","Two","Three","Four","Five","Six","Seven","Eight","Nine","Zero" }) do allowed[key] = true end

function Config.CanBind(bindings, action, key)
    if not Config.Bindings[action] or not allowed[key] then return false end
    for other, name in pairs(bindings) do
        if other ~= action and name == key then return false end
    end
    return true
end
return Config
