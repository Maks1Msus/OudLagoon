-- Настройки боевой системы. Все значения предварительные, для тестирования.
-- Файл общий для сервера и клиента: сервер использует его для расчётов,
-- клиент только для темпа атак и анимаций (решает всё равно сервер).

local CombatConfig = {}

-- Атрибут Tool, по которому СЕРВЕР определяет оружие.
-- Ставится только сервером: клиент не может создать Tool или изменить атрибут так,
-- чтобы это увидел сервер.
CombatConfig.WeaponAttribute = "CombatWeaponId"

-- Бой без оружия (нет Tool или у Tool неизвестный CombatWeaponId)
CombatConfig.UnarmedId = "Unarmed"

CombatConfig.PvPEnabled = true

-- Проверка по HumanoidRootPart цели (в дополнение к области удара).
-- Область удара ловит любые части модели, поэтому у крупных NPC она может задеть тело,
-- корень которого лежит далеко. Эти параметры не дают по такой цели попасть.
--
-- RootRangeTolerance: запас (studs) к AttackRange для расстояния до корня цели.
--   Компенсирует сетевые задержки и толщину тела. Расстояние считается в 3D.
CombatConfig.RootRangeTolerance = 1

-- MaxAttackAngle: максимальный угол (градусы, в горизонтальной плоскости) между
--   направлением взгляда атакующего и направлением на корень цели. 70 = конус 140 градусов.
CombatConfig.MaxAttackAngle = 70

-- Ближе этого расстояния (по горизонтали, studs) направление не проверяется:
--   цель вплотную, направление до неё не определить.
CombatConfig.DirectionCheckMinDistance = 1.5

-- Допуск на сетевые задержки при проверке кулдауна (сек).
-- Не накапливается: следующая атака всё равно отсчитывается от запланированного времени.
CombatConfig.CooldownTolerance = 0.05

-- Высота области удара (studs)
CombatConfig.HitboxHeight = 6

-- Печатать в Output каждую атаку (удобно при отладке, потом выключить)
CombatConfig.DebugLogging = true

-- Урон = BaseDamage + Strength * Scaling
-- Cooldown   - пауза между атаками (сек)
-- AttackRange - глубина области удара перед персонажем (studs)
-- HitboxWidth - ширина области удара (studs)
-- MaxTargets - сколько целей может поразить одна атака
-- AnimationId - "rbxassetid://..." (nil = без анимации, пока нет ассетов)
-- Необязательные переопределения для конкретного оружия (иначе берутся общие значения выше):
--   RootRangeTolerance, MaxAttackAngle
CombatConfig.Weapons = {
    Unarmed = {
        DisplayName = "Fists",
        BaseDamage = 5,
        Scaling = 0.5,
        Cooldown = 0.8,
        AttackRange = 5,
        HitboxWidth = 4,
        MaxTargets = 1,
        AnimationId = nil,
    },

    Sword = {
        DisplayName = "Sword",
        BaseDamage = 15,
        Scaling = 0.8,
        Cooldown = 1.0,
        AttackRange = 6,
        HitboxWidth = 5,
        MaxTargets = 3,
        AnimationId = nil,
    },
}

return CombatConfig