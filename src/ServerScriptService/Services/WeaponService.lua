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

-- Keep the Tool lifecycle while making its R6 Handle an animation channel.
local function BindAnimatedHandle(tool, handle, handleConfig)
    local gripConfig = handleConfig.Grip or {}
    local motor
    local armConnection
    local equipVersion = 0

    local function ClearGrip()
        equipVersion += 1
        if armConnection then
            armConnection:Disconnect()
            armConnection = nil
        end
        if motor then
            motor:Destroy()
            motor = nil
        end
    end

    tool.Equipped:Connect(function()
        ClearGrip()
        local version = equipVersion
        local character = tool.Parent
        local arm = character and character:FindFirstChild("Right Arm")
        if not arm or not arm:IsA("BasePart") then
            warn("[WeaponService] Animated Handle requires an R6 Right Arm:", tool.Name)
            return
        end

        local function ReplaceGrip(candidate)
            -- Roblox can add RightGrip before or after Equipped fires.
            task.defer(function()
                if version ~= equipVersion or tool.Parent ~= character
                    or candidate.Parent ~= arm or candidate == motor
                    or candidate.Name ~= "RightGrip"
                    or not candidate:IsA("JointInstance")
                    or candidate.Part0 ~= arm or candidate.Part1 ~= handle
                then
                    return
                end

                local replacement = Instance.new("Motor6D")
                replacement.Name = gripConfig.Name or candidate.Name
                replacement.Part0 = arm
                replacement.Part1 = handle
                replacement.C0 = gripConfig.C0 or candidate.C0
                replacement.C1 = gripConfig.C1 or candidate.C1
                replacement.Enabled = candidate.Enabled

                if motor then
                    motor:Destroy()
                end
                motor = replacement
                candidate:Destroy()
                replacement.Parent = arm
            end)
        end

        armConnection = arm.ChildAdded:Connect(ReplaceGrip)
        for _, child in ipairs(arm:GetChildren()) do
            ReplaceGrip(child)
        end
    end)

    tool.Unequipped:Connect(ClearGrip)
    tool.Destroying:Connect(ClearGrip)
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
    handle.CanCollide = false
    handle.Parent = tool

    if handleConfig.Animated then
        BindAnimatedHandle(tool, handle, handleConfig)
    end

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
