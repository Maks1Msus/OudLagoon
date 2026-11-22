local ProgressionConfig = require(script.Parent.ProgressionConfig)

local GameConfig = {}

-- ДАННЫЕ ---------------------------------------------------------------

GameConfig.DataStoreName = "ReZeroMMORPG_PlayerData_v1"

GameConfig.DataVersion = 3

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
-- Уровень, опыт и очки берутся из ProgressionConfig (единый источник правил).

GameConfig.StartingLevel = ProgressionConfig.StartingLevel
GameConfig.StartingExperience = ProgressionConfig.StartingExperience
GameConfig.StartingStatPoints = ProgressionConfig.StartingStatPoints

GameConfig.StartingStats = {
    Attributes = ProgressionConfig.StartingAttributes,
}

GameConfig.StartingProficiencies = { Sword = 0, Unarmed = 0, Magic = 0 }
GameConfig.StartingMagic = { ManaCapacity = 100, Affinities = {} }

GameConfig.StartingResources = {
    Gold = 0,
}

return GameConfig
