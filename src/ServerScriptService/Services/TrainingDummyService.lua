
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

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

function TrainingDummyService:SpawnForPlayer(player)
    if not dummyFolder then
        warn("[TrainingDummyService] Service is not initialized")
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
    model:SetAttribute("TrainingDummyMode", "Passive")

    humanoid.DisplayName = "Training Dummy"
    humanoid.MaxHealth = DUMMY_HEALTH
    humanoid.Health = DUMMY_HEALTH
    humanoid.WalkSpeed = 0
    humanoid.JumpPower = 0
    humanoid.JumpHeight = 0
    humanoid.AutoRotate = false
    humanoid.BreakJointsOnDeath = false
    humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.Always
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

    humanoid.Died:Connect(function()
        Debris:AddItem(model, CORPSE_LIFETIME)
    end)

    print(
        "[TrainingDummyService] Spawned",
        model.Name,
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
