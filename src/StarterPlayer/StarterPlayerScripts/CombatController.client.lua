-- Управление боем на клиенте: только ввод, анимации и визуальные эффекты.
-- Урон, цели и кулдаун решает сервер (CombatService). Клиент шлёт одну команду: "Attack".
--
-- ЛКМ: атака. Зажатие ЛКМ: повторные атаки с учётом кулдауна оружия.
-- Работает и без оружия, и с экипированным Tool, у которого есть атрибут CombatWeaponId.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local CombatConfig = require(
    ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("CombatConfig")
)

local Events = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Events")
local CombatRequest = Events:WaitForChild("CombatRequest")
local CombatFeedback = Events:WaitForChild("CombatFeedback")

-- Небольшой запас сверх кулдауна, чтобы запрос не приходил на сервер чуть раньше времени
local CLIENT_COOLDOWN_MARGIN = 0.02

local attackHeld = false
local nextAttackAt = 0

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

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    -- gameProcessed: клик по кнопке интерфейса не должен считаться атакой
    if gameProcessed then
        return
    end

    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        attackHeld = true
        tryAttack()
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        attackHeld = false
    end
end)

-- Зажатие ЛКМ: повторяем атаки, как только проходит кулдаун
RunService.Heartbeat:Connect(function()
    if attackHeld then
        tryAttack()
    end
end)

-- ВИЗУАЛЬНАЯ ОБРАТНАЯ СВЯЗЬ ----------------------------------------------

local function showDamageNumber(target, damage)
    if typeof(target) ~= "Instance" or type(damage) ~= "number" then
        return
    end

    local adornee = target:FindFirstChild("Head") or target:FindFirstChild("HumanoidRootPart")

    if not adornee then
        return
    end

    local billboard = Instance.new("BillboardGui")
    billboard.Size = UDim2.fromOffset(90, 30)
    billboard.StudsOffset = Vector3.new(0, 3, 0)
    billboard.AlwaysOnTop = true
    billboard.Adornee = adornee
    billboard.Parent = player:WaitForChild("PlayerGui")

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.Text = tostring(math.floor(damage))
    label.TextColor3 = Color3.fromRGB(255, 220, 90)
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
        showDamageNumber(payload.Target, payload.Damage)
    end
end)