local Theme = require(script.Parent.Theme)
local Colors = Theme.Colors
local px = UDim2.fromOffset
local Hud = {}

function Hud.new(gui, config, onAction, onRebind)
    local panel = Theme.frame(gui, "AbilityBar", UDim2.new(1, -18, 1, -75), px(312, 103), Colors.Panel)
    panel.AnchorPoint = Vector2.one
    Theme.outline(panel)
    local buttons = {}
    for i = 1, 4 do
        local slot = "Slot" .. i
        buttons[slot] = Theme.button(panel, slot, "", px(8 + (i - 1) * 75, 7), px(71, 33), function() onAction(slot) end)
        buttons[slot].TextSize = 11
        buttons[slot].TextWrapped = true
    end
    buttons.MagicMode = Theme.button(panel, "Composer", "", px(8, 46), px(175, 24), function() onAction("MagicMode") end)
    buttons.MagicMode.TextSize = 13
    local settings = Theme.frame(panel, "Bindings", px(0, -208), px(312, 204), Colors.Panel)
    local composer = Theme.frame(panel, "Recipe", px(0, -210), px(312, 206), Colors.Panel)
    Theme.outline(settings)
    Theme.outline(composer)
    local keys = Theme.button(panel, "Controls", "Keys", px(190, 46), px(114, 24), function() onAction("Keys") end)
    keys.TextSize = 13
    local track = Theme.frame(panel, "Gate", px(8, 78), px(296, 18), Colors.Surface)
    local fill = Theme.frame(track, "Wear", px(0, 0), UDim2.fromScale(0,1), Colors.Mana)
    local label = Theme.label(track, "Value", "", px(5,0), px(286,18), 11)
    label.ZIndex = fill.ZIndex + 1

    local name = Theme.label(composer, "Name", "", px(8, 5), px(294, 24), 14)
    local estimate = Theme.label(composer, "Estimate", "", px(8, 30), px(294, 24), 13)
    local formActions = { "Fire", "Wind", "Projectile", "Forward", "Area", "Self" }
    for i, action in ipairs(formActions) do
        local column, row = (i-1)%2, math.floor((i-1)/2)
        buttons[action] = Theme.button(composer, action, "", px(8 + 150*column, 60 + row*34), px(145, 29),
            function() onAction(action) end)
        buttons[action].TextSize = 13
    end
    buttons.CastMagic = Theme.button(composer, "Cast", "", px(8, 166), px(188, 32), function() onAction("CastMagic") end)
    Theme.button(composer, "Clear", "Clear", px(202, 166), px(101, 32), function() onAction("Clear") end)
    local bindingButtons = {}
    for i, action in ipairs(config.ActionOrder) do
        local column, row = (i-1)%2, math.floor((i-1)/2)
        bindingButtons[action] = Theme.button(settings, action, "", px(8 + column*150, 7 + row*32), px(145, 28),
            function() onRebind(action) end)
        bindingButtons[action].TextSize = 12
    end
    local status = Theme.label(panel, "Feedback", "", px(0,-27), px(312,25), 13)
    status.TextColor3 = Colors.Accent
    local digits = { One="1", Two="2", Three="3", Four="4", Five="5", Six="6", Seven="7", Eight="8", Nine="9", Zero="0" }
    return function(view)
        panel.Visible = not view.Hidden
        settings.Visible = view.Settings
        composer.Visible = view.Compose and not view.Settings
        local bindings = view.Bindings
        local function key(action) return digits[bindings[action]] or bindings[action] end
        for action, button in pairs(bindingButtons) do
            button.Text = action .. "   " .. (view.Binding == action and "Press key…" or key(action))
        end
        local ratio = math.clamp(view.Wear / view.MaxWear, 0, 1)
        fill.Size = UDim2.fromScale(ratio, 1)
        fill.BackgroundColor3 = ratio >= 0.9 and Colors.Health or ratio >= 0.65 and Colors.Accent or Colors.Mana
        label.Text = (view.Overloaded and "OVERLOAD   " or "Gate   ") .. math.ceil(view.Wear) .. " / " .. view.MaxWear
        for i = 1, 4 do
            local action = "Slot"..i
            local entry = view.Slots[action]
            buttons[action].Text = key(action) .. "   " .. (entry and entry.Label or "—")
            Theme.setButtonEnabled(buttons[action], entry ~= nil and entry.Ready)
        end
        buttons.MagicMode.Text = (view.Compose and "Close magic" or "Compose magic") .. "   [" .. key("MagicMode") .. "]"
        name.Text = view.Name
        estimate.Text = view.Estimate
        estimate.TextColor3 = view.Risk and Colors.Error or Colors.Muted
        for _, action in ipairs(formActions) do
            buttons[action].Text = key(action) .. "   " .. action
            Theme.setButtonEnabled(buttons[action], true, action == view.Element or action == view.Form)
        end
        buttons.CastMagic.Text = "Cast   [" .. key("CastMagic") .. "]"
        Theme.setButtonEnabled(buttons.CastMagic, view.CanCast, true)
        status.Position = px(0, (settings.Visible or composer.Visible) and -236 or -27)
        status.Text = view.Message
    end
end
return Hud
