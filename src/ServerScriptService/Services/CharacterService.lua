local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConstants = require(
    ReplicatedStorage.Shared.Constants.GameConstants
)

local CharacterService = {}

-- Атрибуты на Player: сервер -> клиент, только для отображения.
-- Источник истины - профиль в DataService. Изменения атрибутов на клиенте
-- на сервер не передаются, но читать их для логики на сервере всё равно не стоит.
--
-- В профиле Stats.Mana - это МАКСИМУМ маны. Чтобы не путать его с текущей маной,
-- в атрибутах он называется MaxMana, а Mana - это текущее значение.
function CharacterService:RefreshAttributes(player, profile)
    local stats = profile.Stats

    for statName, value in pairs(stats) do
        if statName ~= "Mana" then
            player:SetAttribute(statName, value)
        end
    end

    local maxMana = stats.Mana or GameConstants.MaxMana

    player:SetAttribute("MaxMana", maxMana)

    local currentMana = player:GetAttribute("Mana")

    if currentMana == nil or currentMana > maxMana then
        player:SetAttribute("Mana", maxMana)
    end

    player:SetAttribute("Level", profile.Level)
    player:SetAttribute("Experience", profile.Experience)
end

-- Вызывается при каждом появлении персонажа (в том числе после смерти).
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

    local stats = profile.Stats

    -- Здоровье
    local vitality = stats.Vitality or 10

    local maxHealth = math.max(
        1,
        GameConstants.DefaultHealth
            + (vitality - 10) * 5
    )

    humanoid.MaxHealth = maxHealth
    humanoid.Health = maxHealth

    -- Скорость
    local agility = stats.Agility or 10

    humanoid.WalkSpeed = math.clamp(
        GameConstants.DefaultWalkSpeed
            + (agility - 10) * 0.1,
        8,
        30
    )

    -- Атрибуты и мана (при возрождении мана восстанавливается полностью)
    self:RefreshAttributes(player, profile)
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
    local maxMana = player:GetAttribute("MaxMana") or GameConstants.MaxMana
    local mana = player:GetAttribute("Mana") or 0

    if amount == nil then
        mana = maxMana
    else
        mana = math.min(maxMana, mana + amount)
    end

    player:SetAttribute("Mana", mana)
end

return CharacterService