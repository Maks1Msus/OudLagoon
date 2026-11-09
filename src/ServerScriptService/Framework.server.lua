local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Services = script.Parent.Services

local DataService = require(Services.DataService)
local RemoteService = require(Services.RemoteService)
local PlayerService = require(Services.PlayerService)
local DebugService = require(Services.DebugService)
local ProgressionService = require(
    Services.ProgressionService
)
local CombatService = require(Services.CombatService)

local GameConfig = require(
    ReplicatedStorage.Shared.Config.GameConfig
)

-- Порядок важен: сначала Remotes, затем сервисы, которые на них подписываются.
RemoteService:Init()
PlayerService:Init()
ProgressionService:Init()
CombatService:Init()
DebugService:Init() -- активен только в Roblox Studio

print("================================")
print(" ReZero MMORPG Core Framework ")
print(" Framework initialized!")
print("================================")

-- Автосохранение (заодно обновляет блокировки сессий)
task.spawn(function()
    while true do
        task.wait(GameConfig.AutoSaveInterval)

        DataService:SaveAll()
    end
end)

-- Сохранение при закрытии сервера: параллельно и со снятием блокировок,
-- чтобы игроки могли сразу зайти на другой сервер.
game:BindToClose(function()
    print("[Framework] Server shutting down. Saving profiles...")

    DataService:SaveAll(true)

    print("[Framework] Shutdown save completed")
end)