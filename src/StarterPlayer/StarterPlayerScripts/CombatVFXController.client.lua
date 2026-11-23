local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"):WaitForChild("CombatVFXConfig"))
local CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))
local CombatStates = require(Shared:WaitForChild("Constants"):WaitForChild("CombatStates"))
local DashConfig = require(Shared:WaitForChild("Config"):WaitForChild("DashConfig"))
local DashDust = require(Shared:WaitForChild("Combat"):WaitForChild("DashDust"))
local event = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Events"):WaitForChild("CombatVFX")
if not Config.Enabled then
    return
end

local Attributes = Config.Attributes
local entries = {}
local connections = {}
local highlightCount = 0
local trailCount = 0

local folder = Instance.new("Folder")
folder.Name = "LocalCombatVFX"
folder.Parent = workspace
local dust = DashDust.new(folder, Config.DashDust)

local function IsNear(position)
    local camera = workspace.CurrentCamera
    return camera and (camera.CFrame.Position - position).Magnitude <= Config.RenderDistance
end

local function ClearHighlight(entry)
    if entry.Highlight then
        entry.Highlight:Destroy()
        entry.Highlight = nil
        entry.Color = nil
        highlightCount -= 1
    end
end

local function ClearTrail(entry)
    local resources = entry.TrailResources
    if not resources then
        return
    end
    entry.TrailResources = nil
    trailCount -= 1
    resources.Trail.Enabled = false
    for _, instance in ipairs({ resources.Trail, resources.Start, resources.Finish }) do
        Debris:AddItem(instance, Config.Trail.Lifetime + 0.05)
    end
end

local function RemoveCharacter(character)
    dust:Forget(character)
    local entry = entries[character]
    if entry then
        ClearHighlight(entry)
        ClearTrail(entry)
        entries[character] = nil
    end
end

local function AddCharacter(character)
    if character:IsA("Model") then
        entries[character] = entries[character] or {}
        entries[character].Tagged = true
    end
end

local function UntagCharacter(character)
    local entry = entries[character]
    if entry then
        entry.Tagged = false
        ClearTrail(entry)
        if not character.Parent or not entry.Reaction then
            RemoveCharacter(character)
        end
    end
end

local function UpdateHighlight(character, entry, state, phase, now, deltaTime)
    local baseColor
    local iframeEndsAt = character:GetAttribute(Attributes.DodgeIFrameEndsAt)
    local dodgeGlow = entry.Tagged and state == CombatStates.Dodging
        and type(iframeEndsAt) == "number" and now < iframeEndsAt
        and Config.DodgeInvulnerability or nil
    if entry.Tagged then
        baseColor = state == CombatStates.Attacking and Config.AttackPhases[phase] or Config.States[state]
    end

    if dodgeGlow then baseColor = dodgeGlow.Color end

    local reaction = entry.Reaction
    local weight = 0
    if reaction then
        local remaining = (reaction.EndsAt - now) / reaction.Settings.Duration
        if remaining <= 0 then
            entry.Reaction = nil
        else
            weight = math.clamp(remaining, 0, 1)
        end
    end

    if not baseColor and weight == 0 then
        ClearHighlight(entry)
        return
    end
    local color = baseColor
    if weight > 0 then
        color = baseColor and baseColor:Lerp(reaction.Settings.Color, weight) or reaction.Settings.Color
    end

    if not entry.Highlight and highlightCount < Config.MaxHighlights then
        local highlight = Instance.new("Highlight")
        highlight.Name = "CombatStateVFX"
        highlight.Adornee = character
        highlight.DepthMode = Enum.HighlightDepthMode.Occluded
        highlight.Parent = folder
        entry.Highlight = highlight
        highlightCount += 1
    end

    local highlight = entry.Highlight
    if highlight then
        local blend = 1 - math.exp(-deltaTime / Config.ColorBlendTime)
        entry.Color = entry.Color and entry.Color:Lerp(color, blend) or color
        highlight.FillColor = entry.Color
        highlight.OutlineColor = entry.Color
        local fill = dodgeGlow and dodgeGlow.FillTransparency or (baseColor and Config.HighlightFillTransparency or 1)
        local outline = dodgeGlow and dodgeGlow.OutlineTransparency or (baseColor and Config.HighlightOutlineTransparency or 1)
        highlight.FillTransparency = fill + (Config.ReactionFillTransparency - fill) * weight
        highlight.OutlineTransparency = outline + (Config.ReactionOutlineTransparency - outline) * weight
    end
end

local function FindHandle(character, weaponId)
    for _, child in ipairs(character:GetChildren()) do
        if child:IsA("Tool") and child:GetAttribute(CombatConfig.WeaponAttribute) == weaponId then
            local handle = child:FindFirstChild("Handle")
            if handle and handle:IsA("BasePart") then
                return handle
            end
        end
    end
end

local function CreateTrail(entry, handle, attackId)
    if trailCount >= Config.MaxTrails then
        return
    end

    -- Temporary swords and custom models may use different blade axes.
    local size = handle.Size
    local axis = Vector3.new(0, 1, 0)
    local length = size.Y
    if size.Z > length then
        axis, length = Vector3.new(0, 0, 1), size.Z
    end
    if size.X > length then
        axis, length = Vector3.new(1, 0, 0), size.X
    end

    local start = Instance.new("Attachment")
    start.Name = "CombatTrailStart"
    start.Position = axis * length * -0.45
    start.Parent = handle
    local finish = Instance.new("Attachment")
    finish.Name = "CombatTrailFinish"
    finish.Position = axis * length * 0.45
    finish.Parent = handle

    local trail = Instance.new("Trail")
    trail.Name = "CombatAttackTrail"
    trail.Attachment0 = start
    trail.Attachment1 = finish
    trail.Color = ColorSequence.new(Config.Trail.Color)
    trail.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, Config.Trail.Transparency),
        NumberSequenceKeypoint.new(1, 1),
    })
    trail.WidthScale = NumberSequence.new(Config.Trail.Width)
    trail.Lifetime = Config.Trail.Lifetime
    trail.MinLength = 0.02
    trail.FaceCamera = true
    trail.LightEmission = 0.15
    trail.Enabled = true
    trail.Parent = handle

    entry.TrailResources = {
        Trail = trail, Start = start, Finish = finish,
        Handle = handle, AttackId = attackId,
    }
    trailCount += 1
end

local function UpdateCharacter(character, entry, now, deltaTime)
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local ownCharacter = character == Players.LocalPlayer.Character
    local predicted = ownCharacter and humanoid and humanoid:GetAttribute(DashConfig.PredictionAttribute)
    if not predicted and not entry.Tagged and (not entry.Reaction or now >= entry.Reaction.EndsAt) then
        RemoveCharacter(character)
        return
    end
    local root = character:FindFirstChild("HumanoidRootPart")
    if not character.Parent or not root or not humanoid or humanoid.Health <= 0 or not IsNear(root.Position) then
        ClearHighlight(entry)
        ClearTrail(entry)
        dust:Forget(character)
        return
    end

    local state = character:GetAttribute(Attributes.State)
    local phase = character:GetAttribute(Attributes.Phase)
    local dashEndsAt = character:GetAttribute(Attributes.DodgeEndsAt)
    local dashing = predicted or (not ownCharacter and entry.Tagged and state == CombatStates.Dodging
        and type(dashEndsAt) == "number" and now < dashEndsAt)
    dust:Step(character, root, humanoid, dashing, deltaTime)
    UpdateHighlight(character, entry, state, phase, now, deltaTime)

    local attackId = character:GetAttribute(Attributes.AttackId)
    local endsAt = character:GetAttribute(Attributes.ActiveEndsAt)
    local weaponId = character:GetAttribute(Attributes.WeaponId)
    local handle
    if entry.Tagged and state == CombatStates.Attacking and phase == CombatStates.AttackPhases.Active
        and type(attackId) == "number" and type(endsAt) == "number" and now < endsAt
    then
        handle = FindHandle(character, weaponId)
    end
    local resources = entry.TrailResources
    if resources and (not handle or resources.Handle ~= handle or resources.AttackId ~= attackId) then
        ClearTrail(entry)
    end
    if handle and not entry.TrailResources then
        CreateTrail(entry, handle, attackId)
    end
end

local function playBreakBurst(root, color)
    local tweenService = game:GetService("TweenService")
    local origin = root.Position
    local info = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    -- An expanding circle of bright guard fragments on the horizontal plane.
    for i = 1, 12 do
        local angle = (i - 1) * math.pi / 6
        local radial = Vector3.new(math.cos(angle), 0, math.sin(angle))
        local shard = Instance.new("Part")
        shard.Name = "PostureBreakFragment"
        shard.Anchored = true
        shard.CanCollide, shard.CanQuery, shard.CanTouch = false, false, false
        shard.Material = Enum.Material.Neon
        shard.Color = i % 2 == 0 and color or Color3.new(1, 1, 1)
        shard.Size = Vector3.new(0.65, 0.12, 0.12)
        shard.CFrame = CFrame.lookAt(origin + radial, origin)
        shard.Parent = folder
        tweenService:Create(shard, info, {
            Position = origin + radial * 3 + Vector3.new(0, i % 3 * 0.2, 0), Transparency = 1,
        }):Play()
        Debris:AddItem(shard, 0.35)
    end
end

local function PlayReaction(payload)
    if type(payload) ~= "table" or typeof(payload.Target) ~= "Instance"
        or not payload.Target:IsA("Model") or not payload.Target.Parent
        or type(payload.ServerTime) ~= "number"
        or workspace:GetServerTimeNow() - payload.ServerTime > Config.MaxImpactAge
    then
        return
    end
    local character = payload.Target
    local root = character:FindFirstChild("HumanoidRootPart")
    local settings = Config.Reactions[payload.Result]
    if not root or not settings or not IsNear(root.Position) then
        return
    end

    if payload.Result == "PostureBreak" then playBreakBurst(root, settings.Color) end

    -- A reaction can arrive before the replicated state tag, or survive its removal.
    local entry = entries[character]
    if not entry then
        entry = { Tagged = CollectionService:HasTag(character, Config.ActorTag) }
        entries[character] = entry
    end
    local current = entry.Reaction
    if current and current.EndsAt > workspace:GetServerTimeNow()
        and current.Settings.Priority > settings.Priority
    then
        return
    end
    entry.Reaction = {
        Settings = settings,
        EndsAt = workspace:GetServerTimeNow() + settings.Duration,
    }
end

table.insert(connections, CollectionService:GetInstanceAddedSignal(Config.ActorTag):Connect(AddCharacter))
table.insert(connections, CollectionService:GetInstanceRemovedSignal(Config.ActorTag):Connect(UntagCharacter))
for _, character in ipairs(CollectionService:GetTagged(Config.ActorTag)) do
    AddCharacter(character)
end
table.insert(connections, event.OnClientEvent:Connect(PlayReaction))
table.insert(connections, RunService.Heartbeat:Connect(function(deltaTime)
    local now = workspace:GetServerTimeNow()
    local character = Players.LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid:GetAttribute(DashConfig.PredictionAttribute) and not entries[character] then
        entries[character] = { Tagged = CollectionService:HasTag(character, Config.ActorTag) }
    end
    dust:Update(deltaTime)
    for character, entry in pairs(entries) do
        UpdateCharacter(character, entry, now, deltaTime)
    end
end))

script.Destroying:Connect(function()
    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
    for character in pairs(entries) do
        RemoveCharacter(character)
    end
    dust:Destroy()
    folder:Destroy()
end)
