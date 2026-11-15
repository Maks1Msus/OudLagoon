-- WeaponRegistry: единая точка доступа к описаниям оружия (CombatConfig.Weapons).
-- Общий модуль для сервера и клиента. Боевая система не знает особенностей конкретного
-- оружия: она получает его параметры отсюда, а определение "какое оружие у персонажа"
-- живёт ТОЛЬКО здесь (раньше этот код был скопирован в нескольких местах).
--
-- Оружие персонажа - экипированный Tool с атрибутом CombatWeaponId (ставит только сервер,
-- см. WeaponService). Нет Tool, либо у Tool неизвестный id: бой без оружия (Unarmed).
-- Unarmed - боевой набор, а не предмет: Equippable = false, в рюкзак не выдаётся.

local CombatConfig = require(script.Parent.Parent.Config.CombatConfig)

local WeaponRegistry = {}

-- Описание оружия по id либо nil.
function WeaponRegistry.Get(weaponId)
    if type(weaponId) ~= "string" then
        return nil
    end

    return CombatConfig.Weapons[weaponId]
end

function WeaponRegistry.GetUnarmedId()
    return CombatConfig.UnarmedId
end

-- Можно ли выдать это оружие как предмет (Tool).
function WeaponRegistry.IsEquippable(weaponId)
    local weapon = WeaponRegistry.Get(weaponId)

    return weapon ~= nil and weapon.Equippable == true
end

-- Отсортированный список id оружия, которое можно выдать (для тестов и меню).
function WeaponRegistry.GetEquippableIds()
    local ids = {}

    for weaponId, weapon in pairs(CombatConfig.Weapons) do
        if weapon.Equippable == true then
            table.insert(ids, weaponId)
        end
    end

    table.sort(ids)

    return ids
end

-- Оружие по Tool: id берётся из атрибута CombatWeaponId.
-- Возвращает weaponId, weapon либо nil, nil (не Tool, нет атрибута, неизвестный id).
function WeaponRegistry.ResolveFromTool(tool)
    if typeof(tool) ~= "Instance" or not tool:IsA("Tool") then
        return nil, nil
    end

    local weaponId = tool:GetAttribute(CombatConfig.WeaponAttribute)
    local weapon = WeaponRegistry.Get(weaponId)

    if weapon then
        return weaponId, weapon
    end

    return nil, nil
end

-- Оружие персонажа: экипированный Tool с известным id, иначе Unarmed.
-- Всегда возвращает weaponId, weapon.
function WeaponRegistry.ResolveFromCharacter(character)
    local tool = character and character:FindFirstChildOfClass("Tool")
    local weaponId, weapon = WeaponRegistry.ResolveFromTool(tool)

    if weapon then
        return weaponId, weapon
    end

    local unarmedId = CombatConfig.UnarmedId

    return unarmedId, CombatConfig.Weapons[unarmedId]
end

-- Ошибка конфигурации должна проявиться при запуске, а не в бою.
function WeaponRegistry.Validate()
    local unarmedId = CombatConfig.UnarmedId

    assert(
        type(CombatConfig.Weapons[unarmedId]) == "table",
        "[WeaponRegistry] Unarmed weapon '" .. tostring(unarmedId) .. "' is not defined"
    )

    for weaponId, weapon in pairs(CombatConfig.Weapons) do
        local name = tostring(weaponId)

        assert(
            type(weapon.AttackTiming) == "table",
            "[WeaponRegistry] Weapon '" .. name .. "' has no AttackTiming"
        )

        if weapon.Equippable == true then
            assert(
                weaponId ~= unarmedId,
                "[WeaponRegistry] Weapon '" .. name .. "' is Unarmed and cannot be Equippable"
            )

            assert(
                type(weapon.Handle) == "table" and typeof(weapon.Handle.Size) == "Vector3",
                "[WeaponRegistry] Equippable weapon '" .. name .. "' needs Handle.Size (Vector3)"
            )
        end
    end
end

return WeaponRegistry
