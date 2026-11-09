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
}

return CombatStates
