local ProgressionConfig = require(script.Parent.ProgressionConfig)

local GameConfig = {}

-- ДАННЫЕ ---------------------------------------------------------------

GameConfig.DataStoreName = "ReZeroMMORPG_PlayerData_v1"

-- Версия 2: Stats.Mana теперь хранит очки характеристики (старт 10),
-- а не максимум маны (раньше старт 100). См. Migrations в DataService.
GameConfig.DataVersion = 2

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
    Strength = 10,
    Vitality = 10,
    Agility = 10,
    Intelligence = 10,
    Mana = 10, -- очки характеристики; максимум маны = Mana * GameConstants.ManaPerPoint
    Spirit = 10,
}

GameConfig.StartingResources = {
    Gold = 0,
}

return GameConfig