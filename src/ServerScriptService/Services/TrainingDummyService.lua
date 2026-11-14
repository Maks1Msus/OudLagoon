
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TrainingDummyConfig = require(
    ReplicatedStorage.Shared.Config.TrainingDummyConfig
)

local CombatConfig = require(
    ReplicatedStorage.Shared.Config.CombatConfig
)

local CombatStates = require(
    ReplicatedStorage.Shared.Constants.CombatStates
)

local CombatService = require(script.Parent.CombatService)
local CombatStateService = require(script.Parent.CombatStateService)
local NPCCombatAnimationService = require(script.Parent.NPCCombatAnimationService)

local TrainingDummyService = {}

local MAX_DUMMIES = 5
local DUMMY_HEALTH = 100
local SPAWN_DISTANCE = 7
local CORPSE_LIFETIME = 3

local DUMMY_FOLDER_NAME = "DebugDummies"

local dummyFolder
local nextDummyId = 0

local function GetOrCreateFolder()
    local folder = Workspace:FindFirstChild(DUMMY_FOLDER_NAME)

    if not folder then
        folder = Instance.new("Folder")
        folder.Name = DUMMY_FOLDER_NAME
        folder.Parent = Workspace
    end

    return folder
end

local function GetDummies()
    local result = {}

    for _, instance in ipairs(dummyFolder:GetChildren()) do
        if instance:IsA("Model")
            and instance:GetAttribute("IsTrainingDummy") then
            table.insert(result, instance)
        end
    end

    table.sort(result, function(a, b)
        return (a:GetAttribute("TrainingDummyId") or 0)
            < (b:GetAttribute("TrainingDummyId") or 0)
    end)

    return result
end

local function GetSpawnCFrame(player)
    local character = player.Character

    if not character then
        return nil
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")

    if not humanoid or humanoid.Health <= 0 or not root then
        return nil
    end

    local spawnPosition =
        (root.CFrame * CFrame.new(0, 0, -SPAWN_DISTANCE)).Position

    local lookAt = Vector3.new(
        root.Position.X,
        spawnPosition.Y,
        root.Position.Z
    )

    return CFrame.lookAt(spawnPosition, lookAt)
end

local function CreateR6Model()
    local description = Instance.new("HumanoidDescription")

    -- Нейтральная внешность манекена.
    local bodyColor = Color3.fromRGB(180, 155, 125)

    description.HeadColor = bodyColor
    description.TorsoColor = bodyColor
    description.LeftArmColor = bodyColor
    description.RightArmColor = bodyColor
    description.LeftLegColor = bodyColor
    description.RightLegColor = bodyColor

    local success, model = pcall(function()
        return Players:CreateHumanoidModelFromDescriptionAsync(
            description,
            Enum.HumanoidRigType.R6
        )
    end)

    description:Destroy()

    if not success or not model then
        warn("[TrainingDummyService] Failed to create R6 model:", model)
        return nil
    end

    local humanoid = model:FindFirstChildOfClass("Humanoid")
    local root = model:FindFirstChild("HumanoidRootPart")

    if not humanoid or not root or humanoid.RigType ~= Enum.HumanoidRigType.R6 then
        model:Destroy()
        warn("[TrainingDummyService] Generated model is not a valid R6 rig")
        return nil
    end

    return model, humanoid, root
end

-- ПОВЕДЕНИЕ --------------------------------------------------------------

local function RandomBetween(range)
    return range.Min + math.random() * (range.Max - range.Min)
end

-- Манекен "жив" для поведения, пока он в мире и не погиб.
local function IsActive(model, humanoid)
    return model.Parent ~= nil and humanoid.Health > 0
end

-- Режим Blocking: пауза -> поднять блок -> держать -> опустить, по кругу.
-- Блок идёт через общую боевую систему (CombatStateService), как у игрока:
-- окно парирования, направление и снижение урона считает ApplyDamage.
local function RunBlockingBehavior(model, humanoid, modeConfig)
    task.spawn(function()
        while IsActive(model, humanoid) do
            task.wait(RandomBetween(modeConfig.IdleTime))

            if not IsActive(model, humanoid) then
                break
            end

            -- Блок может не начаться (например, манекен в другом состоянии): тогда просто ждём дальше
            if CombatStateService:StartBlock(model) then
                task.wait(RandomBetween(modeConfig.HoldTime))

                if IsActive(model, humanoid) then
                    CombatStateService:StopBlock(model)
                end
            end
        end
    end)
end

-- Ближайший живой игрок в пределах range (по HumanoidRootPart) либо nil.
local function FindNearestPlayerRoot(root, range)
    local nearestRoot
    local nearestDistance = range

    for _, player in ipairs(Players:GetPlayers()) do
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local targetRoot = character and character:FindFirstChild("HumanoidRootPart")

        if humanoid and humanoid.Health > 0 and targetRoot then
            local distance = (targetRoot.Position - root.Position).Magnitude

            if distance <= nearestDistance then
                nearestRoot = targetRoot
                nearestDistance = distance
            end
        end
    end

    return nearestRoot
end

-- Плавно поворачивает манекен к точке в горизонтальной плоскости.
local function FaceTowards(root, targetPosition, alpha)
    local flatTarget = Vector3.new(targetPosition.X, root.Position.Y, targetPosition.Z)

    if (flatTarget - root.Position).Magnitude < 0.05 then
        return
    end

    root.CFrame = root.CFrame:Lerp(CFrame.lookAt(root.Position, flatTarget), alpha)
end

-- Угол (градусы, по горизонтали) между взглядом манекена и направлением на цель.
local function AngleToTarget(root, offset)
    local look = root.CFrame.LookVector
    local flatLook = Vector3.new(look.X, 0, look.Z)
    local flatOffset = Vector3.new(offset.X, 0, offset.Z)

    if flatLook.Magnitude < 1e-3 or flatOffset.Magnitude < 1e-3 then
        return 0
    end

    local cosAngle = math.clamp(flatLook.Unit:Dot(flatOffset.Unit), -1, 1)

    return math.deg(math.acos(cosAngle))
end

-- Режим Aggressive: заметил игрока -> повернулся -> если игрок в зоне удара достаточно долго
-- и манекен смотрит на него, атакует через CombatService (тот же путь, что и у игрока).
-- Удар полностью проверяется боевой системой: состояние, кулдаун, область, блок, парирование.
local function RunAggressiveBehavior(model, humanoid, modeConfig)
    local root = model:FindFirstChild("HumanoidRootPart")

    if not root then
        return
    end

    local weapon = CombatConfig.Weapons[CombatConfig.UnarmedId]

    task.spawn(function()
        local engagedSince = nil -- с какого момента игрок находится в зоне удара

        while IsActive(model, humanoid) do
            local targetRoot = FindNearestPlayerRoot(root, modeConfig.DetectionRange)

            if targetRoot then
                -- Во время замаха и блока манекен не следит за игроком
                if CombatStateService:GetState(model) == CombatStates.Idle then
                    FaceTowards(root, targetRoot.Position, modeConfig.TurnAlpha)
                end

                local offset = targetRoot.Position - root.Position

                if offset.Magnitude <= weapon.AttackRange then
                    engagedSince = engagedSince or os.clock()

                    if os.clock() - engagedSince >= modeConfig.ReactionTime
                        and AngleToTarget(root, offset) <= modeConfig.MaxAttackAngle
                    then
                        -- Отказ (кулдаун, не то состояние) - обычная ситуация, просто ждём
                        CombatService:PerformNPCAttack(model, { Strength = modeConfig.Strength })
                    end
                else
                    engagedSince = nil
                end
            else
                engagedSince = nil
            end

            task.wait(modeConfig.TickInterval)
        end
    end)
end

local BEHAVIORS = {
    Blocking = RunBlockingBehavior,
    Aggressive = RunAggressiveBehavior,
}

function TrainingDummyService:Init()
    dummyFolder = GetOrCreateFolder()

    -- Не начинаем ID заново, если сервис инициализируется повторно.
    for _, dummy in ipairs(GetDummies()) do
        nextDummyId = math.max(
            nextDummyId,
            dummy:GetAttribute("TrainingDummyId") or 0
        )
    end

    print("[TrainingDummyService] Initialized")
end

-- mode - ключ из TrainingDummyConfig.Modes ("Passive", "Blocking"); по умолчанию Passive.
function TrainingDummyService:SpawnForPlayer(player, mode)
    if not dummyFolder then
        warn("[TrainingDummyService] Service is not initialized")
        return false
    end

    mode = mode or TrainingDummyConfig.DefaultMode

    local modeConfig = TrainingDummyConfig.Modes[mode]

    if not modeConfig then
        warn("[TrainingDummyService] Unknown mode:", mode)
        return false
    end

    local spawnCFrame = GetSpawnCFrame(player)

    if not spawnCFrame then
        return false
    end

    local currentDummies = GetDummies()

    if #currentDummies >= MAX_DUMMIES then
        warn("[TrainingDummyService] Maximum dummy count reached")
        return false
    end

    local model, humanoid, root = CreateR6Model()

    if not model then
        return false
    end

    nextDummyId += 1

    model.Name = "Training Dummy " .. nextDummyId
    model:SetAttribute("IsTrainingDummy", true)
    model:SetAttribute("TrainingDummyId", nextDummyId)
    model:SetAttribute("TrainingDummyMode", mode)

    humanoid.DisplayName = modeConfig.DisplayName
    humanoid.MaxHealth = DUMMY_HEALTH
    humanoid.Health = DUMMY_HEALTH
    humanoid.WalkSpeed = 0
    humanoid.JumpPower = 0
    humanoid.JumpHeight = 0
    humanoid.AutoRotate = false
    humanoid.BreakJointsOnDeath = false
    humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOn
    humanoid.NameDisplayDistance = 60
    humanoid.HealthDisplayDistance = 60

    -- Сначала задаём позицию, затем помещаем модель в Workspace.
    model:PivotTo(spawnCFrame)
    model.PrimaryPart = root
    model.Parent = dummyFolder

    -- Сервер остаётся владельцем физики NPC.
    pcall(function()
        root:SetNetworkOwner(nil)
    end)

    -- Анимации NPC (блок, реакции) и боевое состояние манекена
    NPCCombatAnimationService:Register(model)

    humanoid.Died:Connect(function()
        -- Смерть прерывает блок и останавливает боевую анимацию
        CombatStateService:SetDead(model)
        NPCCombatAnimationService:Unregister(model)

        Debris:AddItem(model, CORPSE_LIFETIME)
    end)

    local behavior = BEHAVIORS[mode]

    if behavior then
        behavior(model, humanoid, modeConfig)
    end

    print(
        "[TrainingDummyService] Spawned",
        model.Name,
        "mode:",
        mode,
        "for",
        player.Name
    )

    return true, model
end

function TrainingDummyService:RemoveLast()
    local dummies = GetDummies()
    local dummy = dummies[#dummies]

    if not dummy then
        return false
    end

    dummy:Destroy()

    return true
end

function TrainingDummyService:RemoveAll()
    local dummies = GetDummies()
    local removedCount = #dummies

    for _, dummy in ipairs(dummies) do
        dummy:Destroy()
    end

    return removedCount
end

function TrainingDummyService:GetCount()
    return #GetDummies()
end

return TrainingDummyService
