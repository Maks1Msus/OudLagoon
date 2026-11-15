-- WeaponService: выдача, экипировка и снятие оружия (серверная часть).
-- Оружие игрока - Tool с атрибутом CombatWeaponId. Атрибут ставит только сервер:
-- клиент не может создать Tool или изменить атрибут так, чтобы это увидел сервер.
-- Характеристики берутся из CombatConfig.Weapons через WeaponRegistry; боевую логику
-- (удары, урон, состояния) сервис не знает и не трогает.
--
-- Встроенная панель предметов Roblox по-прежнему позволяет игроку самому брать Tool из
-- рюкзака и убирать обратно. Это безопасно: сервер определяет оружие по экипированному
-- Tool (WeaponRegistry.ResolveFromCharacter), а удар запоминает оружие в момент начала.
--
-- Пока нет инвентаря, выданное оружие живёт столько же, сколько рюкзак (пропадает при
-- респавне). Сервис не хранит состояния и Init не требует.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage.Shared.Config.CombatConfig)
local WeaponRegistry = require(ReplicatedStorage.Shared.Weapons.WeaponRegistry)

local WeaponService = {}

local DEFAULT_HANDLE_COLOR = Color3.fromRGB(190, 195, 205)

local function GetBackpack(player)
    return player:FindFirstChildOfClass("Backpack")
end

local function GetHumanoid(player)
    local character = player.Character

    return character and character:FindFirstChildOfClass("Humanoid")
end

-- Добавляет в found Tool из container, у которых известный id оружия (и он равен weaponId,
-- если weaponId задан).
local function CollectTools(container, weaponId, found)
    if not container then
        return
    end

    for _, child in ipairs(container:GetChildren()) do
        local toolWeaponId = WeaponRegistry.ResolveFromTool(child)

        if toolWeaponId and (weaponId == nil or toolWeaponId == weaponId) then
            table.insert(found, child)
        end
    end
end

-- Все Tool игрока с этим оружием (рюкзак и экипированные). weaponId = nil: любое оружие.
local function FindTools(player, weaponId)
    local found = {}

    CollectTools(GetBackpack(player), weaponId, found)
    CollectTools(player.Character, weaponId, found)

    return found
end

local function CreateTool(weaponId, weapon)
    local tool = Instance.new("Tool")
    tool.Name = weapon.DisplayName or weaponId
    tool.CanBeDropped = false
    tool:SetAttribute(CombatConfig.WeaponAttribute, weaponId)

    -- Временная модель: рукоять по размерам из конфига, до появления настоящих моделей
    local handleConfig = weapon.Handle

    local handle = Instance.new("Part")
    handle.Name = "Handle"
    handle.Size = handleConfig.Size
    handle.Color = handleConfig.Color or DEFAULT_HANDLE_COLOR
    handle.Material = handleConfig.Material or Enum.Material.Metal
    handle.Massless = true
    handle.Parent = tool

    return tool
end

-- Выдаёт оружие в рюкзак. Одно оружие каждого вида на игрока.
-- Возвращает Tool либо nil, <причина>:
-- "UnknownWeapon" | "NotEquippable" | "NoBackpack" | "AlreadyHave".
function WeaponService:Give(player, weaponId)
    local weapon = WeaponRegistry.Get(weaponId)

    if not weapon then
        return nil, "UnknownWeapon"
    end

    if not WeaponRegistry.IsEquippable(weaponId) then
        return nil, "NotEquippable"
    end

    local backpack = GetBackpack(player)

    if not backpack then
        return nil, "NoBackpack"
    end

    if #FindTools(player, weaponId) > 0 then
        return nil, "AlreadyHave"
    end

    local tool = CreateTool(weaponId, weapon)
    tool.Parent = backpack

    return tool
end

-- Есть ли у игрока это оружие (в рюкзаке или в руках).
function WeaponService:Has(player, weaponId)
    return #FindTools(player, weaponId) > 0
end

-- Берёт в руки оружие, которое уже есть у игрока (смена оружия: прежнее уходит в рюкзак).
-- Возвращает true либо false, "CharacterUnavailable" | "NotOwned".
function WeaponService:Equip(player, weaponId)
    local humanoid = GetHumanoid(player)

    if not humanoid or humanoid.Health <= 0 then
        return false, "CharacterUnavailable"
    end

    local tool = FindTools(player, weaponId)[1]

    if not tool then
        return false, "NotOwned"
    end

    if tool.Parent ~= player.Character then
        humanoid:EquipTool(tool)
    end

    return true
end

-- Убирает оружие из рук в рюкзак: бой без оружия.
function WeaponService:Unequip(player)
    local humanoid = GetHumanoid(player)

    if not humanoid then
        return false, "CharacterUnavailable"
    end

    humanoid:UnequipTools()

    return true
end

-- Удаляет оружие игрока: указанное weaponId либо всё, если weaponId = nil.
-- Возвращает, сколько предметов удалено. Если удалено оружие в руках, персонаж
-- автоматически переходит к бою без оружия.
function WeaponService:Remove(player, weaponId)
    local removed = 0

    for _, tool in ipairs(FindTools(player, weaponId)) do
        tool:Destroy()
        removed += 1
    end

    return removed
end

function WeaponService:RemoveAll(player)
    return self:Remove(player, nil)
end

-- id оружия в руках игрока (Unarmed, если ничего не экипировано).
function WeaponService:GetEquippedWeaponId(player)
    return (WeaponRegistry.ResolveFromCharacter(player.Character))
end

return WeaponService
