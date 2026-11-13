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

local CombatAnimationConfig = {}

-- Слоты: что именно можно проиграть и как.
-- Priority - приоритет AnimationTrack (перекрывает приоритет, заданный в самом ассете).
-- Looped   - зацикливать ли анимацию (блок удерживается, значит зациклен).
CombatAnimationConfig.Slots = {
    Attack = { Priority = Enum.AnimationPriority.Action2, Looped = false },
    Block = { Priority = Enum.AnimationPriority.Action, Looped = true },
    Parry = { Priority = Enum.AnimationPriority.Action3, Looped = false },
    Hit = { Priority = Enum.AnimationPriority.Action3, Looped = false },
    Stun = { Priority = Enum.AnimationPriority.Action4, Looped = true },
    Dodge = { Priority = Enum.AnimationPriority.Action3, Looped = false },
}

-- Анимации конкретного оружия. Ключ = идентификатор оружия из CombatConfig.Weapons.
-- Любой слот можно переопределить для оружия; иначе берётся Common.
CombatAnimationConfig.Weapons = {
    Unarmed = {
        Attack = "rbxassetid://0",
    },

    Sword = {
        Attack = "rbxassetid://0",
    },
}

-- Общие анимации, не зависящие от оружия.
-- Сейчас подключены: Block, Stun, Dodge. Parry и Hit подключатся позже:
-- для них серверу нужно сообщать защищающемуся результат удара.
CombatAnimationConfig.Common = {
    Block = "rbxassetid://0",
    Parry = "rbxassetid://0",
    Hit = "rbxassetid://0",
    Stun = "rbxassetid://0",
    Dodge = "rbxassetid://0",
}

CombatAnimationConfig.Settings = {
    FadeInTime = 0.1,  -- плавное включение (сек)
    FadeOutTime = 0.1, -- плавное выключение (сек)

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

return CombatAnimationConfig
