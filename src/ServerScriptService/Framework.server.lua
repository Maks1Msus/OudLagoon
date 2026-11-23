local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Services = script.Parent.Services
local TrainingDummyService = require(Services.TrainingDummyService)
local DataService = require(Services.DataService)
local RemoteService = require(Services.RemoteService)
local PlayerService = require(Services.PlayerService)
local DebugService = require(Services.DebugService)
local ProgressionService = require(
    Services.ProgressionService
)
local CombatStateService = require(Services.CombatStateService)
local PostureService = require(Services.PostureService)
local RagdollService = require(Services.RagdollService)
local CombatMovementService = require(Services.CombatMovementService)
local DashService = require(Services.DashService)
local SwordPickupService = require(Services.SwordPickupService)
local ComboService = require(Services.ComboService)
local CombatService = require(Services.CombatService)
local CombatSFXService = require(Services.CombatSFXService)
local CombatVFXService = require(Services.CombatVFXService)
local NPCCombatAnimationService = require(Services.NPCCombatAnimationService)
local EnemyService = require(Services.EnemyService)

local GameConfig = require(
    ReplicatedStorage.Shared.Config.GameConfig
)

-- Порядок важен: сначала Remotes, затем сервисы, которые на них подписываются.
RemoteService:Init()
PlayerService:Init()
ProgressionService:Init()

CombatStateService:Init()
PostureService:Init()
CombatMovementService:Init()
RagdollService:Init()
DashService:Init()
ComboService:Init()
CombatService:Init()
CombatVFXService:Init()
CombatSFXService:Init()
SwordPickupService:Init()

NPCCombatAnimationService:Init()
EnemyService:Init()
TrainingDummyService:Init()
DebugService:Init()

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
