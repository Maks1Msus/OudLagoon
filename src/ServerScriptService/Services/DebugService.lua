local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local TrainingDummyService = require(script.Parent.TrainingDummyService)
local WeaponService = require(script.Parent.WeaponService)
local CombatService = require(script.Parent.CombatService)
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

-- Очки характеристик для быстрой проверки влияния Strength на урон.
function Actions.AddStatPoints(player, profile, amount)
    profile.StatPoints += math.floor(amount or 50)

    CharacterService:RefreshAttributes(player, profile)
    PlayerService:PushProfile(player)
end

-- Тестовый меч. Предмет создаёт WeaponService: оружие распознаётся по атрибуту
-- CombatWeaponId, который ставит сервер.
function Actions.GiveSword(player)
    WeaponService:Give(player, "Sword")
end

-- Убирает всё выданное оружие, в том числе из рук: бой без оружия.
function Actions.RemoveWeapons(player)
    WeaponService:RemoveAll(player)
end

-- Неподвижный манекен с обычным Humanoid в 7 studs перед игроком.
function Actions.SpawnDummy(player)
    TrainingDummyService:SpawnForPlayer(player, "Passive")
end

-- Манекен, который периодически поднимает блок (проверка блока и парирования).
function Actions.SpawnLowPostureDummy(player)
    TrainingDummyService:SpawnForPlayer(player, "LowPosture")
end

function Actions.SpawnBlockingDummy(player)
    TrainingDummyService:SpawnForPlayer(player, "Blocking")
end

-- Манекен, который сам атакует игрока, подошедшего на дистанцию удара.
function Actions.SpawnHeavyDummy(player)
    TrainingDummyService:SpawnForPlayer(player, "HeavyTest")
end

function Actions.SpawnAggressiveDummy(player)
    TrainingDummyService:SpawnForPlayer(player, "Aggressive")
end

-- Оглушение способностью: проверка явного события Stunned у игрока и у манекенов.
function Actions.StunSelf(player)
    if player.Character then
        CombatService:ApplyAbilityStun(player.Character)
    end
end

function Actions.StunDummies()
    TrainingDummyService:StunAll()
end

function Actions.RemoveDummy()
    TrainingDummyService:RemoveLast()
end

function Actions.RemoveAllDummies()
    TrainingDummyService:RemoveAll()
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