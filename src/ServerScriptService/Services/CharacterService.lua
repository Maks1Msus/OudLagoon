local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StatRules = require(ReplicatedStorage.Shared.Progression.StatRules)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local GameConstants = require(ReplicatedStorage.Shared.Constants.GameConstants)

local PostureService = require(script.Parent.PostureService)
local CombatMovementService = require(script.Parent.CombatMovementService)

local CharacterService = {}

-- Атрибуты на Player: сервер -> клиент, только для отображения.
-- Источник истины - профиль в DataService. Изменения атрибутов на клиенте
-- на сервер не передаются, но читать их для логики на сервере всё равно не стоит.
--
function CharacterService:RefreshAttributes(player, profile)
    local attributes = profile.Stats.Attributes

    for name, value in pairs(attributes) do
        player:SetAttribute(name, value)
    end

    local maxMana = profile.Magic.ManaCapacity

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
    humanoid.MaxHealth = StatRules.GetMaxHealth(profile.Stats.Attributes.Vitality)
    humanoid.Health = math.min(humanoid.Health, humanoid.MaxHealth)

    local endurance = profile.Stats.Attributes.Endurance
    PostureService:Configure(humanoid.Parent, StatRules.GetMaxPosture(endurance), StatRules.GetPostureRecovery(endurance))
    self:RefreshAttributes(player, profile)
end

-- Вызывается при каждом появлении персонажа (в том числе после смерти).
-- Здесь здоровье и мана восстанавливаются полностью.
function CharacterService:ApplyStats(player, character, profile)
    local deadline = os.clock() + 10
    local humanoid = character:WaitForChild("Humanoid", 10)

    if not humanoid then
        warn("[CharacterService] Humanoid not found:", player.Name)
        return
    end

    -- CharacterAdded can fire before Roblox parents the new character.
    while character.Parent == nil and player.Character == character and os.clock() < deadline do
        task.wait()
    end
    if character.Parent == nil or player.Character ~= character then
        return
    end

    self:UpdateDerivedStats(player, humanoid, profile)
    CombatMovementService:SetBaseWalkSpeed(humanoid, GameConstants.DefaultWalkSpeed)

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
        or GameConfig.StartingMagic.ManaCapacity
    local mana = player:GetAttribute("Mana") or 0

    if amount == nil then
        mana = maxMana
    else
        mana = math.min(maxMana, mana + amount)
    end

    player:SetAttribute("Mana", mana)
end

return CharacterService
