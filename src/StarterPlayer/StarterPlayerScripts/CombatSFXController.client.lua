local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config.CombatSFXConfig)
local Players = game:GetService("Players")
local Client = require(Shared.Combat.CombatSFXClient)
Config.Validate()
if not Config.Enabled then return end
Client:Init()
local event = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Events"):WaitForChild("CombatSFX")
local lastId = 0
local connections = {}

table.insert(connections, event.OnClientEvent:Connect(function(payload)
    if type(payload) ~= "table" or typeof(payload.Character) ~= "Instance"
        or not payload.Character:IsA("Model") or type(payload.Key) ~= "string" then return end
    local id, time = payload.Id, payload.ServerTime
    local now = workspace:GetServerTimeNow()
    if type(id) ~= "number" or id ~= id or id == math.huge or id % 1 ~= 0 or id <= lastId
        or type(time) ~= "number" or time ~= time or time > now + 0.5 or now - time > Config.MaxAge then return end
    lastId = id
    Client:Receive(payload)
end))
table.insert(connections, RunService.Heartbeat:Connect(function() Client:Update() end))
table.insert(connections, Players.LocalPlayer.CharacterAdded:Connect(function() Client:Reset() end))
script.Destroying:Connect(function()
    for _, connection in ipairs(connections) do connection:Disconnect() end
    Client:Destroy()
end)
