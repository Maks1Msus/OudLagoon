-- Управление боем на клиенте: ввод и визуальная обратная связь (числа урона).
-- Анимации вынесены в CombatAnimationController.
-- Урон, цели, кулдаун и блок решает сервер. Клиент шлёт только намерения:
--   CombatRequest("Attack"), CombatStateRequest("BlockStart" | "BlockEnd" | "Sync").
--
-- ЛКМ: атака или одно нажатие в буфер во время текущего удара.
-- Each attack request requires a separate LMB press.
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
local DodgeDirections = require(ReplicatedStorage:WaitForChild("Shared")
    :WaitForChild("Combat"):WaitForChild("DodgeDirections"))
local DashMovement = require(script.Parent:WaitForChild("DashMovementController"))

local CombatStates = require(
    ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Constants"):WaitForChild("CombatStates")
)

local Events = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Events")
local CombatRequest = Events:WaitForChild("CombatRequest")
local CombatFeedback = Events:WaitForChild("CombatFeedback")
local CombatStateRequest = Events:WaitForChild("CombatStateRequest")
local CombatStateChanged = Events:WaitForChild("CombatStateChanged")

-- Минимальный интервал между запросами атаки.
local ATTACK_REQUEST_INTERVAL = 0.08
local nextAttackRequestAt = 0
local nextDodgeRequestAt = 0

-- Как часто повторяется BlockStart, пока блок удерживается, но сервер его ещё не принял
-- (например, идёт собственная атака). Лимит сервера - 20 запросов в секунду.
local BLOCK_RETRY_INTERVAL = 0.1

-- В этих состояниях атаку отправлять бессмысленно: сервер её отклонит
local CANNOT_ATTACK_STATES = {
    [CombatStates.UsingAbility] = true,
    [CombatStates.Blocking] = true,
    [CombatStates.Stunned] = true,
    [CombatStates.Ragdolled] = true,
    [CombatStates.Dead] = true,
}

local blockHeld = false
local nextBlockRequestAt = 0

-- Последнее состояние, сообщённое сервером
local combatState = CombatStates.Idle

-- ОРУЖИЕ И АНИМАЦИИ -----------------------------------------------------

local function getHumanoid()
    local character = player.Character

    return character and character:FindFirstChildOfClass("Humanoid")
end

-- Анимации здесь не проигрываются: их показывает CombatAnimationController
-- после того, как сервер подтвердил атаку (иначе отклонённая атака выглядела бы успешной).

-- АТАКА -----------------------------------------------------------------

local function tryAttack()
    local humanoid = getHumanoid()

    if not humanoid or humanoid.Health <= 0 then
        return
    end

    if blockHeld or CANNOT_ATTACK_STATES[combatState] then
        return
    end

    local now = os.clock()

    if now < nextAttackRequestAt then
        return
    end

    nextAttackRequestAt = now + ATTACK_REQUEST_INTERVAL

    if DashMovement.IsMoving() or combatState == CombatStates.Dodging then
        local requestId = DashMovement.GetAttackRequestId()
        if requestId then CombatStateRequest:FireServer("DashAttack", requestId) end
        return
    end
    CombatRequest:FireServer("Attack")
end

-- Movement direction is quantized locally; the server resolves and limits world motion.
local function getDashDirectionId(steering)
    local humanoid = getHumanoid()
    local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    if not humanoid or humanoid.Health <= 0 or not root then return nil end
    if steering and humanoid.MoveDirection.Magnitude < 0.05 then return nil end
    return DodgeDirections.FromLocalVector(root.CFrame:VectorToObjectSpace(humanoid.MoveDirection))
end

local function tryDodge()
    local now = os.clock()
    local directionId = getDashDirectionId()
    if not directionId or now < nextDodgeRequestAt then return end
    if combatState == CombatStates.UsingAbility or combatState == CombatStates.Stunned or combatState == CombatStates.Ragdolled or combatState == CombatStates.Dead
        or combatState == CombatStates.Dodging then return end
    local requestId = DashMovement.Request(directionId,
        combatState == CombatStates.Idle or combatState == CombatStates.Blocking)
    if not requestId then return end
    nextDodgeRequestAt = now + 0.1
    CombatStateRequest:FireServer("Dodge", directionId, requestId)
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

    if combatState == CombatStates.Blocking or combatState == CombatStates.Ragdolled or combatState == CombatStates.Dead
        or combatState == CombatStates.Dodging then
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
    if gameProcessed or player:GetAttribute("OudLagoonMenuOpen") then
        return
    end

    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        tryAttack()
    elseif input.KeyCode == Enum.KeyCode.R or input.UserInputType == Enum.UserInputType.MouseButton3 then
        local humanoid = getHumanoid()
        if humanoid and humanoid.Health > 0 and not blockHeld and combatState == CombatStates.Idle
            and not DashMovement.IsMoving() then
            CombatRequest:FireServer("Heavy")
        end
    elseif input.KeyCode == Enum.KeyCode.Q then
        tryDodge()
    elseif isBlockInput(input) then
        blockHeld = true
        nextBlockRequestAt = 0
        -- Fresh presses may use a server-granted combo-parry window during hitstun.
        CombatStateRequest:FireServer("ComboParry")
        requestBlock()
    end
end)

-- Отпускание обрабатывается без проверки gameProcessed: блок не должен "залипнуть"
UserInputService.InputEnded:Connect(function(input)
    if isBlockInput(input) then
        releaseBlock()
    end
end)

-- Окно потеряло фокус: отпускание кнопки мы не увидим, поэтому сбрасываем всё сами
UserInputService.WindowFocusReleased:Connect(function()
    releaseBlock()
end)

player:GetAttributeChangedSignal("OudLagoonMenuOpen"):Connect(function()
    if player:GetAttribute("OudLagoonMenuOpen") then
        releaseBlock()
    end
end)

-- Зажатие блока: повторяем запрос, пока сервер его не примет.
RunService.Heartbeat:Connect(function()
    if blockHeld then
        requestBlock()
    end
end)

-- СОСТОЯНИЕ ОТ СЕРВЕРА --------------------------------------------------

CombatStateChanged.OnClientEvent:Connect(function(payload)
    DashMovement.OnPayload(payload)
    if type(payload) == "table" and type(payload.State) == "string" then
        combatState = payload.State
    end
end)

-- Новый персонаж всегда начинает в Idle; уточняем у сервера на случай расхождения
player.CharacterAdded:Connect(function()
    combatState = CombatStates.Idle
    nextAttackRequestAt = 0
    nextDodgeRequestAt = 0
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
local function showDamageNumber(target, damage, result, postureBroken)
    if typeof(target) ~= "Instance" or type(damage) ~= "number" then
        return
    end

    local text = tostring(math.floor(damage))
    local color = DAMAGE_COLOR

    if postureBroken then
        text = text .. " (Posture Break)"
        color = Color3.fromRGB(225, 193, 255)
    elseif result == CombatStates.DamageResults.Parried then
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
        showDamageNumber(payload.Target, payload.Damage, payload.Result, payload.PostureBroken)
    end
end)
