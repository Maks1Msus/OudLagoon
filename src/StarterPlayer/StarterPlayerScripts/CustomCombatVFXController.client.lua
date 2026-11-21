local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config.CustomCombatVFXConfig)
local StateConfig = require(Shared.Config.CombatVFXConfig)
local States = require(Shared.Constants.CombatStates)
local Renderer = require(Shared.Combat.CustomCombatVFX)
if not Config.Enabled or not StateConfig.Enabled then return end

local folder = Instance.new("Folder")
folder.Name = "LocalCustomCombatVFX"
folder.Parent = workspace
local renderer = Renderer.new(folder, Config)
local event = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Events"):WaitForChild("CombatVFX")
local impacts = setmetatable({}, { __mode = "k" })
local blocks = {}
local connections = {}

table.insert(connections, event.OnClientEvent:Connect(function(payload)
    if type(payload) ~= "table" or typeof(payload.Target) ~= "Instance"
        or not payload.Target:IsA("Model") or not payload.Target.Parent then return end
    local character = payload.Target
    if payload.Kind == "CustomAction" and payload.Action == "StopDash" then
        renderer:Stop(character, "Dash")
        return
    end
    local time = payload.ServerTime
    local now = workspace:GetServerTimeNow()
    if type(time) ~= "number" or time ~= time or time > now + 0.5 or now - time > Config.MaxAge then return end
    local age = math.max(0, now - time)
    if payload.Kind == "CustomAction" then
        if payload.Action == "Dash" then
            renderer:Play(character, "Dash", payload.Duration, "Dash", age, { Direction = payload.Direction })
        end
    elseif payload.Result == States.DamageResults.Hit then
        local moves = Config.Attacks[payload.WeaponId]
        local key = moves and moves[payload.MoveId]
        local attacker = payload.Attacker
        if not key or typeof(attacker) ~= "Instance" or not attacker:IsA("Model")
            or type(payload.AttackId) ~= "number" then return end
        local seen = impacts[character]
        if not seen then seen = setmetatable({}, { __mode = "k" }); impacts[character] = seen end
        if seen[attacker] == payload.AttackId then return end
        seen[attacker] = payload.AttackId
        renderer:Play(character, key, nil, "Hit")
    elseif payload.Result == States.DamageResults.Parried then
        renderer:Play(character, "Parry", nil, "Parry")
    end
end))

table.insert(connections, RunService.RenderStepped:Connect(function()
    local visible = {}
    for _, character in ipairs(CollectionService:GetTagged(StateConfig.ActorTag)) do
        if character:GetAttribute(StateConfig.Attributes.State) == States.Blocking and renderer:Near(character) then
            visible[character] = true
            blocks[character] = true
            if not renderer:Has(character, "Block") then renderer:Play(character, "Block", nil, "Block") end
        end
    end
    for character in pairs(blocks) do
        if not visible[character] then
            renderer:Stop(character, "Block")
            blocks[character] = nil
        end
    end
    renderer:Update()
end))

script.Destroying:Connect(function()
    for _, connection in ipairs(connections) do connection:Disconnect() end
    renderer:Destroy()
    folder:Destroy()
end)
