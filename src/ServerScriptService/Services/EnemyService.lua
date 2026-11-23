local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Config = require(ReplicatedStorage.Shared.Config.EnemyConfig)
local CombatStateService = require(script.Parent.CombatStateService)
local CombatMovementService = require(script.Parent.CombatMovementService)
local NPCCombatAnimationService = require(script.Parent.NPCCombatAnimationService)
local EnemyCombatService = require(script.Parent.EnemyCombatService)

local PostureService = require(script.Parent.PostureService)
local EnemyService = {}
local initialized = false
local slots = {}
local folder, template

local function SpawnFrame(config, humanoid, root, model)
    local spawn = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
    local position = config.Position or (spawn and spawn.CFrame:PointToWorldSpace(config.SpawnOffset)) or config.SpawnOffset
    local excluded = { folder }
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character then table.insert(excluded, player.Character) end
    end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = excluded
    params.RespectCanCollide = true
    params.IgnoreWater = true
    local hit = workspace:Raycast(position + Vector3.new(0, 16, 0), Vector3.new(0, -64, 0), params)
    local leg = model:FindFirstChild("Left Leg")
    local height = root.Size.Y * 0.5 + humanoid.HipHeight + (leg and leg.Size.Y or 0)
    return CFrame.new((hit and hit.Position or position) + Vector3.new(0, height + 0.1, 0))
        * CFrame.Angles(0, math.rad(config.Yaw or 0), 0)
end

local function SpawnSlot(slot)
    slot.Generation = slot.Generation + 1
    local generation = slot.Generation
    slot.RespawnToken = nil
    local model = template:Clone()
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    local root = model:FindFirstChild("HumanoidRootPart")
    local settings = Config.Types[slot.Config.EnemyType]
    if not humanoid or not root or humanoid.RigType ~= Enum.HumanoidRigType.R6 then
        model:Destroy()
        warn("[EnemyService] TrainingEnemy template must be a valid R6 rig")
        return nil
    end
    model.Name = slot.Config.Id
    model.PrimaryPart = root
    model:SetAttribute("EnemyType", slot.Config.EnemyType)
    model:SetAttribute("AIProfile", slot.Profile or slot.Config.AIProfile)
    model:SetAttribute("CombatWeaponId", "Unarmed")
    model:SetAttribute("Respawn", slot.Config.Respawn ~= false)
    model:SetAttribute("AIState", "Idle")
    humanoid.DisplayName = "Training Enemy"
    humanoid.MaxHealth = settings.MaxHealth
    humanoid.Health = settings.MaxHealth
    humanoid.AutoRotate = false
    humanoid.BreakJointsOnDeath = false
    humanoid.JumpPower = 0
    humanoid.JumpHeight = 0
    humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOn
    humanoid.NameDisplayDistance = 60
    humanoid.HealthDisplayDistance = 60
    if not humanoid:FindFirstChildOfClass("Animator") then Instance.new("Animator", humanoid) end
    slot.Home = slot.Home or SpawnFrame(slot.Config, humanoid, root, model)
    model:PivotTo(slot.Home)
    slot.Model = model
    local dead = false
    humanoid.Died:Connect(function()
        if dead or slot.Generation ~= generation or slot.Model ~= model then return end
        dead = true
        model:SetAttribute("AIState", "Dead")
        CombatStateService:SetDead(model)
        EnemyCombatService:Unregister(model)
        NPCCombatAnimationService:Unregister(model)
        slot.Profile = model:GetAttribute("AIProfile")
        if model:GetAttribute("Respawn") then
            local token = {}
            slot.RespawnToken = token
            task.delay(settings.RespawnTime, function()
                if Config.Enabled and slot.Generation == generation and slot.RespawnToken == token then
                    SpawnSlot(slot)
                end
            end)
        end
        task.delay(settings.CorpseLifetime, function()
            if model.Parent then model:Destroy() end
        end)
    end)
    model.Destroying:Once(function()
        EnemyCombatService:Unregister(model)
        NPCCombatAnimationService:Unregister(model)
        CombatStateService:SetDead(model)
        if slot.Model == model then
            slot.Model = nil
            if not dead then
                slot.Generation = slot.Generation + 1 -- manual removal cancels pending lifecycle work
                slot.RespawnToken = nil
            end
        end
    end)
    CombatStateService:ResetCharacter(model)
    CombatMovementService:SetBaseWalkSpeed(humanoid, settings.WalkSpeed)
    PostureService:RegisterCharacter(model, { Max = settings.MaxPosture, RecoveryPerSecond = settings.PostureRecovery })
    model.Parent = folder
    pcall(function() root:SetNetworkOwner(nil) end)
    game:GetService("CollectionService"):AddTag(model, "PostureNPC")
    NPCCombatAnimationService:Register(model)
    EnemyCombatService:Register(model, settings, slot.Home)
    return model
end

function EnemyService:Spawn(spawnConfig)
    if not Config.Enabled or not template or not Config.Types[spawnConfig.EnemyType] or not Config.Profiles[spawnConfig.AIProfile] then
        return nil, "UnavailableEnemyTypeOrProfile"
    end
    if slots[spawnConfig.Id] then return nil, "DuplicateSpawnId" end
    local slot = { Config = spawnConfig, Generation = 0 }
    slots[spawnConfig.Id] = slot
    return SpawnSlot(slot)
end

function EnemyService:Init()
    if initialized then return end
    initialized = true
    if not Config.Enabled then return end
    Config.Validate()
    local models = ServerStorage:FindFirstChild("NPCs")
    template = models and models:FindFirstChild("TrainingEnemy")
    if not template or not template:IsA("Model") then
        warn("[EnemyService] Missing ServerStorage/NPCs/TrainingEnemy template")
        return
    end
    folder = workspace:FindFirstChild(Config.FolderName)
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = Config.FolderName
        folder.Parent = workspace
    end
    EnemyCombatService:Init()
    for _, spawnConfig in ipairs(Config.Spawns) do self:Spawn(spawnConfig) end
end

return EnemyService
