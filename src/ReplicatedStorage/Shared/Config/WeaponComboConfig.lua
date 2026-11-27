-- Конфигурация комбо оружия.
--
-- Этот файл описывает СТРУКТУРУ атак, но не выполняет бой.
-- Сервер остаётся источником истины:
--   CombatService      - hitbox, урон и попадания;
--   CombatStateService - боевые состояния и фазы;
--   ComboService       - состояние и прогресс комбо.
--
-- Все значения таймингов здесь пока являются стартовыми значениями для будущих этапов.
-- На ЭТАПЕ 1 они НЕ заменяют CombatConfig.Weapons[*].AttackTiming и не меняют
-- существующее поведение боя.

local WeaponComboConfig = {}

WeaponComboConfig.Settings = {
    -- Сколько может длиться пауза после предыдущего подтверждённого звена,
    -- прежде чем серия считается законченной.
    DefaultResetAfter = 1.10,

    -- Максимальное количество заранее сохранённых Attack input.
    -- Первая версия Combo System использует только один.
    MaxBufferedInputs = 1,

    -- Защита от слишком долгого непрерывного удержания цели в hitstun.
    MaxComboLockDuration = 1.50,

    -- Запас для будущей проверки true combo.
    LatencyMargin = 0.10,
}

WeaponComboConfig.Weapons = {
    Unarmed = {
        StartMove = "Light1",
        MaxChain = 3,
        ResetAfter = 1.10,

        Moves = {
            Heavy = {
                Standalone = true, Cooldown = 0.9, MaxTargets = 1,
                Startup = 0.32, Active = 0.12, RecoveryOnHit = 0.35, RecoveryOnMiss = 0.60,
                DamageMultiplier = 1.45, PostureDamage = 26, HitStun = 0.38,
                SuperArmor = { Start = 0.03, Finish = 0.09 },
                Hitbox = { RangeMultiplier = 1, WidthMultiplier = 1 },
                WalkSpeed = { Startup = 0.35, Active = 0.15, Recovery = 0.40 },
                TurnScale = { Startup = 0.55, Active = 0.18, Recovery = 0.80 },
            },
            DashLight = {
                PostureDamage = 20,
                Index = 1, AlternativeStart = true, Next = "Light2",
                Startup = 0.10, Active = 0.12,
                RecoveryOnHit = 0.20, RecoveryOnMiss = 0.40,
                DamageMultiplier = 0.85, HitStun = 0.32,
                ParryInterrupt = false,
            },
            Light1 = {
                PostureDamage = 7,
                Index = 1,
                Next = "Light2",

                Startup = 0.16,
                Active = 0.10,

                RecoveryOnHit = 0.24,
                RecoveryOnMiss = 0.34,

                DamageMultiplier = 1.00,
                HitStun = 0.42,

                ParryInterrupt = false,
            },

            Light2 = {
                PostureDamage = 9,
                Index = 2,
                Next = "Light3",

                Startup = 0.17,
                Active = 0.10,

                RecoveryOnHit = 0.24,
                RecoveryOnMiss = 0.34,

                DamageMultiplier = 1.10,
                HitStun = 0.42,

                ParryInterrupt = false,
            },

            Light3 = {
                PostureDamage = 13,
                Index = 3,
                Next = nil,

                Startup = 0.22,
                Active = 0.12,

                RecoveryOnHit = 0.70,
                RecoveryOnMiss = 0.85,
                Finisher = { RagdollDuration = 1.20, KnockbackSpeed = 34, UpwardSpeed = 12 },

                DamageMultiplier = 1.40,
                HitStun = 0.50,

                ParryInterrupt = false,
            },
        },
    },

    Sword = {
        StartMove = "Light1",
        MaxChain = 3,
        ResetAfter = 1.20,

        Moves = {
            Heavy = {
                Standalone = true, Cooldown = 1.25, MaxTargets = 3,
                Startup = 0.46, Active = 0.16, RecoveryOnHit = 0.46, RecoveryOnMiss = 0.80,
                DamageMultiplier = 1.70, PostureDamage = 36, HitStun = 0.45,
                SuperArmor = { Start = 0.04, Finish = 0.12 },
                Hitbox = { RangeMultiplier = 1.10, WidthMultiplier = 1.15 },
                WalkSpeed = { Startup = 0.35, Active = 0.15, Recovery = 0.40 },
                TurnScale = { Startup = 0.30, Active = 0, Recovery = 0.80 },
            },
            DashLight = {
                PostureDamage = 13,
                Index = 1, AlternativeStart = true, Next = "Light2",
                Startup = 0.10, Active = 0.12,
                RecoveryOnHit = 0.20, RecoveryOnMiss = 0.40,
                DamageMultiplier = 0.85, HitStun = 0.32,
                ParryInterrupt = false,
            },
            Light1 = {
                PostureDamage = 9,
                Index = 1,
                Next = "Light2",

                Startup = 0.20,
                Active = 0.12,

                RecoveryOnHit = 0.28,
                RecoveryOnMiss = 0.40,

                DamageMultiplier = 1.00,
                HitStun = 0.50,

                ParryInterrupt = false,
            },

            Light2 = {
                PostureDamage = 11,
                Index = 2,
                Next = "Light3",

                Startup = 0.22,
                Active = 0.12,

                RecoveryOnHit = 0.30,
                RecoveryOnMiss = 0.42,

                DamageMultiplier = 1.15,
                HitStun = 0.50,

                -- Fresh F press during the first 0.16s of Light3 Startup grants
                -- a source-specific parry, including while recovering from Hit stun.
                ParryInterrupt = true,
                InterruptWindow = 0.16,
            },

            Light3 = {
                PostureDamage = 16,
                Index = 3,
                Next = nil,

                Startup = 0.26,
                Active = 0.14,

                RecoveryOnHit = 0.70,
                RecoveryOnMiss = 0.85,
                Finisher = { RagdollDuration = 1.20, KnockbackSpeed = 34, UpwardSpeed = 12 },

                DamageMultiplier = 1.50,
                HitStun = 0.55,

                ParryInterrupt = false,
            },
        },
    },
}

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

function WeaponComboConfig.GetWeapon(weaponId)
    return WeaponComboConfig.Weapons[weaponId]
end

function WeaponComboConfig.GetMove(weaponId, moveId)
    local weapon = WeaponComboConfig.Weapons[weaponId]

    if not weapon then
        return nil
    end

    return weapon.Moves[moveId]
end

function WeaponComboConfig.GetStartMove(weaponId)
    local weapon = WeaponComboConfig.Weapons[weaponId]

    if not weapon then
        return nil, nil
    end

    local moveId = weapon.StartMove

    return moveId, weapon.Moves[moveId]
end

function WeaponComboConfig.Validate()
    assert(
        IsFiniteNumber(WeaponComboConfig.Settings.MaxComboLockDuration)
            and WeaponComboConfig.Settings.MaxComboLockDuration > 0,
        "[WeaponComboConfig] Settings.MaxComboLockDuration must be > 0"
    )
    for weaponId, weapon in pairs(WeaponComboConfig.Weapons) do
        assert(
            type(weapon.StartMove) == "string",
            string.format(
                "[WeaponComboConfig] %s.StartMove must be a string",
                weaponId
            )
        )

        assert(
            type(weapon.Moves) == "table",
            string.format(
                "[WeaponComboConfig] %s.Moves must be a table",
                weaponId
            )
        )

        assert(
            weapon.Moves[weapon.StartMove] ~= nil,
            string.format(
                "[WeaponComboConfig] %s.StartMove '%s' does not exist",
                weaponId,
                weapon.StartMove
            )
        )

        assert(
            type(weapon.MaxChain) == "number"
                and weapon.MaxChain >= 1
                and weapon.MaxChain % 1 == 0,
            string.format(
                "[WeaponComboConfig] %s.MaxChain must be a positive integer",
                weaponId
            )
        )

        local resetAfter = weapon.ResetAfter
            or WeaponComboConfig.Settings.DefaultResetAfter

        assert(
            IsFiniteNumber(resetAfter) and resetAfter > 0,
            string.format(
                "[WeaponComboConfig] %s.ResetAfter must be > 0",
                weaponId
            )
        )

        local indexes = {}

        for moveId, move in pairs(weapon.Moves) do
            if move.Standalone then
                assert(moveId ~= weapon.StartMove and not move.Index and not move.Next and not move.Finisher,
                    "Standalone move cannot be a combo link")
                assert(IsFiniteNumber(move.Cooldown) and move.Cooldown > 0
                    and IsFiniteNumber(move.MaxTargets) and move.MaxTargets >= 1 and move.MaxTargets % 1 == 0,
                    "Invalid standalone cooldown or target limit")
                assert(IsFiniteNumber(move.RecoveryOnMiss) and IsFiniteNumber(move.RecoveryOnHit)
                    and move.RecoveryOnMiss >= move.RecoveryOnHit, "Invalid whiff recovery")
                local armor = move.SuperArmor
                assert(IsFiniteNumber(armor.Start) and IsFiniteNumber(armor.Finish)
                    and armor.Start >= 0 and armor.Start < armor.Finish and armor.Finish <= move.Active,
                    "Invalid armor window")
                for _, phase in ipairs({ "Startup", "Active", "Recovery" }) do
                    for _, scale in ipairs({ move.WalkSpeed, move.TurnScale }) do
                        assert(IsFiniteNumber(scale[phase]) and scale[phase] >= 0 and scale[phase] <= 1,
                            "Invalid movement scale")
                    end
                end
                assert(IsFiniteNumber(move.Hitbox.RangeMultiplier) and move.Hitbox.RangeMultiplier > 0
                    and IsFiniteNumber(move.Hitbox.WidthMultiplier) and move.Hitbox.WidthMultiplier > 0
                    and (move.Hitbox.HeightMultiplier == nil or IsFiniteNumber(move.Hitbox.HeightMultiplier)
                        and move.Hitbox.HeightMultiplier > 0),
                    "Invalid move hitbox")
            else
                assert(
                    type(move.Index) == "number"
                        and move.Index >= 1
                        and move.Index % 1 == 0,
                    string.format(
                        "[WeaponComboConfig] %s.%s.Index must be a positive integer",
                        weaponId,
                        moveId
                    )
                )

                if move.AlternativeStart then
                    assert(move.Index == 1 and moveId ~= weapon.StartMove and move.Next
                        and weapon.Moves[move.Next] and weapon.Moves[move.Next].Index == 2,
                        "Invalid alternate combo start: " .. weaponId .. "." .. moveId)
                end
                assert(
                    move.AlternativeStart or not indexes[move.Index],
                    string.format(
                        "[WeaponComboConfig] %s has duplicate combo index %d",
                        weaponId,
                        move.Index
                    )
                )

                if not move.AlternativeStart then indexes[move.Index] = true end
            end

            if move.Next ~= nil then
                assert(
                    type(move.Next) == "string"
                        and weapon.Moves[move.Next] ~= nil and not weapon.Moves[move.Next].Standalone,
                    string.format(
                        "[WeaponComboConfig] %s.%s.Next references unknown move '%s'",
                        weaponId,
                        moveId,
                        tostring(move.Next)
                    )
                )
            end

            assert(
                IsFiniteNumber(move.Startup) and move.Startup >= 0,
                string.format(
                    "[WeaponComboConfig] %s.%s.Startup must be >= 0",
                    weaponId,
                    moveId
                )
            )

            assert(
                IsFiniteNumber(move.Active) and move.Active > 0,
                string.format(
                    "[WeaponComboConfig] %s.%s.Active must be > 0",
                    weaponId,
                    moveId
                )
            )

            assert(
                IsFiniteNumber(move.RecoveryOnHit)
                    and move.RecoveryOnHit >= 0,
                string.format(
                    "[WeaponComboConfig] %s.%s.RecoveryOnHit must be >= 0",
                    weaponId,
                    moveId
                )
            )

            assert(
                IsFiniteNumber(move.RecoveryOnMiss)
                    and move.RecoveryOnMiss >= 0,
                string.format(
                    "[WeaponComboConfig] %s.%s.RecoveryOnMiss must be >= 0",
                    weaponId,
                    moveId
                )
            )

            assert(
                IsFiniteNumber(move.DamageMultiplier)
                    and move.DamageMultiplier > 0,
                string.format(
                    "[WeaponComboConfig] %s.%s.DamageMultiplier must be > 0",
                    weaponId,
                    moveId
                )
            )

            assert(
                IsFiniteNumber(move.HitStun)
                    and move.HitStun >= 0,
                string.format(
                    "[WeaponComboConfig] %s.%s.HitStun must be >= 0",
                    weaponId,
                    moveId
                )
            )

            assert(IsFiniteNumber(move.PostureDamage) and move.PostureDamage >= 0, "Invalid move PostureDamage")
            if move.Finisher then
                assert(move.Next == nil and move.Index == weapon.MaxChain,
                    "Finisher must be the final combo move")
                for _, key in ipairs({ "RagdollDuration", "KnockbackSpeed", "UpwardSpeed" }) do
                    local n = move.Finisher[key]
                    assert(IsFiniteNumber(n) and n > 0 and n <= (key == "RagdollDuration" and 3 or 80),
                        "Invalid finisher " .. key)
                end
            end
            if move.ParryInterrupt then
                assert(
                    move.Next ~= nil and weapon.Moves[move.Next] ~= nil,
                    string.format(
                        "[WeaponComboConfig] %s.%s.ParryInterrupt needs a next move",
                        weaponId, moveId
                    )
                )
                assert(
                    IsFiniteNumber(move.InterruptWindow)
                        and move.InterruptWindow > 0,
                    string.format(
                        "[WeaponComboConfig] %s.%s.InterruptWindow must be > 0",
                        weaponId,
                        moveId
                    )
                )
            end
        end

        local startMove = weapon.Moves[weapon.StartMove]

        assert(
            startMove.Index == 1,
            string.format(
                "[WeaponComboConfig] %s start move must have Index = 1",
                weaponId
            )
        )

        for index = 1, weapon.MaxChain do
            assert(
                indexes[index],
                string.format(
                    "[WeaponComboConfig] %s is missing combo index %d",
                    weaponId,
                    index
                )
            )
        end
    end

    return true
end

return WeaponComboConfig