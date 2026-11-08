-- Базовый тестовый интерфейс. Создаётся целиком из кода, поэтому
-- в Studio ничего рисовать не нужно. Позже заменится на настоящий MainUI.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local ProgressionConfig = require(
    ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("ProgressionConfig")
)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Events = Remotes:WaitForChild("Events")
local ProfileUpdated = Events:WaitForChild("ProfileUpdated")
local DebugRequest = Events:WaitForChild("DebugRequest")
local StatAllocationRequest = Events:WaitForChild("StatAllocationRequest")
local RequestProfile = Remotes:WaitForChild("Functions"):WaitForChild("RequestProfile")

local STAT_ORDER = ProgressionConfig.StatOrder

local WHITE = Color3.fromRGB(235, 235, 240)

-- ПОСТРОЕНИЕ ИНТЕРФЕЙСА -------------------------------------------------

local function create(className, props, parent)
    local instance = Instance.new(className)

    for key, value in pairs(props) do
        instance[key] = value
    end

    instance.Parent = parent

    return instance
end

local gui = create("ScreenGui", {
    Name = "TestUI",
    ResetOnSpawn = false,
}, playerGui)

local panel = create("Frame", {
    Name = "Panel",
    Size = UDim2.fromOffset(280, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    Position = UDim2.fromOffset(12, 12),
    BackgroundColor3 = Color3.fromRGB(25, 25, 30),
    BackgroundTransparency = 0.15,
    BorderSizePixel = 0,
}, gui)

create("UICorner", { CornerRadius = UDim.new(0, 8) }, panel)

create("UIPadding", {
    PaddingTop = UDim.new(0, 10),
    PaddingBottom = UDim.new(0, 10),
    PaddingLeft = UDim.new(0, 10),
    PaddingRight = UDim.new(0, 10),
}, panel)

create("UIListLayout", {
    Padding = UDim.new(0, 6),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, panel)

local function makeLabel(order, text, textSize)
    return create("TextLabel", {
        Size = UDim2.new(1, 0, 0, textSize + 4),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        Text = text,
        TextColor3 = WHITE,
        TextSize = textSize,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        LayoutOrder = order,
    }, panel)
end

-- Возвращает функцию update(value, maxValue)
local function makeBar(order, color, caption)
    local holder = create("Frame", {
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundColor3 = Color3.fromRGB(50, 50, 58),
        BorderSizePixel = 0,
        LayoutOrder = order,
    }, panel)

    create("UICorner", { CornerRadius = UDim.new(0, 4) }, holder)

    local fill = create("Frame", {
        Size = UDim2.fromScale(0, 1),
        BackgroundColor3 = color,
        BorderSizePixel = 0,
    }, holder)

    create("UICorner", { CornerRadius = UDim.new(0, 4) }, fill)

    local text = create("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        Text = caption,
        TextColor3 = WHITE,
        TextSize = 13,
        ZIndex = 2,
    }, holder)

    return function(value, maxValue)
        local ratio = 0

        if maxValue > 0 then
            ratio = math.clamp(value / maxValue, 0, 1)
        end

        fill.Size = UDim2.fromScale(ratio, 1)

        text.Text = string.format(
            "%s %d / %d",
            caption,
            math.floor(value + 0.5),
            math.floor(maxValue + 0.5)
        )
    end
end

makeLabel(1, "Core Framework Test", 16)
local levelLabel = makeLabel(2, "Level -", 14)
local updateHealth = makeBar(3, Color3.fromRGB(200, 60, 60), "HP")
local updateMana = makeBar(4, Color3.fromRGB(60, 110, 210), "Mana")
local goldLabel = makeLabel(5, "Gold: -", 14)
local statPointsLabel = makeLabel(6, "Stat points: -", 14)

-- Строки характеристик: название, значение и кнопка "+" (видна, если есть очки).
local statsHolder = create("Frame", {
    Name = "Stats",
    Size = UDim2.new(1, 0, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
    LayoutOrder = 7,
}, panel)

create("UIListLayout", {
    Padding = UDim.new(0, 4),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, statsHolder)

local statRows = {} -- [statName] = { Label, Button }

for index, statName in ipairs(STAT_ORDER) do
    local row = create("Frame", {
        Size = UDim2.new(1, 0, 0, 24),
        BackgroundTransparency = 1,
        LayoutOrder = index,
    }, statsHolder)

    local label = create("TextLabel", {
        Size = UDim2.new(1, -30, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        Text = statName .. ": -",
        TextColor3 = WHITE,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local button = create("TextButton", {
        Size = UDim2.fromOffset(24, 24),
        Position = UDim2.new(1, -24, 0, 0),
        BackgroundColor3 = Color3.fromRGB(70, 130, 90),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Text = "+",
        TextColor3 = WHITE,
        TextSize = 16,
        Visible = false,
    }, row)

    create("UICorner", { CornerRadius = UDim.new(0, 4) }, button)

    -- Сервер сам проверяет лимит частоты, имя характеристики и количество очков.
    button.Activated:Connect(function()
        StatAllocationRequest:FireServer(statName, 1)
    end)

    statRows[statName] = { Label = label, Button = button }
end

local statusLabel = makeLabel(8, "Loading profile...", 12)

-- Кнопки отладки: показываются только в Studio.
-- Реальная защита на сервере: DebugService не подписывается на события вне Studio.
if RunService:IsStudio() then
    local debugFrame = create("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = 9,
    }, panel)

    create("UIGridLayout", {
        CellSize = UDim2.new(0.5, -3, 0, 28),
        CellPadding = UDim2.fromOffset(6, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, debugFrame)

    local buttons = {
        { "+50 XP", "AddXP", 50 },
        { "+500 XP", "AddXP", 500 },
        { "+100 Gold", "AddGold", 100 },
        { "-20 HP", "DamageSelf", 20 },
        { "-30 Mana", "SpendMana", 30 },
        { "Restore", "RestoreAll", nil },
        { "Save now", "SaveNow", nil },
    }

    for index, info in ipairs(buttons) do
        local button = create("TextButton", {
            BackgroundColor3 = Color3.fromRGB(70, 70, 85),
            BorderSizePixel = 0,
            Font = Enum.Font.GothamMedium,
            Text = info[1],
            TextColor3 = WHITE,
            TextSize = 13,
            LayoutOrder = index,
        }, debugFrame)

        create("UICorner", { CornerRadius = UDim.new(0, 4) }, button)

        button.Activated:Connect(function()
            DebugRequest:FireServer(info[2], info[3])
        end)
    end
end

-- ОТОБРАЖЕНИЕ ДАННЫХ ----------------------------------------------------

local function renderProfile(data)
    if data.NextLevelExperience and data.NextLevelExperience > 0 then
        levelLabel.Text = string.format(
            "Level %d   XP %d / %d",
            data.Level,
            data.Experience,
            data.NextLevelExperience
        )
    else
        levelLabel.Text = string.format("Level %d   (MAX)", data.Level)
    end

    goldLabel.Text = "Gold: " .. tostring(data.Resources.Gold or 0)

    local points = data.StatPoints or 0

    statPointsLabel.Text = "Stat points: " .. tostring(points)

    for _, statName in ipairs(STAT_ORDER) do
        local row = statRows[statName]
        local value = data.Stats[statName]

        row.Label.Text = string.format("%s: %s", statName, tostring(value or "-"))

        -- Не показываем кнопку, если характеристика достигла серверного лимита.
        -- Серверная проверка остаётся обязательной: клиентскому UI доверять нельзя.
        row.Button.Visible = points > 0
            and type(value) == "number"
            and value < ProgressionConfig.MaxStatValue
    end
end

local function refreshMana()
    updateMana(
        player:GetAttribute("Mana") or 0,
        player:GetAttribute("MaxMana") or 0
    )
end

player:GetAttributeChangedSignal("Mana"):Connect(refreshMana)
player:GetAttributeChangedSignal("MaxMana"):Connect(refreshMana)
refreshMana()

local function bindCharacter(character)
    local humanoid = character:WaitForChild("Humanoid")

    local function refreshHealth()
        updateHealth(humanoid.Health, humanoid.MaxHealth)
    end

    humanoid.HealthChanged:Connect(refreshHealth)
    humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(refreshHealth)
    refreshHealth()
end

player.CharacterAdded:Connect(bindCharacter)

if player.Character then
    task.spawn(bindCharacter, player.Character)
end

-- ПОЛУЧЕНИЕ ПРОФИЛЯ -----------------------------------------------------

ProfileUpdated.OnClientEvent:Connect(renderProfile)

task.spawn(function()
    local data = RequestProfile:InvokeServer()

    if data then
        renderProfile(data)
        statusLabel.Text = "Profile loaded"
    else
        statusLabel.Text = "Profile was not received"
    end
end)