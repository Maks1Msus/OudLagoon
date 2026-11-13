local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local CombatConfig = require(
    ReplicatedStorage.Shared.Config.CombatConfig
)

local DataService = require(script.Parent.DataService)
local RemoteService = require(script.Parent.RemoteService)
local PlayerService = require(script.Parent.PlayerService)
local CharacterService = require(script.Parent.CharacterService)
local ProgressionService = require(script.Parent.ProgressionService)

local DebugService = {}

local Check = RemoteService.Check

local function GetHumanoid(player)
    local character = player.Character

    return character and character:FindFirstChildOfClass("Humanoid")
end

-- Все действия выполняются на сервере над серверным профилем.
-- Клиент присылает только название действия и число.
local Actions = {}

-- Опыт начисляется через ProgressionService, поэтому работает
-- настоящая кривая уровней и выдаются очки характеристик.
function Actions.AddXP(player, _profile, amount)
    ProgressionService:AddExperience(player, math.floor(amount or 50))
end

function Actions.AddGold(player, profile, amount)
    profile.Resources.Gold += math.floor(amount or 100)

    PlayerService:PushProfile(player)
end

function Actions.DamageSelf(player, _profile, amount)
    local humanoid = GetHumanoid(player)

    if humanoid then
        humanoid:TakeDamage(amount or 20)
    end
end

function Actions.SpendMana(player, _profile, amount)
    CharacterService:SpendMana(player, amount or 30)
end

function Actions.RestoreAll(player, _profile)
    local humanoid = GetHumanoid(player)

    if humanoid then
        humanoid.Health = humanoid.MaxHealth
    end

    CharacterService:RestoreMana(player)
end

function Actions.SaveNow(player, _profile)
    DataService:SaveProfile(player)
end

-- БОЕВЫЕ ТЕСТЫ -----------------------------------------------------------

local MAX_DUMMIES = 5

-- Очки характеристик для быстрой проверки влияния Strength на урон.
function Actions.AddStatPoints(player, profile, amount)
    profile.StatPoints += math.floor(amount or 50)

    CharacterService:RefreshAttributes(player, profile)
    PlayerService:PushProfile(player)
end

-- Тестовый меч. Оружие распознаётся по атрибуту CombatWeaponId, который ставит сервер.
function Actions.GiveSword(player)
    local backpack = player:FindFirstChildOfClass("Backpack")
    local character = player.Character

    if not backpack then
        return
    end

    if backpack:FindFirstChild("Sword") or (character and character:FindFirstChild("Sword")) then
        return
    end

    local tool = Instance.new("Tool")
    tool.Name = "Sword"
    tool.CanBeDropped = false
    tool:SetAttribute(CombatConfig.WeaponAttribute, "Sword")

    local handle = Instance.new("Part")
    handle.Name = "Handle"
    handle.Size = Vector3.new(0.4, 4, 0.4)
    handle.Color = Color3.fromRGB(190, 195, 205)
    handle.Material = Enum.Material.Metal
    handle.Massless = true
    handle.Parent = tool

    tool.Parent = backpack
end

-- Неподвижный манекен с обычным Humanoid в 7 studs перед игроком.
function Actions.SpawnDummy(player)
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")

    if not root then
        return
    end

    local folder = workspace:FindFirstChild("DebugDummies")

    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "DebugDummies"
        folder.Parent = workspace
    end

    local existing = folder:GetChildren()

    if #existing >= MAX_DUMMIES then
        existing[1]:Destroy()
    end

    -- Центр корня персонажа обычно на 3 studs выше пола; манекен высотой 5 studs
    local forward = (root.CFrame * CFrame.new(0, 0, -7)).Position
    local position = Vector3.new(forward.X, root.Position.Y - 0.5, forward.Z)
    local lookAt = Vector3.new(root.Position.X, position.Y, root.Position.Z)
    local bodyCFrame = CFrame.lookAt(position, lookAt)

    local model = Instance.new("Model")
    model.Name = "Training Dummy"

    local body = Instance.new("Part")
    body.Name = "HumanoidRootPart"
    body.Size = Vector3.new(2, 5, 1)
    body.Anchored = true
    body.Color = Color3.fromRGB(180, 140, 90)
    body.CFrame = bodyCFrame
    body.Parent = model

    local head = Instance.new("Part")
    head.Name = "Head"
    head.Size = Vector3.new(1.6, 1.6, 1.6)
    head.Anchored = true
    head.Color = Color3.fromRGB(200, 160, 110)
    head.CFrame = bodyCFrame * CFrame.new(0, 3.3, 0)
    head.Parent = model

    local humanoid = Instance.new("Humanoid")
    humanoid.DisplayName = "Training Dummy"
    humanoid.MaxHealth = 100
    humanoid.Health = 100
    humanoid.Parent = model

    model.PrimaryPart = body
    model.Parent = folder

    humanoid.Died:Connect(function()
        Debris:AddItem(model, 2)
    end)
end

function DebugService:Init()
    -- В опубликованной игре обработчика нет вообще: вызовы клиента просто игнорируются.
    if not RunService:IsStudio() then
        return
    end

    RemoteService:OnEvent("DebugRequest", {
        RateLimit = 5,
        Validate = function(action, amount)
            return Check.String(action, 32)
                and (amount == nil or Check.Number(amount, 1, 100000))
        end,
    }, function(player, action, amount)
        local handler = Actions[action]

        if not handler then
            return
        end

        local profile = DataService:GetProfile(player)

        if not profile then
            return
        end

        handler(player, profile, amount)
    end)

    print("[DebugService] Studio debug actions enabled")
end

return DebugService