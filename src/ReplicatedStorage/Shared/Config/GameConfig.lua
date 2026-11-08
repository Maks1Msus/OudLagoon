local GameConfig = {}

-- ДАННЫЕ ---------------------------------------------------------------

GameConfig.DataStoreName = "ReZeroMMORPG_PlayerData_v1"
GameConfig.DataVersion = 1

GameConfig.AutoSaveInterval = 60

GameConfig.LoadAttempts = 5          -- сколько раз пробуем загрузить профиль
GameConfig.LoadRetryDelay = 3        -- пауза между попытками (сек)
GameConfig.SaveAttempts = 3          -- сколько раз пробуем сохранить профиль

-- Через сколько секунд блокировка сессии чужого сервера считается "мёртвой"
-- (например, если тот сервер упал). Блокировка обновляется при каждом автосохранении.
GameConfig.SessionLockTimeout = 300

-- REMOTES --------------------------------------------------------------

-- Лимит вызовов одного RemoteEvent от одного игрока в секунду по умолчанию
GameConfig.DefaultRemoteRateLimit = 20

-- СТАРТОВЫЕ ЗНАЧЕНИЯ ---------------------------------------------------

GameConfig.StartingLevel = 1
GameConfig.StartingExperience = 0
GameConfig.StartingStatPoints = 0
GameConfig.StartingStats = {
    Strength = 10,
    Vitality = 10,
    Agility = 10,
    Intelligence = 10,
    Mana = 100, -- максимальный запас маны (текущая мана хранится отдельно)
    Spirit = 10,
}

GameConfig.StartingResources = {
    Gold = 0,
}

return GameConfig