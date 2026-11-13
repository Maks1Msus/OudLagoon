-- Управление боем на клиенте: только ввод, анимации и визуальные эффекты.
-- Урон, цели, кулдаун и блок решает сервер. Клиент шлёт только намерения:
--   CombatRequest("Attack"), CombatStateRequest("BlockStart" | "BlockEnd" | "Sync").
--
-- ЛКМ: атака. Зажатие ЛКМ: повторные атаки с учётом кулдауна оружия.
-- ПКМ или F (удерживать): блок. Пока блок удерживается, атаки не отправляются.
-- Работает и без оружия, и с экипированным Tool, у которого есть атрибут CombatWeaponId.
--
-- Боевое состояние (combatState) клиент НЕ определяет: оно приходит от сервера
-- через CombatStateChanged и используется только для отображения и чтобы не слать
-- заведомо запрещённые команды. Окончательно решает сервер.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local CombatConfig = require(
    ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("CombatConfig")
)

local CombatStates = require(
    ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Constants"):WaitForChild("CombatStates")
)

local Events = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Events")
local CombatRequest = Events:WaitForChild("CombatRequest")
local CombatFeedback = Events:WaitForChild("CombatFeedback")
local CombatStateRequest = Events:WaitForChild("CombatStateRequest")
local CombatStateChanged = Events:WaitForChild("CombatStateChanged")

-- Небольшой запас сверх кулдауна, чтобы запрос не приходил на сервер чуть раньше времени
local CLIENT_COOLDOWN_MARGIN = 0.02

-- Как часто повторяется BlockStart, пока блок удерживается, но сервер его ещё не принял
-- (например, идёт собственная атака). Лимит сервера - 20 запросов в секунду.
local BLOCK_RETRY_INTERVAL = 0.1

-- В этих состояниях атаку отправлять бессмысленно: сервер её отклонит
local CANNOT_ATTACK_STATES = {
    [CombatStates.Blocking] = true,
    [CombatStates.Dodging] = true,
    [CombatStates.Stunned] = true,
    [CombatStates.Dead] = true,
}

local attackHeld = false
local blockHeld = false
local nextAttackAt = 0
local nextBlockRequestAt = 0

-- Последнее состояние, сообщённое сервером
local combatState = CombatStates.Idle

-- ОРУЖИЕ И АНИМАЦИИ -----------------------------------------------------

local function getHumanoid()
    local character = player.Character

    return character and character:FindFirstChildOfClass("Humanoid")
end

-- Клиент использует конфиг только для темпа атак. Сервер определяет оружие сам.
local function getWeaponConfig()
    local character = player.Character
    local tool = character and character:FindFirstChildOfClass("Tool")

    if tool then
        local weaponId = tool:GetAttribute(CombatConfig.WeaponAttribute)
        local weapon = type(weaponId) == "string" and CombatConfig.Weapons[weaponId]

        if weapon then
            return weapon
        end
    end

    return CombatConfig.Weapons[CombatConfig.UnarmedId]
end

local tracks = setmetatable({}, { __mode = "k" }) -- [animator] = { [animationId] = track }

local function playSwing(weapon)
    local animationId = weapon.AnimationId

    if not animationId then
        return -- пока нет ассетов анимации
    end

    local humanoid = getHumanoid()
    local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")

    if not animator then
        return
    end

    local perAnimator = tracks[animator]

    if not perAnimator then
        perAnimator = {}
        tracks[animator] = perAnimator
    end

    local track = perAnimator[animationId]

    if not track then
        local animation = Instance.new("Animation")
        animation.AnimationId = animationId

        track = animator:LoadAnimation(animation)
        perAnimator[animationId] = track
    end

    track:Play()
end

-- АТАКА -----------------------------------------------------------------

local function tryAttack()
    local humanoid = getHumanoid()

    if not humanoid or humanoid.Health <= 0 then
        return
    end

    -- Намерение защищаться важнее атаки; запрещённые состояния не расходуют кулдаун
    if blockHeld or CANNOT_ATTACK_STATES[combatState] then
        return
    end

    local now = os.clock()

    if now < nextAttackAt then
        return
    end

    local weapon = getWeaponConfig()

    -- Новый удар нельзя начать, пока идёт предыдущий (Startup + Active + Recovery),
    -- а кулдаун оружия считается отдельно: ждём большее из двух значений.
    local timing = weapon.AttackTiming
    local swingDuration = timing and (timing.Startup + timing.Active + timing.Recovery) or 0

    nextAttackAt = now + math.max(weapon.Cooldown, swingDuration) + CLIENT_COOLDOWN_MARGIN

    CombatRequest:FireServer("Attack")
    playSwing(weapon)
end

-- БЛОК ------------------------------------------------------------------

local function isBlockInput(input)
    return input.KeyCode == Enum.KeyCode.F
end

-- Просит сервер начать блок. Сервер может отказать (идёт атака, оглушение и т.д.),
-- поэтому, пока блок удерживается, запрос повторяется с небольшим интервалом.
local function requestBlock()
    local humanoid = getHumanoid()

    if not humanoid or humanoid.Health <= 0 then
        return
    end

    if combatState == CombatStates.Blocking or combatState == CombatStates.Dead then
        return
    end

    local now = os.clock()

    if now < nextBlockRequestAt then
        return
    end

    nextBlockRequestAt = now + BLOCK_RETRY_INTERVAL

    CombatStateRequest:FireServer("BlockStart")
end

local function releaseBlock()
    if not blockHeld then
        return
    end

    blockHeld = false

    -- Всегда сообщаем серверу: лишний BlockEnd он игнорирует
    CombatStateRequest:FireServer("BlockEnd")
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    -- gameProcessed: клик по кнопке интерфейса или ввод в чат не должны считаться боем
    if gameProcessed then
        return
    end

    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        attackHeld = true
        tryAttack()
    elseif isBlockInput(input) then
        blockHeld = true
        nextBlockRequestAt = 0
        requestBlock()
    end
end)

-- Отпускание обрабатывается без проверки gameProcessed: блок не должен "залипнуть"
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        attackHeld = false
    elseif isBlockInput(input) then
        releaseBlock()
    end
end)

-- Окно потеряло фокус: отпускание кнопки мы не увидим, поэтому сбрасываем всё сами
UserInputService.WindowFocusReleased:Connect(function()
    attackHeld = false
    releaseBlock()
end)

-- Зажатие ЛКМ: повторяем атаки, как только проходит кулдаун.
-- Зажатие блока: повторяем запрос, пока сервер его не примет.
RunService.Heartbeat:Connect(function()
    if blockHeld then
        requestBlock()
    elseif attackHeld then
        tryAttack()
    end
end)

-- СОСТОЯНИЕ ОТ СЕРВЕРА --------------------------------------------------

CombatStateChanged.OnClientEvent:Connect(function(payload)
    if type(payload) == "table" and type(payload.State) == "string" then
        combatState = payload.State
    end
end)

-- Новый персонаж всегда начинает в Idle; уточняем у сервера на случай расхождения
player.CharacterAdded:Connect(function()
    combatState = CombatStates.Idle
    nextBlockRequestAt = 0

    CombatStateRequest:FireServer("Sync")
end)

if player.Character then
    CombatStateRequest:FireServer("Sync")
end

-- ВИЗУАЛЬНАЯ ОБРАТНАЯ СВЯЗЬ ----------------------------------------------

local DAMAGE_COLOR = Color3.fromRGB(255, 220, 90)
local BLOCKED_COLOR = Color3.fromRGB(170, 190, 220)
local PARRIED_COLOR = Color3.fromRGB(120, 200, 255)

-- result: "Hit" | "Blocked" | "Parried" (от сервера; для старых данных может быть nil)
local function showDamageNumber(target, damage, result)
    if typeof(target) ~= "Instance" or type(damage) ~= "number" then
        return
    end

    local text = tostring(math.floor(damage))
    local color = DAMAGE_COLOR

    if result == CombatStates.DamageResults.Parried then
        text = "Parried!"
        color = PARRIED_COLOR
    elseif result == CombatStates.DamageResults.Blocked then
        text = text .. " (blocked)"
        color = BLOCKED_COLOR
    end

    local adornee = target:FindFirstChild("Head") or target:FindFirstChild("HumanoidRootPart")

    if not adornee then
        return
    end

    local billboard = Instance.new("BillboardGui")
    billboard.Size = UDim2.fromOffset(140, 30)
    billboard.StudsOffset = Vector3.new(0, 3, 0)
    billboard.AlwaysOnTop = true
    billboard.Adornee = adornee
    billboard.Parent = player:WaitForChild("PlayerGui")

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.Text = text
    label.TextColor3 = color
    label.TextStrokeTransparency = 0.4
    label.TextSize = 22
    label.Parent = billboard

    local tweenInfo = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

    TweenService:Create(billboard, tweenInfo, {
        StudsOffset = Vector3.new(0, 5, 0),
    }):Play()

    local fade = TweenService:Create(label, tweenInfo, {
        TextTransparency = 1,
        TextStrokeTransparency = 1,
    })

    fade.Completed:Connect(function()
        billboard:Destroy()
    end)

    fade:Play()
end

CombatFeedback.OnClientEvent:Connect(function(payload)
    if type(payload) == "table" and payload.Kind == "Hit" then
        showDamageNumber(payload.Target, payload.Damage, payload.Result)
    end
end)