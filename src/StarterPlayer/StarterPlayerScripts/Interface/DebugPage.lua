local Theme = require(script.Parent.Theme)
local ProgressionPages = require(script.Parent.ProgressionPages)
local px = UDim2.fromOffset

local DebugPage = {}

local sections = {
    {
        Name = "Progression",
        { "+50 XP", "AddXP", 50 },
        { "+500 XP", "AddXP", 500 },
        { "+50 Points", "AddStatPoints", 50 },
        { "+100 Gold", "AddGold", 100 },
        { "Save Now", "SaveNow" },
    },
    {
        Name = "Character",
        { "Take 20 Damage", "DamageSelf", 20 },
        { "Spend 30 Mana", "SpendMana", 30 },
        { "Restore Health & Mana", "RestoreAll" },
        { "Stun Self (Ability)", "StunSelf" },
        { "Give Sword", "GiveSword" },
    },
    {
        Name = "Training Dummies",
        { "Low Posture Dummy", "SpawnLowPostureDummy" },
        { "Spawn R6 Dummy", "SpawnDummy" },
        { "Spawn Blocking Dummy", "SpawnBlockingDummy" },
        { "Spawn Aggressive Dummy", "SpawnAggressiveDummy" },
        { "Stun Dummies (Ability)", "StunDummies" },
        { "Remove Last Dummy", "RemoveDummy" },
        { "Remove All Dummies", "RemoveAllDummies" },
    },
}

function DebugPage.new(parent, send)
    ProgressionPages.heading(parent, "Debugging")
    local gold = Theme.label(parent, "Gold", "Gold: —", px(0, 49), px(610, 24), 14)
    gold.TextColor3 = Theme.Colors.Accent
    local top = 83
    for _, section in ipairs(sections) do
        local label = Theme.label(parent, "Section", section.Name, px(0, top), px(610, 26), 15)
        label.TextColor3 = Theme.Colors.Muted
        for index, action in ipairs(section) do
            local column = (index - 1) % 3
            local row = math.floor((index - 1) / 3)
            local button = Theme.button(parent, action[2], action[1],
                px(column * 206, top + 32 + row * 42), px(198, 35), function()
                    send(action[2], action[3])
                end)
            button.TextSize = 12
            Theme.outline(button)
        end
        top += 32 + math.ceil(#section / 3) * 42 + 12
    end

    return function(state)
        gold.Text = state.Profile and ("Gold: " .. tostring(state.Profile.Resources.Gold or 0)) or "Gold: —"
    end
end

return DebugPage
