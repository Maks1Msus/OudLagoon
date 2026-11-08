local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConstants = require(
    ReplicatedStorage.Shared.Constants.GameConstants
)

local CharacterService = {}

-- Максимум маны считается из очков характеристики Mana.
local function CalculateMaxMana(stats)
    local manaStat = stats.Mana or GameConstants.BaseStatValue

    return math.max(1, manaStat * GameConstants.ManaPerPoint)
end

local function CalculateMaxHealth(stats)
    local vitality = stats.Vitality or GameConstants.BaseStatValue

    return math.max(
        1,
        GameConstants.DefaultHealth
            + (vitality - GameConstants.BaseStatValue)
                * GameConstants.HealthPerVitality
    )
end

local function CalculateWalkSpeed(stats)
    local agility = stats.Agility or GameConstants.BaseStatValue

    return math.clamp(
        GameConstants.DefaultWalkSpeed
            + (agility - GameConstants.BaseStatValue)
                * GameConstants.SpeedPerAgility,
        GameConstants.MinWalkSpeed,
        GameConstants.MaxWalkSpeed
    )
end

-- Атрибуты на Player: сервер -> клиент, только для отображения.
-- Источник истины - профиль в DataService. Изменения атрибутов на клиенте
-- на сервер не передаются, но читать их для логики на сервере всё равно не стоит.
--
-- В профиле Stats.Mana - это ОЧКИ характеристики. Максимум маны в атрибуте MaxMana,
-- а атрибут Mana - это текущее значение.
-- Не лечит и не восстанавливает ману (кроме ограничения текущей маны сверху).
function CharacterService:RefreshAttributes(player, profile)
    local stats = profile.Stats

    for statName, value in pairs(stats) do
        if statName ~= "Mana" then
            player:SetAttribute(statName, value)
        end
    end

    local maxMana = CalculateMaxMana(stats)

    player:SetAttribute("MaxMana", maxMana)

    local currentMana = player:GetAttribute("Mana")

    if currentMana == nil or currentMana > maxMana then
        player:SetAttribute("Mana", maxMana)
    end

    player:SetAttribute("Level", profile.Level)
    player:SetAttribute("Experience", profile.Experience)
    player:SetAttribute("StatPoints", profile.StatPoints)
end

-- Пересчитывает здоровье, скорость и атрибуты по текущим характеристикам.
-- НЕ восстанавливает здоровье и ману, поэтому безопасно вызывать посреди боя
-- (например, при вложении очка характеристики).
function CharacterService:UpdateDerivedStats(player, humanoid, profile)
    local stats = profile.Stats

    humanoid.MaxHealth = CalculateMaxHealth(stats)
    humanoid.WalkSpeed = CalculateWalkSpeed(stats)

    self:RefreshAttributes(player, profile)
end

-- Вызывается при каждом появлении персонажа (в том числе после смерти).
-- Здесь здоровье и мана восстанавливаются полностью.
function CharacterService:ApplyStats(player, character, profile)
    local humanoid = character:WaitForChild("Humanoid", 10)

    if not humanoid then
        warn("[CharacterService] Humanoid not found:", player.Name)
        return
    end

    -- Пока мы ждали, персонаж мог быть удалён
    if character.Parent == nil then
        return
    end

    self:UpdateDerivedStats(player, humanoid, profile)

    humanoid.Health = humanoid.MaxHealth
    player:SetAttribute("Mana", player:GetAttribute("MaxMana"))

    print("[CharacterService] Stats applied:", player.Name)
end

-- Базовые операции с маной (пригодятся будущему MagicService).
-- Возвращает true, если маны хватило и она списана.
function CharacterService:SpendMana(player, amount)
    local mana = player:GetAttribute("Mana") or 0

    if type(amount) ~= "number" or amount <= 0 or mana < amount then
        return false
    end

    player:SetAttribute("Mana", mana - amount)

    return true
end

-- amount = nil восстанавливает ману полностью.
function CharacterService:RestoreMana(player, amount)
    local maxMana = player:GetAttribute("MaxMana")
        or (GameConstants.BaseStatValue * GameConstants.ManaPerPoint)
    local mana = player:GetAttribute("Mana") or 0

    if amount == nil then
        mana = maxMana
    else
        mana = math.min(maxMana, mana + amount)
    end

    player:SetAttribute("Mana", mana)
end

return CharacterService