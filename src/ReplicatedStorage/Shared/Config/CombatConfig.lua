-- Настройки боевой системы. Все значения предварительные, для тестирования.
-- Файл общий для сервера и клиента: сервер использует его для расчётов,
-- клиент только для темпа атак и анимаций (решает всё равно сервер).

local CombatConfig = {}
CombatConfig.DebugHitboxes = true

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

-- Интервал серверных проверок Active. 0 = каждый Heartbeat, после шага физики.
-- Каждая цель всё равно поражается не более одного раза за удар.
CombatConfig.ActiveScanInterval = 0

-- Server-measured RTT / 2 estimates the replicated attacker's horizontal position delay.
-- This is bounded extrapolation, not target rewind or full lag compensation.
CombatConfig.HitboxPrediction = {
    Enabled = true,
    MaxTime = 0.10,
    MaxDistance = 1.5,
    MaxSpeed = 40,
}

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
-- Анимации оружия задаются не здесь, а в CombatAnimationConfig.
-- Equippable - можно ли выдать оружие как предмет (Tool). У Unarmed false: это боевой набор.
-- Handle     - внешний вид Tool у Equippable-оружия: Size (обязателен), Color, Material.
--   Tool создаёт WeaponService, реестр и проверки лежат в WeaponRegistry.
-- Необязательные переопределения для конкретного оружия (иначе берутся общие значения выше):
--   RootRangeTolerance, MaxAttackAngle
CombatConfig.Weapons = {
    Unarmed = {
        DisplayName = "Fists",
        Equippable = false, -- бой без оружия: не предмет, в рюкзак не выдаётся
        BaseDamage = 5,
        Scaling = 0.5,
        Cooldown = 0.8,
        HitStun = 0.20,
        AttackTiming = {
            Startup = 0.18,
            Active = 0.15,
            Recovery = 0.15,
            CanDodgeDuringRecovery = true,
            CanBlockDuringRecovery = true,
        },
        AttackRange = 7,
        HitboxWidth = 4,
        MaxTargets = 5,
    },

    Sword = {
        DisplayName = "Sword",
        Equippable = true,
        Handle = {
            Animated = true, -- R6 Right Arm -> Handle uses Motor6D.
            Size = Vector3.new(0.4, 0.4, 4),
            -- Bind pose from the animation authoring rig.
            Grip = {
                Name = "Motor6D",
                C0 = CFrame.new(),
                C1 = CFrame.new(0, 0.926, 1.356),
            },
            Color = Color3.fromRGB(190, 195, 205),
            Material = Enum.Material.Metal,
        },
        BaseDamage = 15,
        Scaling = 0.8,
        Cooldown = 1.0,
        HitStun = 0.22,
        AttackTiming = {
            Startup = 0.20,
            Active = 0.20,
            Recovery = 0.30,
            CanDodgeDuringRecovery = true,
            CanBlockDuringRecovery = true,
        },
        AttackRange = 9,
        HitboxWidth = 5,
        MaxTargets = 5,
    },
}

return CombatConfig
