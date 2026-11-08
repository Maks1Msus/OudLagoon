local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(
    ReplicatedStorage.Shared.Config.GameConfig
)

local DataService = {}

local PlayerStore = DataStoreService:GetDataStore(
    GameConfig.DataStoreName
)

local JOB_ID = game.JobId

-- Все таблицы ниже индексируются по UserId
local Profiles = {}  -- загруженные профили (без служебного поля SessionLock)
local Loading = {}   -- идёт загрузка
local Saving = {}    -- идёт сохранение (защита от одновременных записей)
local Releasing = {} -- идёт финальное сохранение после выхода игрока

-- УТИЛИТЫ ---------------------------------------------------------------

local function DeepCopy(original)
    local copy = {}

    for key, value in pairs(original) do
        if type(value) == "table" then
            copy[key] = DeepCopy(value)
        else
            copy[key] = value
        end
    end

    return copy
end

-- Рекурсивно добавляет в target поля, которых там нет, но есть в template.
-- Нужно, чтобы старые сохранения получали новые поля (в том числе вложенные).
local function Reconcile(target, template)
    for key, value in pairs(template) do
        if target[key] == nil then
            if type(value) == "table" then
                target[key] = DeepCopy(value)
            else
                target[key] = value
            end
        elseif type(value) == "table" and type(target[key]) == "table" then
            Reconcile(target[key], value)
        end
    end
end
local function MergeDefaults(data, defaults)
    for key, defaultValue in pairs(defaults) do
        if data[key] == nil then
            data[key] = DeepCopy(defaultValue)
        elseif type(data[key]) == "table"
            and type(defaultValue) == "table" then

            MergeDefaults(data[key], defaultValue)
        end
    end

    return data
end
local function KeyFor(userId)
    return "Player_" .. userId
end

local function CreateDefaultData()
    return {
        Version = GameConfig.DataVersion,
        StatPoints = GameConfig.StartingStatPoints or 0,
        Level = GameConfig.StartingLevel,
        Experience = GameConfig.StartingExperience,

        Stats = DeepCopy(GameConfig.StartingStats),

        Resources = DeepCopy(GameConfig.StartingResources),

        Abilities = {},

        SpiritualProfile = {
            Directions = {},
            ActiveDirections = {},
            DominantDirection = nil,
            CompletedTrials = {},
            SpiritualCombinations = {},
        },

        Inventory = {},

        Quests = {},

        Settings = {},
    }
end

-- МИГРАЦИИ --------------------------------------------------------------
-- Migrations[N] переводит данные с версии N на версию N + 1.
-- Пример:
-- Migrations[1] = function(data)
--     data.Resources.Silver = 0
-- end
local Migrations = {}

local function Migrate(data)
    local version = data.Version or 1

    while version < GameConfig.DataVersion do
        local migrate = Migrations[version]

        if migrate then
            migrate(data)
        end

        version += 1
    end

    data.Version = GameConfig.DataVersion
end

-- БЛОКИРОВКА СЕССИИ -----------------------------------------------------
-- Не даёт двум серверам одновременно владеть одним профилем
-- (иначе возможны потеря прогресса и дублирование предметов).

local function IsLockedByOtherServer(data)
    local lock = data.SessionLock

    if type(lock) ~= "table" then
        return false
    end

    if lock.JobId == JOB_ID then
        return false
    end

    return (os.time() - (lock.Time or 0)) < GameConfig.SessionLockTimeout
end

-- ЗАГРУЗКА --------------------------------------------------------------

-- Возвращает profile или nil, reason.
-- reason: "AlreadyLoading" | "PlayerLeft" | "Locked" | "Corrupt" | "DataStoreError"
function DataService:LoadProfile(player)
    local userId = player.UserId

    -- Если игрок только что вышел и идёт финальное сохранение - дожидаемся его,
    -- чтобы не загрузить устаревшие данные.
    while Releasing[userId] do
        task.wait()
    end

    if Profiles[userId] then
        return Profiles[userId]
    end

    if Loading[userId] then
        return nil, "AlreadyLoading"
    end

    Loading[userId] = true

    local key = KeyFor(userId)
    local loaded = nil
    local failReason = "DataStoreError"

    for attempt = 1, GameConfig.LoadAttempts do
        if player.Parent ~= Players then
            failReason = "PlayerLeft"
            break
        end

        local claimed = nil
        local status = nil

        -- UpdateAsync атомарно читает данные и ставит блокировку сессии.
        -- Функция-обработчик может вызываться несколько раз, поэтому
        -- состояние сбрасывается в начале каждого вызова.
        local ok, err = pcall(function()
            PlayerStore:UpdateAsync(key, function(old)
                claimed = nil
                status = nil

                if old == nil then
                    status = "new"
                    claimed = CreateDefaultData()
                elseif type(old) ~= "table" then
                    status = "corrupt"
                    return nil
                elseif IsLockedByOtherServer(old) then
                    status = "locked"
                    return nil
                else
                    status = "ok"
                    claimed = old
                end

                local toStore = DeepCopy(claimed)
                toStore.SessionLock = {
                    JobId = JOB_ID,
                    Time = os.time(),
                }

                return toStore
            end)
        end)

        if not ok then
            failReason = "DataStoreError"

            warn(
                "[DataService] Load attempt",
                attempt,
                "failed for",
                player.Name,
                err
            )
        elseif status == "corrupt" then
            -- Не перезаписываем неизвестные данные и не повторяем попытки.
            failReason = "Corrupt"
            break
        elseif status == "locked" then
            failReason = "Locked"

            warn(
                "[DataService] Profile is locked by another server:",
                player.Name
            )
        elseif claimed then
            loaded = claimed
            break
        end

        if attempt < GameConfig.LoadAttempts then
            task.wait(GameConfig.LoadRetryDelay)
        end
    end

    Loading[userId] = nil

    if not loaded then
        return nil, failReason
    end

    loaded.SessionLock = nil

    Migrate(loaded)
    Reconcile(loaded, CreateDefaultData())

    Profiles[userId] = loaded

    print("[DataService] Profile loaded:", player.Name)

    return loaded
end

function DataService:GetProfile(player)
    return Profiles[player.UserId]
end

-- СОХРАНЕНИЕ ------------------------------------------------------------

-- releaseLock = true снимает блокировку сессии (финальное сохранение).
local function SaveByUserId(userId, releaseLock)
    -- Не пишем в один ключ из нескольких потоков одновременно
    while Saving[userId] do
        task.wait()
    end

    local profile = Profiles[userId]

    if not profile then
        return true
    end

    Saving[userId] = true

    local key = KeyFor(userId)
    local snapshot = DeepCopy(profile)
    local sessionLost = false
    local success = false

    for attempt = 1, GameConfig.SaveAttempts do
        local ok, err = pcall(function()
            PlayerStore:UpdateAsync(key, function(old)
                sessionLost = false

                -- Если профиль захватил другой сервер, не затираем его данные.
                if type(old) == "table" and IsLockedByOtherServer(old) then
                    sessionLost = true
                    return nil
                end

                if releaseLock then
                    snapshot.SessionLock = nil
                else
                    snapshot.SessionLock = {
                        JobId = JOB_ID,
                        Time = os.time(),
                    }
                end

                return snapshot
            end)
        end)

        if ok and not sessionLost then
            success = true
            break
        end

        if sessionLost then
            warn("[DataService] Session lost for UserId", userId)
            break
        end

        warn(
            "[DataService] Save attempt",
            attempt,
            "failed for UserId",
            userId,
            err
        )

        if attempt < GameConfig.SaveAttempts then
            task.wait(attempt * 2)
        end
    end

    Saving[userId] = nil

    if sessionLost then
        Profiles[userId] = nil

        local player = Players:GetPlayerByUserId(userId)

        if player then
            player:Kick("Your session was opened on another server.")
        end

        return false
    end

    return success
end

function DataService:SaveProfile(player)
    return SaveByUserId(player.UserId, false)
end

function DataService:ReleaseProfile(player)
    local userId = player.UserId

    if not Profiles[userId] then
        return
    end

    Releasing[userId] = true

    local success = SaveByUserId(userId, true)

    if success then
        Profiles[userId] = nil
    else
        warn(
            "[DataService] Profile retained in memory after save failure:",
            player.Name,
            "(autosave will retry)"
        )
    end

    Releasing[userId] = nil
end

-- Сохраняет все профили параллельно (важно для BindToClose: у сервера всего ~30 сек).
-- Профили вышедших игроков освобождаются. releaseLocks = true освобождает всех.
function DataService:SaveAll(releaseLocks)
    local userIds = {}

    for userId in pairs(Profiles) do
        table.insert(userIds, userId)
    end

    local pending = #userIds

    for _, userId in ipairs(userIds) do
        task.spawn(function()
            local playerPresent = Players:GetPlayerByUserId(userId) ~= nil
            local release = (releaseLocks == true) or not playerPresent

            local ok, result = pcall(SaveByUserId, userId, release)

            if ok and result and release then
                Profiles[userId] = nil
            elseif not ok then
                warn("[DataService] SaveAll error for UserId", userId, result)
            end

            pending -= 1
        end)
    end

    while pending > 0 do
        task.wait()
    end
end

return DataService