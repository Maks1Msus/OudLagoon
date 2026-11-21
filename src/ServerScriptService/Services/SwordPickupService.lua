local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config.SwordPickupConfig)
local WeaponService = require(script.Parent.WeaponService)

local SwordPickupService = {}
local initialized = false
local prompt, attachment
local lastRequest = {}

local function GroundPosition()
    local spawn = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
    local position = Config.Position
        or (spawn and spawn.CFrame:PointToWorldSpace(Config.SpawnOffset))
        or Config.FallbackPosition
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local excluded = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character then table.insert(excluded, player.Character) end
    end
    params.FilterDescendantsInstances = excluded
    params.RespectCanCollide = true
    params.IgnoreWater = true
    local ground = workspace:Raycast(position + Vector3.new(0, 16, 0), Vector3.new(0, -64, 0), params)
    return ground and ground.Position or position
end

local function CreatePart(model, name, size, cframe, color, material, collidable)
    local part = Instance.new("Part")
    part.Name = name
    part.Size = size
    part.CFrame = cframe
    part.Color = color
    part.Material = material
    part.Anchored = true
    part.CanCollide = collidable == true
    part.CanTouch = false
    part.CanQuery = collidable == true
    part.Parent = model
    return part
end

-- Triggered runs on the server; distance and character are checked again here.
function SwordPickupService:TryGive(player)
    if not prompt or not prompt.Parent or not prompt.Enabled or not attachment.Parent then
        return false, "PickupUnavailable"
    end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if player.Parent ~= Players or not character or not character.Parent
        or not humanoid or humanoid.Health <= 0 or not root then
        return false, "CharacterUnavailable"
    end
    if (root.Position - attachment.WorldPosition).Magnitude > Config.MaxActivationDistance then
        return false, "TooFar"
    end
    local now = os.clock()
    if now < (lastRequest[player] or 0) then return false, "Cooldown" end
    lastRequest[player] = now + Config.RequestCooldown
    if WeaponService:Has(player, "Sword") then return false, "AlreadyHave" end
    local tool, reason = WeaponService:Give(player, "Sword")
    return tool ~= nil, reason
end

function SwordPickupService:Init()
    if initialized then return end
    initialized = true
    if not Config.Enabled then return end
    if workspace:FindFirstChild(Config.StandName) then
        warn("[SwordPickupService] Stand name already exists:", Config.StandName)
        return
    end

    local position = GroundPosition()
    local model = Instance.new("Model")
    model.Name = Config.StandName
    local base = CreatePart(model, "Pedestal", Vector3.new(3, 0.5, 3),
        CFrame.new(position + Vector3.new(0, 0.25, 0)), Color3.fromRGB(82, 76, 66), Enum.Material.Slate, true)
    local center = CFrame.new(position)
    CreatePart(model, "DisplayBlade", Vector3.new(0.3, 2.8, 0.14), center * CFrame.new(0, 3, 0),
        Color3.fromRGB(190, 195, 205), Enum.Material.Metal)
    CreatePart(model, "DisplayGuard", Vector3.new(1.2, 0.15, 0.3), center * CFrame.new(0, 1.6, 0),
        Color3.fromRGB(145, 125, 80), Enum.Material.Metal)
    CreatePart(model, "DisplayGrip", Vector3.new(0.25, 0.85, 0.25), center * CFrame.new(0, 1.1, 0),
        Color3.fromRGB(70, 47, 33), Enum.Material.Wood)
    attachment = Instance.new("Attachment")
    attachment.Name = "PickupPoint"
    attachment.Position = Vector3.new(0, 1.8, 0)
    attachment.Parent = base
    prompt = Instance.new("ProximityPrompt")
    prompt.Name = "SwordPrompt"
    prompt.ObjectText = "Меч"
    prompt.ActionText = "Взять меч"
    prompt.KeyboardKeyCode = Enum.KeyCode.E
    prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
    prompt.MaxActivationDistance = Config.MaxActivationDistance
    prompt.HoldDuration = Config.HoldDuration
    prompt.RequiresLineOfSight = true
    prompt.Parent = attachment
    model.PrimaryPart = base
    model.Parent = workspace
    prompt.Triggered:Connect(function(player) self:TryGive(player) end)
    Players.PlayerRemoving:Connect(function(player) lastRequest[player] = nil end)
end

return SwordPickupService
