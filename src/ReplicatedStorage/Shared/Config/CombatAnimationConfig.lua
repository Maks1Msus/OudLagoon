-- Идентификаторы боевых анимаций и правила их воспроизведения (только клиентская визуализация).
-- Сервер об анимациях ничего не знает: тайминги и урон определяют CombatConfig и
-- CombatStateService, а CombatAnimationController лишь показывает подтверждённое состояние.
--
-- ID "rbxassetid://0" (или пустая строка / nil) = анимация ещё не сделана: слот пропускается
-- без ошибок. Чтобы подключить анимацию, замените 0 на ID опубликованной анимации.
--
-- Длительность анимации атаки должна быть равна Startup + Active + Recovery оружия
-- из CombatConfig (сейчас Unarmed = 0.52 с, Sword = 0.70 с). Серверные тайминги под
-- анимацию не подгоняются; если длина расходится, в Output появится предупреждение.
--
-- БЛОК состоит из двух анимаций:
--   BlockStart - вход в защитную стойку (не зациклена), стартует при подтверждении блока сервером;
--   BlockLoop  - удержание блока (зациклена), включается плавно к концу BlockStart.
-- Окно парирования на сервере открывается в момент активации блока и от длины BlockStart
-- НЕ зависит. Рекомендуется делать BlockStart примерно равной Block.ParryWindow
-- (CombatStateConfig), чтобы движение совпадало с окном парирования.
-- Если BlockStart не назначена, сразу играет BlockLoop.
--
-- РЕАКЦИИ (накладываются поверх текущей позы и не меняют состояние):
--   Parry    - успешное парирование; прерывает блок, затем снова включается BlockLoop;
--   BlockHit - короткая реакция на удар, принятый в блок;
--   Hit1..3  - получение полного урона; вариант выбирается случайно, без повтора подряд
--              (PickHitSlot), берутся только назначенные;
--   Parried  - реакция АТАКУЮЩЕГО, чей удар парировали (клиент игрока и NPC);
--   Stunned  - оглушение СПОСОБНОСТЬЮ. Играет только по явному событию (CombatFeedback,
--              Kind = "Reaction", Reaction = "Stunned" / PlayReaction у NPC), а не при
--              любом переходе в состояние Stunned: оглушение от удара и парирования
--              показывается реакциями Hit1..3 и Parried.
--
-- Приоритеты: блок (Action) < Attack (Action2) < BlockHit и Hit1..3 (Action3) <
-- Parry, Parried, Stunned (Action4). Parry выше BlockHit, чтобы реакция на предыдущий
-- удар не перекрывала парирование.

local CombatConfig = require(script.Parent.CombatConfig)
local CombatStates = require(script.Parent.Parent.Constants.CombatStates)

local CombatAnimationConfig = {}

-- Слоты реакции на полный урон (из них PickHitSlot выбирает случайный).
CombatAnimationConfig.HitSlots = { "Hit1", "Hit2", "Hit3" }

-- Слоты: что именно можно проиграть и как.
-- Priority - приоритет AnimationTrack (перекрывает приоритет, заданный в самом ассете).
-- Looped   - зацикливать ли анимацию.
CombatAnimationConfig.Slots = {
    Attack = { Priority = Enum.AnimationPriority.Action2, Looped = false },

    BlockStart = { Priority = Enum.AnimationPriority.Action, Looped = false },
    BlockLoop = { Priority = Enum.AnimationPriority.Action, Looped = true },
    BlockHit = { Priority = Enum.AnimationPriority.Action3, Looped = false },

    -- Парирование (защищающийся). Должно быть выше BlockHit и блока.
    Parry = { Priority = Enum.AnimationPriority.Action4, Looped = false },

    Parried = { Priority = Enum.AnimationPriority.Action4, Looped = false },

    Hit1 = { Priority = Enum.AnimationPriority.Action3, Looped = false },
    Hit2 = { Priority = Enum.AnimationPriority.Action3, Looped = false },
    Hit3 = { Priority = Enum.AnimationPriority.Action3, Looped = false },

    Stunned = { Priority = Enum.AnimationPriority.Action4, Looped = true },
    Dodge = { Priority = Enum.AnimationPriority.Action3, Looped = false },
}
-- Анимации конкретного оружия. Ключ = идентификатор оружия из CombatConfig.Weapons.
-- Любой слот можно переопределить для оружия (например, BlockStart/BlockLoop/Parry меча);
-- иначе берётся Common.
CombatAnimationConfig.Weapons = {
    Unarmed = {
        Attack = "rbxassetid://71788438859538",
    },

    Sword = {
        Attack = "rbxassetid://91695651580130",
    },
}

-- Общие анимации, не зависящие от оружия.
CombatAnimationConfig.Common = {
    BlockStart = "rbxassetid://121365165289991",
    BlockLoop = "rbxassetid://132713008662757",
    BlockHit = "rbxassetid://0",
    Parry = "rbxassetid://98950245815500",
    Hit1 = "rbxassetid://0",
    Hit2 = "rbxassetid://0",
    Hit3 = "rbxassetid://0",

    Parried = "rbxassetid://0",
    Stunned = "rbxassetid://86159934712814",
    Dodge = "rbxassetid://0",
}

CombatAnimationConfig.Settings = {
    FadeInTime = 0.1,  -- плавное включение (сек)
    FadeOutTime = 0.1, -- плавное выключение (сек)

    -- За сколько секунд до конца BlockStart (и Parry) включается следующая анимация.
    -- Даёт плавный переход без рывка: две анимации перекрываются на это время.
    LoopBlendTime = 0.1,

    -- Состояния, в которых реакция Hit1..3 не должна проигрываться (используется, если
    -- реакция не должна выглядеть как прерывание текущего действия).
    SuppressHitDuring = {
        Attacking = true,
        Dodging = true,
        Stunned = true,
    },

    -- Предупреждать, если длина анимации атаки расходится с серверным таймингом
    WarnOnLengthMismatch = true,
    LengthTolerance = 0.1, -- допустимое расхождение (сек)

    DebugLogging = false, -- печатать в Output переключения анимаций
}

-- Назначена ли анимация (а не заглушка).
function CombatAnimationConfig.IsAssigned(animationId)
    if type(animationId) ~= "string" or animationId == "" then
        return false
    end

    -- "rbxassetid://0", "rbxassetid://000" - заглушки
    return animationId:match("^rbxassetid://0*$") == nil
end

-- ID анимации для слота: сначала оружие, затем общие. nil, если не назначена.
function CombatAnimationConfig.GetAnimationId(slot, weaponId)
    local weapon = weaponId and CombatAnimationConfig.Weapons[weaponId]
    local animationId = weapon and weapon[slot]

    if not CombatAnimationConfig.IsAssigned(animationId) then
        animationId = CombatAnimationConfig.Common[slot]
    end

    if CombatAnimationConfig.IsAssigned(animationId) then
        return animationId
    end

    return nil
end

-- Единое правило для игроков и NPC: проигрывать ли реакцию Hit1..3, если в момент удара
-- получатель находился в состоянии state (см. Settings.SuppressHitDuring).
function CombatAnimationConfig.ShouldPlayHit(state)
    return not CombatAnimationConfig.Settings.SuppressHitDuring[state]
end

-- Случайный слот реакции на урон среди НАЗНАЧЕННЫХ Hit1..3, не равный lastSlot
-- (если вариантов больше одного). nil, если ни одна анимация не назначена.
-- random - необязательная функция () -> число [0, 1) (для тестов); по умолчанию math.random.
function CombatAnimationConfig.PickHitSlot(weaponId, lastSlot, random)
    local candidates = {}

    for _, slot in ipairs(CombatAnimationConfig.HitSlots) do
        if CombatAnimationConfig.GetAnimationId(slot, weaponId) then
            table.insert(candidates, slot)
        end
    end

    if #candidates > 1 then
        local index = table.find(candidates, lastSlot)

        if index then
            table.remove(candidates, index)
        end
    end

    if #candidates == 0 then
        return nil
    end

    local roll = random and random() or math.random()

    return candidates[math.min(#candidates, math.floor(roll * #candidates) + 1)]
end

-- Слоты, которые использует код боевых анимаций (клиент игрока и NPC).
CombatAnimationConfig.RequiredSlots = {
    "Attack", "BlockStart", "BlockLoop", "BlockHit", "Parry", "Parried",
    "Hit1", "Hit2", "Hit3", "Stunned", "Dodge",
}

-- Проверка согласованности конфигурации. Возвращает список проблем (пустой = всё в порядке).
function CombatAnimationConfig.Validate()
    local problems = {}

    local function add(...)
        table.insert(problems, table.concat({ ... }, " "))
    end

    for _, slot in ipairs(CombatAnimationConfig.RequiredSlots) do
        if not CombatAnimationConfig.Slots[slot] then
            add("slot", slot, "is used by the animation code but missing in Slots")
        end
    end

    for slot, settings in pairs(CombatAnimationConfig.Slots) do
        if typeof(settings.Priority) ~= "EnumItem"
            or settings.Priority.EnumType ~= Enum.AnimationPriority
        then
            add("Slots." .. slot, "has no valid Priority")
        end

        if type(settings.Looped) ~= "boolean" then
            add("Slots." .. slot, "has no boolean Looped")
        end

        -- Слот должен быть объявлен в Common либо хотя бы у одного оружия
        -- (например, Attack лежит только в Weapons.Unarmed / Weapons.Sword)
        local declared = CombatAnimationConfig.Common[slot] ~= nil

        for _, animations in pairs(CombatAnimationConfig.Weapons) do
            if animations[slot] ~= nil then
                declared = true
                break
            end
        end

        if not declared then
            add("slot", slot, "has no entry in Common or in any weapon (use \"rbxassetid://0\" as placeholder)")
        end
    end

    for slot in pairs(CombatAnimationConfig.Common) do
        if not CombatAnimationConfig.Slots[slot] then
            add("Common." .. slot, "is not a known slot (typo?)")
        end
    end

    for weaponId, animations in pairs(CombatAnimationConfig.Weapons) do
        if not CombatConfig.Weapons[weaponId] then
            add("Weapons." .. weaponId, "is not a weapon from CombatConfig")
        end

        for slot in pairs(animations) do
            if not CombatAnimationConfig.Slots[slot] then
                add("Weapons." .. weaponId .. "." .. slot, "is not a known slot (typo?)")
            end
        end
    end

    for _, slot in ipairs(CombatAnimationConfig.HitSlots) do
        if not CombatAnimationConfig.Slots[slot] then
            add("HitSlots contains unknown slot", slot)
        end
    end

    for state in pairs(CombatAnimationConfig.Settings.SuppressHitDuring) do
        if type(CombatStates[state]) ~= "string" then
            add("Settings.SuppressHitDuring has unknown state", state)
        end
    end

    return problems
end

-- Печатает проблемы конфигурации (warn). Возвращает true, если проблем нет.
function CombatAnimationConfig.WarnIfInvalid(owner)
    local problems = CombatAnimationConfig.Validate()

    for _, problem in ipairs(problems) do
        warn("[CombatAnimationConfig]", owner or "", problem)
    end

    return #problems == 0
end

return CombatAnimationConfig
