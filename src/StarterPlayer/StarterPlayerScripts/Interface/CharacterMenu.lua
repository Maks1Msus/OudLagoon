local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config.ProgressionConfig)
local StatRules = require(Shared.Progression.StatRules)
local Theme = require(script.Parent.Theme)
local CharacterPreview = require(script.Parent.CharacterPreview)
local ProgressionPages = require(script.Parent.ProgressionPages)
local DebugPage = require(script.Parent.DebugPage)

local CharacterMenu = {}
CharacterMenu.__index = CharacterMenu

local Colors = Theme.Colors
local px = UDim2.fromOffset
local WIDTH, HEIGHT = 1020, 620
local FIRST_TAB = "Attributes"

local function attributeEffect(statName, state)
    if statName == "Willpower" then
        return "Reserved for magic control and Gate stability"
    end
    if not state.Profile then
        return ""
    end

    local attributes = state.Profile.Stats.Attributes
    local bonus = state.Draft[statName] or 0
    local name, current, proposed
    if statName == "Vitality" then
        name = "Max health"
        current = StatRules.GetMaxHealth(attributes.Vitality)
        proposed = StatRules.GetMaxHealth(attributes.Vitality + bonus)
    elseif statName == "Endurance" then
        name = "Stamina capacity"
        current = StatRules.GetMaxStamina(attributes.Endurance)
        proposed = StatRules.GetMaxStamina(attributes.Endurance + bonus)
    else
        local proficiency = state.Profile.Proficiencies[state.WeaponId]
        local preview = table.clone(attributes)
        preview[statName] += bonus
        name = state.Weapon.DisplayName .. " base damage"
        current = StatRules.GetPlayerBaseDamage(state.Weapon, attributes, proficiency)
        proposed = StatRules.GetPlayerBaseDamage(state.Weapon, preview, proficiency)
    end

    return name .. ": " .. (current == proposed and tostring(current) or (current .. " → " .. proposed))
end

local function createRow(parent, index, statName, adjust, bulkAmount)
    local row = Theme.frame(parent, statName, px(0, 85 + (index - 1) * 65), px(610, 57), Colors.Surface)
    Theme.outline(row)
    Theme.label(row, "Name", statName, px(14, 6), px(282, 24), 17)
    local effect = Theme.label(row, "Effect", "", px(14, 31), px(284, 17), 12)
    effect.TextColor3 = Colors.Muted
    local value = Theme.label(row, "Value", "—", px(300, 0), px(112, 57), 17)
    value.TextXAlignment = Enum.TextXAlignment.Right
    local minus = Theme.button(row, "Decrease", "−1", px(433, 11), px(43, 35), function()
        adjust(statName, -1)
    end)
    local plus = Theme.button(row, "Increase", "+1", px(484, 11), px(43, 35), function()
        adjust(statName, 1)
    end)
    local bulk = Theme.button(row, "BulkAdd", "+10", px(535, 11), px(63, 35), function()
        adjust(statName, bulkAmount())
    end)
    Theme.outline(bulk, Colors.Accent)
    return { Value = value, Effect = effect, Minus = minus, Plus = plus, Bulk = bulk }
end

function CharacterMenu.new(parent, displayName, actions)
    local backdrop = Theme.frame(parent, "MenuOverlay", px(0, 0), UDim2.fromScale(1, 1), Colors.Ink)
    backdrop.BackgroundTransparency = 0.36
    backdrop.Active = true
    backdrop.Visible = false

    local panel = Theme.frame(backdrop, "CharacterMenu", UDim2.fromScale(0.5, 0.5),
        px(WIDTH, HEIGHT), Colors.Panel)
    panel.AnchorPoint = Vector2.new(0.5, 0.5)
    Theme.outline(panel, Colors.Accent)
    local scale = Theme.create("UIScale", panel, {})
    local function resize()
        local size = backdrop.AbsoluteSize
        scale.Scale = math.clamp(math.min((size.X - 36) / WIDTH, (size.Y - 36) / HEIGHT), 0.25, 1.15)
    end
    backdrop:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize)
    resize()

    Theme.frame(panel, "HeaderRule", px(0, 57), px(WIDTH, 1), Colors.Border)
    local closeButton = Theme.button(panel, "Close", "×", px(WIDTH - 58, 10), px(36, 36), actions.Close)
    closeButton.TextSize = 26
    closeButton.Modal = true

    local name = Theme.label(panel, "PlayerName", displayName, px(24, 84), px(336, 44), 34)
    name.Font = Enum.Font.Garamond
    name.TextTruncate = Enum.TextTruncate.AtEnd
    local progress = Theme.label(panel, "Progress", "Loading profile…", px(26, 131), px(336, 23), 15)
    progress.TextColor3 = Colors.Muted
    local track = Theme.frame(panel, "Experience", px(26, 162), px(328, 4), Colors.Surface)
    local fill = Theme.frame(track, "Fill", px(0, 0), UDim2.fromScale(0, 1), Colors.Accent)
    Theme.frame(panel, "ColumnRule", px(369, 82), px(1, 507), Colors.Border)
    local portrait = Theme.frame(panel, "Portrait", px(26, 183), px(328, 395), Colors.Surface)
    Theme.outline(portrait)

    local self = setmetatable({
        Overlay = backdrop,
        Preview = CharacterPreview.new(portrait),
        Progress = progress,
        ExperienceFill = fill,
        Tabs = {},
        Rows = {},
        OnTabChanged = actions.TabChanged,
    }, CharacterMenu)

    local tabs = { FIRST_TAB, "Proficiencies", "Total", "Identity" }
    if actions.Debug then
        table.insert(tabs, "Debugging")
    end
    for index, tabName in ipairs(tabs) do
        local left = 24 + (index - 1) * 152
        local button = Theme.button(panel, tabName .. "Tab", tabName, px(left, 9), px(144, 42), function()
            self:selectTab(tabName)
        end)
        local line = Theme.frame(panel, tabName .. "Underline", px(left, 55), px(144, 2), Colors.Accent)
        local page = Theme.frame(panel, tabName .. "Page", px(386, 77), px(610, 519))
        self.Tabs[tabName] = { Button = button, Line = line, Page = page }
    end
    self.Tabs.Proficiencies.Render = ProgressionPages.proficiencies(self.Tabs.Proficiencies.Page)
    self.Tabs["Total"].Render = ProgressionPages.derived(self.Tabs["Total"].Page)
    self.Tabs.Identity.Render = ProgressionPages.identity(self.Tabs.Identity.Page)
    if actions.Debug then
        self.Tabs.Debugging.Render = DebugPage.new(self.Tabs.Debugging.Page, actions.Debug)
    end

    local page = self.Tabs.Attributes.Page
    ProgressionPages.heading(page, "Attributes")
    self.Points = Theme.label(page, "FreePoints", "", px(0, 48), px(310, 24), 15)
    Theme.label(page, "BulkAmountLabel", "Bulk add amount", px(410, 48), px(125, 24), 13)
    local bulkInput = Theme.create("TextBox", page, {
        Name = "BulkAmount",
        Position = px(536, 46),
        Size = px(63, 28),
        Text = "10",
        PlaceholderText = "1–100",
        ClearTextOnFocus = false,
        Font = Enum.Font.GothamMedium,
        TextSize = 14,
        TextColor3 = Colors.Text,
        BackgroundColor3 = Colors.Surface,
        BorderSizePixel = 0,
    })
    Theme.outline(bulkInput)
    local function bulkAmount()
        local amount = tonumber(bulkInput.Text)
        if amount and amount % 1 == 0 and amount >= 1 and amount <= Config.MaxStatValue then
            return amount
        end
        return 0
    end
    for index, statName in ipairs(Config.StatOrder) do
        self.Rows[statName] = createRow(page, index, statName, actions.Adjust, bulkAmount)
    end

    self.Status = Theme.label(page, "Status", "", px(0, 411), px(610, 38), 14)
    self.Status.TextWrapped = true
    self.Retry = Theme.button(page, "Retry", "Retry Loading", px(0, 477), px(186, 40), actions.Retry)
    self.Clear = Theme.button(page, "ClearDraft", "Clear Draft", px(0, 477), px(186, 40), actions.Clear)
    self.Reset = Theme.button(page, "ResetAttributes", "Reset Attributes", px(198, 477), px(192, 40), actions.Reset)
    self.Apply = Theme.button(page, "Apply", "Apply Points", px(402, 477), px(208, 40), actions.Apply)
    self.BulkInput = bulkInput
    self.BulkAmount = bulkAmount
    bulkInput:GetPropertyChangedSignal("Text"):Connect(function()
        if self.State then
            self:renderAttributes(self.State)
        end
    end)

    self:selectTab(FIRST_TAB)
    return self
end

function CharacterMenu:selectTab(name)
    if not self.Tabs[name] or self.ActiveTab == name then
        return
    end
    local previous = self.ActiveTab
    self.ActiveTab = name
    for tabName, tab in pairs(self.Tabs) do
        local active = tabName == name
        tab.Page.Visible = active
        tab.Line.Visible = active
        tab.Button.BackgroundTransparency = active and 0 or 1
        tab.Button.TextColor3 = active and Colors.Accent or Colors.Muted
    end
    if previous then
        self.OnTabChanged()
    end
end

function CharacterMenu:renderAttributes(state)
    local profile = state.Profile
    local left = profile and profile.StatPoints - state.DraftCost or 0
    self.Points.Text = profile and ("Unspent points: " .. left) or "Unspent points: —"
    self.Points.TextColor3 = left < 0 and Colors.Error or Colors.Accent
    local bulkAmount = self.BulkAmount()
    local editing = profile ~= nil and not state.Busy and not state.ResetArmed
    self.BulkInput.Interactable = editing
    for _, statName in ipairs(Config.StatOrder) do
        local row = self.Rows[statName]
        local value = profile and profile.Stats.Attributes[statName]
        local change = state.Draft[statName] or 0
        local room = value and math.min(left, Config.MaxStatValue - value - change) or 0
        if change > 0 and value then
            row.Value.Text = string.format("%d → %d", value, value + change)
        elseif value and value >= Config.MaxStatValue then
            row.Value.Text = tostring(value) .. " · Max"
        else
            row.Value.Text = value and tostring(value) or "—"
        end
        row.Value.TextColor3 = change > 0 and Colors.Accent or Colors.Text
        row.Effect.Text = attributeEffect(statName, state)
        row.Minus.Visible = change > 0
        row.Plus.Visible = room > 0
        row.Bulk.Visible = room > 0
        row.Bulk.Text = bulkAmount > 0 and ("+" .. math.min(room, bulkAmount)) or "Bulk"
        Theme.setButtonEnabled(row.Minus, editing and row.Minus.Visible)
        Theme.setButtonEnabled(row.Plus, editing and row.Plus.Visible)
        Theme.setButtonEnabled(row.Bulk, editing and row.Bulk.Visible and bulkAmount > 0)
    end

    self.Status.Text = state.Message
    self.Status.TextColor3 = state.Error and Colors.Error or Colors.Muted
    self.Retry.Visible = not profile and not state.Loading
    self.Clear.Visible = profile ~= nil
    self.Reset.Visible = profile ~= nil
    self.Apply.Visible = profile ~= nil
    self.Clear.Text = state.ResetArmed and "Cancel" or "Clear Draft"
    self.Reset.Text = state.ResetArmed and "Confirm Reset" or "Reset Attributes"
    self.Apply.Text = state.Busy and "Working…" or "Apply Points"
    Theme.setButtonEnabled(self.Clear, not state.Busy and (state.ResetArmed or state.DraftCost > 0))
    Theme.setButtonEnabled(self.Reset, not state.Busy and not state.Loading and state.Spent > 0, state.ResetArmed)
    Theme.setButtonEnabled(self.Apply, state.CanConfirm and not state.ResetArmed, true)
end

function CharacterMenu:render(state)
    self.State = state
    local profile = state.Profile
    local nextExperience = profile and profile.NextLevelExperience or 0
    local xpRatio = 0
    if profile and nextExperience > 0 then
        self.Progress.Text = string.format("Level %d  ·  XP %d / %d",
            profile.Level, profile.Experience, nextExperience)
        xpRatio = math.clamp(profile.Experience / nextExperience, 0, 1)
    elseif profile then
        self.Progress.Text = string.format("Level %d  ·  Max Level", profile.Level)
        xpRatio = 1
    else
        self.Progress.Text = state.Loading and "Loading profile…" or "Profile unavailable"
    end
    self.ExperienceFill.Size = UDim2.fromScale(xpRatio, 1)

    self:renderAttributes(state)
    for _, tab in pairs(self.Tabs) do
        if tab.Render then
            tab.Render(state)
        end
    end
end

return CharacterMenu
