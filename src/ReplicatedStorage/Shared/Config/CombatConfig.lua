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

-- Как часто (сек) сервер проверяет попадания, пока атака находится в фазе Active.
-- Каждая цель всё равно поражается не более одного раза за удар.
CombatConfig.ActiveScanInterval = 0.05

-- Урон = BaseDamage + Strength * Scaling
-- Cooldown   - пауза между НАЧАЛАМИ атак (сек); не зависит от длительности самого удара
-- AttackTiming - фазы одного удара (сек):
--   Startup  - подготовка, урон не наносится
--   Active   - окно регистрации попаданий (урон наносится только здесь)
--   Recovery - завершение удара
--   CanDodgeDuringRecovery / CanBlockDuringRecovery - можно ли прервать Recovery
--     уклонением / блоком (Startup и Active прервать нельзя)
--   Полная длительность удара = Startup + Active + Recovery.
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
        AttackTiming = {
            Startup = 0.12,
            Active = 0.15,
            Recovery = 0.25,
            CanDodgeDuringRecovery = true,
            CanBlockDuringRecovery = true,
        },
        AttackRange = 5,
        HitboxWidth = 4,
        MaxTargets = 5,
        AnimationId = nil,
    },

    Sword = {
        DisplayName = "Sword",
        BaseDamage = 15,
        Scaling = 0.8,
        Cooldown = 1.0,
        AttackTiming = {
            Startup = 0.20,
            Active = 0.20,
            Recovery = 0.30,
            CanDodgeDuringRecovery = true,
            CanBlockDuringRecovery = true,
        },
        AttackRange = 6,
        HitboxWidth = 5,
        MaxTargets = 5,
        AnimationId = nil,
    },
}

return CombatConfig