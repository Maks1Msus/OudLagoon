local Theme = {}

Theme.Colors = {
    Panel = Color3.fromRGB(28, 30, 33),
    Surface = Color3.fromRGB(41, 43, 46),
    Border = Color3.fromRGB(91, 85, 75),
    Text = Color3.fromRGB(241, 232, 214),
    Muted = Color3.fromRGB(180, 173, 160),
    Disabled = Color3.fromRGB(140, 135, 127),
    Accent = Color3.fromRGB(208, 179, 123),
    Ink = Color3.fromRGB(35, 29, 22),
    Error = Color3.fromRGB(237, 156, 137),
    Health = Color3.fromRGB(157, 72, 67),
    Mana = Color3.fromRGB(65, 112, 144),
}

function Theme.create(className, parent, properties)
    local instance = Instance.new(className)
    for key, value in pairs(properties) do
        instance[key] = value
    end
    instance.Parent = parent
    return instance
end

function Theme.frame(parent, name, position, size, color)
    return Theme.create("Frame", parent, {
        Name = name,
        Position = position,
        Size = size,
        BorderSizePixel = 0,
        BackgroundColor3 = color or Theme.Colors.Panel,
        BackgroundTransparency = color and 0 or 1,
    })
end

function Theme.label(parent, name, text, position, size, textSize)
    return Theme.create("TextLabel", parent, {
        Name = name,
        Text = text,
        Position = position,
        Size = size,
        BackgroundTransparency = 1,
        TextColor3 = Theme.Colors.Text,
        Font = Enum.Font.Gotham,
        TextSize = textSize,
        TextXAlignment = Enum.TextXAlignment.Left,
    })
end

function Theme.button(parent, name, text, position, size, callback)
    local button = Theme.create("TextButton", parent, {
        Name = name,
        Text = text,
        Position = position,
        Size = size,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamMedium,
        TextSize = 15,
    })
    Theme.setButtonEnabled(button, true)
    button.Activated:Connect(callback)
    return button
end

function Theme.setButtonEnabled(button, enabled, primary)
    button.Interactable = enabled
    button.Selectable = enabled
    button.AutoButtonColor = enabled
    button.BackgroundColor3 = enabled and primary and Theme.Colors.Accent or Theme.Colors.Surface
    button.TextColor3 = enabled and (primary and Theme.Colors.Ink or Theme.Colors.Text)
        or Theme.Colors.Disabled
end

function Theme.outline(parent, color)
    Theme.create("UIStroke", parent, {
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        Color = color or Theme.Colors.Border,
        Thickness = 1,
    })
end

return Theme
