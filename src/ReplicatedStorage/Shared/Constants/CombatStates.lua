-- Идентификаторы боевых состояний и фаз атаки.
-- Общий файл: сервер хранит состояния, клиент получает их для анимаций и эффектов.

local CombatStates = {
    Idle = "Idle",
    Attacking = "Attacking",
    Blocking = "Blocking",
    Dodging = "Dodging",
    Stunned = "Stunned",
    Dead = "Dead",

    AttackPhases = {
        Startup = "Startup",
        Active = "Active",
        Recovery = "Recovery",
    },

    -- Итог обработки урона (CombatStateService:ApplyDamage)
    DamageResults = {
        Hit = "Hit",         -- урон прошёл полностью
        Blocked = "Blocked", -- урон снижен блоком
        Parried = "Parried", -- удар парирован, урон не нанесён
        Ignored = "Ignored", -- цель мертва/недоступна или урон некорректен
    },
}

return CombatStates