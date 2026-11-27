local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatStateConfig = require(
    ReplicatedStorage.Shared.Config.CombatStateConfig
)

local CombatConfig = require(
    ReplicatedStorage.Shared.Config.CombatConfig
)

local GameConstants = require(
    ReplicatedStorage.Shared.Constants.GameConstants
)

local CombatStates = require(
    ReplicatedStorage.Shared.Constants.CombatStates
)

local WeaponRegistry = require(
    ReplicatedStorage.Shared.Weapons.WeaponRegistry
)
local StatRules = require(ReplicatedStorage.Shared.Progression.StatRules)

local DataService = require(script.Parent.DataService)
local RemoteService = require(script.Parent.RemoteService)
local CombatStateService = require(script.Parent.CombatStateService)
local ComboService = require(script.Parent.ComboService)
local WeaponComboConfig = require(ReplicatedStorage.Shared.Config.WeaponComboConfig)
local NPCCombatAnimationService = require(script.Parent.NPCCombatAnimationService)

local DashService = require(script.Parent.DashService)
local HitboxPose = require(ReplicatedStorage.Shared.Combat.HitboxPose)

local PostureService = require(script.Parent.PostureService)
local PostureConfig = require(ReplicatedStorage.Shared.Config.PostureConfig)
local CombatService = {}

-- [player или character NPC] = момент времени (os.clock), раньше которого следующая атака
-- запрещена. Ключ - Player для игрока и Model для NPC; слабые ключи не копят удалённых NPC.
local NextAttackAt = setmetatable({}, { __mode = "k" })

local NextHeavyAt = setmetatable({}, { __mode = "k" })

-- [character] = данные текущего удара, пока он не завершился:
-- { AttackId, Player (nil у NPC), Character, WeaponId, Weapon, Strength (только NPC), TracksCombo }
local Attacks = setmetatable({}, { __mode = "k" })
-- Debug drawing follows the same root locally on every client. It is not a server-position snapshot.
local DebugHitboxes = setmetatable({}, { __mode = "k" })

local function ClearDebugHitbox(character, attackId)
    local record = DebugHitboxes[character]
    if record and (attackId == nil or record.AttackId == attackId) then
        record.Box:Destroy()
        DebugHitboxes[character] = nil
    end
end

local function UpdateDebugHitbox(character, root, weapon, boxSize, attackId)
    if not CombatConfig.DebugHitboxes or not attackId then
        ClearDebugHitbox(character)
        return
    end
    local record = DebugHitboxes[character]
    if record and (record.AttackId ~= attackId or record.Root ~= root or not record.Box.Parent) then
        ClearDebugHitbox(character)
        record = nil
    end
    if not record then
        local box = Instance.new("BoxHandleAdornment")
        box.Name = "DebugAttackHitbox"
        box.Adornee = root
        box.AlwaysOnTop = false
        box.Color3 = Color3.fromRGB(255, 80, 80)
        box.Transparency = 0.75
        box.Parent = root
        record = { Box = box, Root = root, AttackId = attackId }
        DebugHitboxes[character] = record
    end
    record.Box.Size = boxSize
    record.Box.CFrame = CFrame.new(0, 0, -weapon.AttackRange / 2)
end

local function CanTrackCombo(attack)
    if attack.TracksCombo and not ComboService:ValidateWeapon(attack.Character) then
        attack.TracksCombo = false
    end

    return attack.TracksCombo
end

local function Log(...)
    if CombatConfig.DebugLogging then
        print("[CombatService]", ...)
    end
end

-- ОГЛУШЕНИЕ СПОСОБНОСТЬЮ -------------------------------------------------

-- Оглушает игрока или NPC способностью с Source = "Ability".
-- Анимация Stunned следует серверному состоянию и его сроку окончания.
-- CombatFeedback сохраняется для совместимости с другими подписчиками.
-- duration - секунды (по умолчанию CombatStateConfig.Stun.AbilityDuration; ограничивается
-- Stun.MaxDuration). Правила ApplyStun (иммунитет, уже оглушён, смерть) действуют как обычно.
-- Возвращает true, <TransitionId> либо false, <причина>.
function CombatService:ApplyAbilityStun(character, duration)
    local ok, result = CombatStateService:ApplyStun(
        character,
        duration or CombatStateConfig.Stun.AbilityDuration,
        "Ability"
    )

    if not ok then
        return false, result
    end

    local owner = Players:GetPlayerFromCharacter(character)

    if owner then
        RemoteService:GetEvent("CombatFeedback"):FireClient(owner, {
            Kind = "Reaction",
            Reaction = "Stunned",
        })
    else
        NPCCombatAnimationService:PlayReaction(character, "Stunned")
    end

    return true, result
end

-- ОРУЖИЕ ----------------------------------------------------------------

-- Оружие определяется сервером по экипированному Tool с атрибутом CombatWeaponId
-- (см. WeaponRegistry). Неизвестный или отсутствующий id означает бой без оружия.
-- Возвращает weaponId, weapon.
function CombatService:GetWeapon(character)
    return WeaponRegistry.ResolveFromCharacter(character)
end

-- УРОН ------------------------------------------------------------------

-- Damage = BaseDamage + Strength * Scaling (округляется, минимум 1).
-- Округление защищает от ошибок чисел с плавающей точкой (22.9999 вместо 23).
function CombatService:CalculateDamage(weapon, strength)
    return StatRules.GetBaseDamage(weapon, strength)
end

-- КУЛДАУН ---------------------------------------------------------------

-- Если атака разрешена, фиксирует следующее допустимое время и возвращает true.
-- Время следующей атаки считается от запланированного момента (а не от прихода запроса),
-- поэтому допуск на сетевые задержки не позволяет атаковать быстрее положенного.
-- owner - Player (игрок) либо Model (NPC): кулдаун у каждого свой.
function CombatService:TryStartCooldown(owner, cooldown, now)
    local nextAllowed = NextAttackAt[owner] or 0

    if now < nextAllowed - CombatConfig.CooldownTolerance then
        return false
    end

    NextAttackAt[owner] = math.max(now, nextAllowed) + cooldown

    return true
end

-- ДОСТИЖИМОСТЬ ЦЕЛИ (ПО КОРНЕВОЙ ЧАСТИ) ---------------------------------

-- Чистая геометрия на числах (а не на Vector3), чтобы её было легко тестировать.
-- offset  - вектор от корня атакующего к корню цели;
-- look    - направление взгляда атакующего (достаточно X и Z).
-- Расстояние считается в 3D, направление - в горизонтальной плоскости.
-- Возвращает true либо false, "Distance" | "Direction".
function CombatService.CheckReach(
    offsetX,
    offsetY,
    offsetZ,
    lookX,
    lookZ,
    maxDistance,
    maxAngleDegrees,
    minDirectionDistance
)
    local distance = math.sqrt(
        offsetX * offsetX + offsetY * offsetY + offsetZ * offsetZ
    )

    if distance > maxDistance then
        return false, "Distance"
    end

    local flatDistance = math.sqrt(offsetX * offsetX + offsetZ * offsetZ)
    local flatLook = math.sqrt(lookX * lookX + lookZ * lookZ)

    -- Цель практически вплотную или направление взгляда не определить:
    -- направление не проверяем (иначе вплотную стоящая цель "пропадала бы").
    if flatDistance <= minDirectionDistance or flatLook < 1e-3 then
        return true
    end

    local cosAngle = (offsetX * lookX + offsetZ * lookZ) / (flatDistance * flatLook)

    if cosAngle < math.cos(math.rad(maxAngleDegrees)) then
        return false, "Direction"
    end

    return true
end

-- Проверка расстояния и направления до HumanoidRootPart цели.
-- Область удара (hitbox) находит кандидатов по ЛЮБЫМ частям модели, поэтому у крупных
-- NPC она может зацепить тело, корень которого лежит далеко за пределами досягаемости.
local function IsRootReachable(attackerFrame, targetRoot, weapon)
    local offset = targetRoot.Position - attackerFrame.Position
    local look = attackerFrame.LookVector

    local tolerance = weapon.RootRangeTolerance or CombatConfig.RootRangeTolerance
    local maxAngle = weapon.MaxAttackAngle or CombatConfig.MaxAttackAngle

    return CombatService.CheckReach(
        offset.X,
        offset.Y,
        offset.Z,
        look.X,
        look.Z,
        weapon.AttackRange + tolerance,
        maxAngle,
        CombatConfig.DirectionCheckMinDistance
    )
end

-- ПОИСК ЦЕЛЕЙ -----------------------------------------------------------

-- Поднимается от части модели к ближайшей модели, в которой есть Humanoid.
local function FindHumanoidModel(part)
    local model = part:FindFirstAncestorOfClass("Model")

    while model do
        local humanoid = model:FindFirstChildOfClass("Humanoid")

        if humanoid then
            return model, humanoid
        end

        model = model:FindFirstAncestorOfClass("Model")
    end

    return nil, nil
end

-- attacker - Player, либо nil, если бьёт NPC.
local function IsPvPAllowed(attacker, model)
    local targetPlayer = Players:GetPlayerFromCharacter(model)

    -- NPC бьёт только игроков (не других NPC и манекены); настройка PvP его не касается
    if attacker == nil then
        return targetPlayer ~= nil
    end

    if not targetPlayer then
        return true
    end

    return targetPlayer ~= attacker and CombatConfig.PvPEnabled
end

local function ApplyParry(character, player, target, attackId, weaponId, moveId, feedback)
    PostureService:ReducePosture(target, PostureConfig.Parry.DefenderRecovery, "SuccessfulParry")
    local pressure = PostureService:AddPosture(character, PostureConfig.Parry.AttackerPostureDamage, {
        Source = target, Reason = "Parried", AttackId = attackId,
        WeaponId = weaponId, MoveId = moveId,
    })
    if not pressure.Broke then
        CombatStateService:ApplyStun(character, CombatStateConfig.Stun.ParryDuration, "Parry")
    end

    if player and not pressure.Broke then
        feedback:FireClient(player, {
            Kind = "Reaction",
            Reaction = "Parried",
        })
    elseif not pressure.Broke then
        -- Атакует NPC: реакцию Parried проигрывает его Animator на сервере
        NPCCombatAnimationService:PlayReaction(character, "Parried")
    end
end

-- A released spell retains its original owner and source even if the caster respawns.
function CombatService:ApplyAbilityEffect(context, target, origin)
    local effect = context.Combat
    if target == context.Caster then
        if effect.Restore then
            local humanoid = target:FindFirstChildOfClass("Humanoid")
            if humanoid and humanoid.Health > 0 then
                humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + effect.Damage)
                PostureService:ReducePosture(target, effect.PostureDamage, "SecondWind")
            end
        end
        return
    end
    if not IsPvPAllowed(context.Player, target) then return end
    local outcome = CombatStateService:ApplyDamage(target, effect.Damage, origin, context.Caster, nil, function()
        return PostureService:AddPosture(target, effect.PostureDamage, {
            Source = context.Caster, Reason = "BlockedAbility", MoveId = context.AbilityId,
        }).Broke
    end)
    local feedback = RemoteService:GetEvent("CombatFeedback")
    if outcome.Result == CombatStates.DamageResults.Hit and outcome.Damage > 0 then
        CombatStateService:ApplyStun(target, effect.HitStun, "Ability")
    elseif outcome.Result == CombatStates.DamageResults.Parried then
        if effect.ParryCaster then
            ApplyParry(context.Caster, context.Player, target, context.CastId, context.WeaponId, context.AbilityId, feedback)
        else
            PostureService:ReducePosture(target, PostureConfig.Parry.DefenderRecovery, "SuccessfulParry")
        end
    end
    if outcome.Result == CombatStates.DamageResults.Ignored then return end
    if context.Player and context.Player.Parent == Players then
        feedback:FireClient(context.Player, { Kind = "Hit", Target = target, Result = outcome.Result,
            Damage = outcome.Damage, PostureBroken = outcome.PostureBroken })
    end
    local victim = Players:GetPlayerFromCharacter(target)
    if victim then
        feedback:FireClient(victim, { Kind = "Received", Result = outcome.Result,
            Damage = outcome.Damage, PostureBroken = outcome.PostureBroken })
    end
end

-- Область удара использует серверный root с ограниченным прогнозом XZ-позиции атакующего.
-- Клиент не присылает ни цели, ни координаты.
-- attacker - Player атакующего либо nil, если бьёт NPC (character всё равно передаётся).
-- Кандидат должен пройти по порядку: жив -> корень в пределах дальности и угла ->
-- PvP разрешён.
-- options (необязательно) нужны окну попаданий Active, где область проверяется много раз:
--   Excluded - набор моделей, уже поражённых этим ударом (пропускаются ДО подсчёта лимита);
--   Limit    - сколько целей ещё можно поразить (по умолчанию weapon.MaxTargets).
-- Возвращает (targets, stats):
--   targets - список { Model, Humanoid, Distance }, ближайшие первыми, не больше лимита;
--   stats   - сколько кандидатов найдено и почему часть отсеяна (для отладки).
function CombatService:FindTargets(attacker, character, root, weapon, options)
    local evaded = options and options.Evaded
    local excluded = options and options.Excluded
    local limit = options and options.Limit or weapon.MaxTargets

    local overlapParams = OverlapParams.new()
    overlapParams.FilterType = Enum.RaycastFilterType.Exclude
    overlapParams.FilterDescendantsInstances = { character }

    local boxSize = Vector3.new(
        weapon.HitboxWidth,
        weapon.HitboxHeight or CombatConfig.HitboxHeight,
        weapon.AttackRange
    )

    local origin = HitboxPose.Resolve(character, root, attacker)
    local boxCFrame = origin * CFrame.new(0, 0, -weapon.AttackRange / 2)
    local debugAttackId = options and options.AttackId or CombatStateService:GetAttackId(character)
    UpdateDebugHitbox(character, root, weapon, boxSize, debugAttackId)

    local parts = workspace:GetPartBoundsInBox(boxCFrame, boxSize, overlapParams)

    local stats = { Candidates = 0, Distance = 0, Direction = 0, LeadDistance = (origin.Position - root.Position).Magnitude }
    local seen = {} -- одна модель = одна цель, сколько бы её частей ни попало в область
    local targets = {}

    for _, part in ipairs(parts) do
        local model, humanoid = FindHumanoidModel(part)

        if model and not seen[model] then
            seen[model] = true

            local targetRoot = model:FindFirstChild("HumanoidRootPart")

            if humanoid.Health > 0 and targetRoot and not (excluded and excluded[model])
                and not (evaded and evaded[model]) then
                stats.Candidates += 1

                local reachable, reason = IsRootReachable(origin, targetRoot, weapon)

                if not reachable then
                    stats[reason] += 1
                elseif IsPvPAllowed(attacker, model) then
                    table.insert(targets, {
                        Model = model,
                        Humanoid = humanoid,
                        Distance = (targetRoot.Position - origin.Position).Magnitude,
                    })
                end
            end
        end
    end

    table.sort(targets, function(a, b)
        return a.Distance < b.Distance
    end)

    while #targets > limit do
        table.remove(targets)
    end

    return targets, stats, origin
end

-- АТАКА -----------------------------------------------------------------

-- Окно попаданий. Пока удар находится в фазе Active, область удара проверяется каждые
-- ActiveScanInterval секунд. Каждая цель поражается не более одного раза за удар
-- (учёт ведёт CombatStateService:RegisterHit), а всего за удар не больше MaxTargets.
-- Фазы, прерывание и устаревшие таймеры контролирует CombatStateService: как только удар
-- перестаёт быть активным (оглушение, смерть, конец фазы), цикл завершается.
function CombatService:RunActiveWindow(attack)
    local player = attack.Player -- nil, если бьёт NPC
    local character = attack.Character
    local weapon = attack.Weapon
    local attackId = attack.AttackId

    local ownerName = player and player.Name or character.Name

    -- Compute damage once per swing from the server's profile or the NPC's configured strength.
    local damage
    if player then
        local profile = DataService:GetProfile(player)

        if not profile then
            return
        end

        damage = StatRules.GetPlayerBaseDamage(weapon, profile.Stats.Attributes,
            profile.Proficiencies[attack.WeaponId])
    else
        local strength = type(attack.Strength) == "number" and attack.Strength or GameConstants.BaseStatValue
        damage = self:CalculateDamage(weapon, strength)
    end

    -- Базовый урон считается один раз на удар, в момент начала Active.
    -- Итог для каждой цели (блок, парирование) определяет ApplyDamage.
    local _, moveId = CombatStateService:GetAttackIdentity(character)
    moveId = moveId or "Light1"
    local pressureMove = attack.Move or WeaponComboConfig.GetMove(attack.WeaponId, moveId)
    local move = attack.Move
    if move then
        damage *= move.DamageMultiplier
    end
    local feedback = RemoteService:GetEvent("CombatFeedback")

    local hits = 0
    local scans = 0
    local evaded = moveId == "Heavy" and {} or nil

    while CombatStateService:IsAttackActive(character, attackId) do
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        local root = character:FindFirstChild("HumanoidRootPart")
        local remaining = weapon.MaxTargets - hits

        -- Персонаж погиб или удалён, либо лимит целей исчерпан: окно закрывается
        if character.Parent == nil
            or not humanoid
            or humanoid.Health <= 0
            or not root
            or remaining <= 0
        then
            break
        end

        scans += 1

        local targets, stats, hitboxOrigin = self:FindTargets(player, character, root, weapon, {
            AttackId = attackId,
            Evaded = evaded,
            Excluded = CombatStateService:GetHitTargets(character, attackId),
            Limit = remaining,
        })

        for _, target in ipairs(targets) do
            -- RegisterHit подтверждает, что удар ещё в Active и цель ещё не поражена
            if CombatStateService:IsDodgeInvulnerable(target.Model) then
                -- A successful evasion covers this swing even after the i-frames expire.
                if evaded then evaded[target.Model] = true end
            elseif CombatStateService:RegisterHit(character, attackId, target.Model) then
                hits += 1

                -- Направление блока берётся от позиции атакующего на момент попадания
                local outcome = CombatStateService:ApplyDamage(
                    target.Model,
                    damage,
                    hitboxOrigin.Position,
                    character,
                    attackId,
                    function()
                        if move and move.Standalone then CombatStateService:UseHitRecovery(character, attackId) end
                        if not pressureMove then return false end
                        local pressure = PostureService:AddPosture(target.Model, pressureMove.PostureDamage, {
                            Source = character, Reason = "BlockedAttack", AttackId = attackId,
                            WeaponId = attack.WeaponId, MoveId = moveId,
                        })
                        return pressure.Broke
                    end
                )
                local victim = Players:GetPlayerFromCharacter(target.Model)

                -- Состояние получателя В МОМЕНТ удара (до оглушения от этого удара).
                -- Уходит клиенту: иначе сообщение о Stunned придёт раньше Received, и клиент
                -- решил бы, что получатель уже оглушён, и подавил бы реакцию Hit.
                local victimState = CombatStateService:GetState(target.Model)

                -- Обычное попадание оглушает получателя.
                if outcome.Result == CombatStates.DamageResults.Hit
                    and outcome.Damage > 0
                then
                    CombatStateService:UseHitRecovery(character, attackId)
                    local tracksCombo = CanTrackCombo(attack)
                    if tracksCombo then
                        ComboService:ConfirmHit(character, attackId)
                        if move.Finisher then
                            CombatStateService:ApplyComboRagdoll(target.Model, character, attackId)
                        else
                            CombatStateService:ApplyComboHitStun(
                                target.Model, move.HitStun, character, attackId
                            )
                        end
                    else
                        CombatStateService:ApplyStun(
                            target.Model, move and move.HitStun or weapon.HitStun,
                            moveId == "Heavy" and "HeavyHit" or "Hit"
                        )
                    end

                    if tracksCombo then
                        local _, nextMove = ComboService:GetNextMove(character)
                        CombatStateService:RestrictComboCounterattack(
                            character, attackId, target.Model, nextMove ~= nil
                        )
                    end
                end

                -- Успешное парирование оглушает атакующего.
                -- Визуальная реакция Parried отправляется отдельно и не зависит
                -- от того, является атакующий игроком или NPC.
                if outcome.Result == CombatStates.DamageResults.Parried then
                    if attack.TracksCombo then
                        ComboService:Reset(character, "Parried")
                        attack.TracksCombo = false
                    end

                    ApplyParry(character, player, target.Model, attackId, attack.WeaponId, moveId, feedback)
                end

                -- Damage - фактически нанесённый урон; Result - Hit | Blocked | Parried.
                -- Received отправляется ровно один раз, в том числе когда атакует NPC.
                if outcome.Result ~= CombatStates.DamageResults.Ignored then
                    if player then
                        feedback:FireClient(player, {
                            Kind = "Hit",
                            Target = target.Model,
                            PostureBroken = outcome.PostureBroken,
                            Damage = outcome.Damage,
                            Result = outcome.Result,
                        })
                    end

                    if victim then
                        feedback:FireClient(victim, {
                            Kind = "Received",
                            VictimState = victimState,
                            PostureBroken = outcome.PostureBroken,
                            Damage = outcome.Damage,
                            Result = outcome.Result,
                        })
                    end
                end

            end
        end

        if #targets > 0 or stats.Candidates > 0 then
            Log(
                ownerName,
                "scan",
                scans,
                "| hit",
                #targets,
                "| candidates",
                stats.Candidates,
                "rejected: distance",
                stats.Distance,
                "direction",
                stats.Direction,
                "lead", stats.LeadDistance
            )
        end

        task.wait(CombatConfig.ActiveScanInterval)
    end

    ClearDebugHitbox(character, attackId)
    Log(ownerName, "attack", attackId, "window closed | hits", hits, "| scans", scans)
end

-- Общий запуск удара для игроков и NPC. Урон здесь НЕ наносится: он регистрируется
-- в фазе Active (см. RunActiveWindow). Единый алгоритм для атаки без оружия и с оружием.
-- owner    - Player либо nil (NPC);
-- strength - сила атакующего, нужна только NPC (у игрока берётся из профиля).
-- Возвращает true, <AttackId> либо false, <причина>.
local function GetMoveTiming(weapon, move)
    if not move then
        return weapon.AttackTiming
    end

    return {
        Startup = move.Startup,
        Active = move.Active,
        Recovery = move.RecoveryOnMiss,
        RecoveryOnHit = move.RecoveryOnHit,
        CanBlockDuringRecovery = not move.Standalone and not move.Finisher and weapon.AttackTiming.CanBlockDuringRecovery,
        CanDodgeDuringRecovery = not move.Standalone and not move.Finisher and weapon.AttackTiming.CanDodgeDuringRecovery,
    }
end

-- All entry moves share one active-window record. Continuations replace it only
-- after the state service has successfully issued their new attack identity.
local function RegisterAttack(character, owner, strength, weaponId, weapon, moveId, move, attackId)
    if move and (move.Hitbox or move.MaxTargets) then
        weapon = table.clone(weapon)
        local box = move.Hitbox
        if box then
            weapon.AttackRange *= box.RangeMultiplier
            weapon.HitboxWidth *= box.WidthMultiplier
            weapon.HitboxHeight = CombatConfig.HitboxHeight * (box.HeightMultiplier or 1)
        end
        weapon.MaxTargets = move.MaxTargets or weapon.MaxTargets
    end

    Attacks[character] = {
        AttackId = attackId, Player = owner, Character = character, Strength = strength,
        WeaponId = weaponId, Weapon = weapon, Move = move,
        TracksCombo = owner ~= nil and move ~= nil and not move.Standalone
            and ComboService:BeginSeries(character, weaponId, attackId, move.AlternativeStart and moveId or nil),
    }
end

local function BeginMove(self, character, owner, strength, requestedMove)
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")

    if not humanoid or not root or not character.Parent or humanoid.Health <= 0 then
        return false, "CharacterUnavailable"
    end

    -- Допустимость действия по боевому состоянию (не атакует, не блокирует, не оглушён...).
    -- Сначала состояние: отклонённый запрос не должен расходовать кулдаун.
    local canAttack, stateReason = CombatStateService:CanAttack(character)

    if not canAttack then
        return false, stateReason
    end

    local weaponId, weapon = self:GetWeapon(character)

    local moveId, move
    if requestedMove then
        moveId = requestedMove
        move = WeaponComboConfig.GetMove(weaponId, moveId)
        if not move then return false, "UnknownMove" end
    elseif owner then
        moveId, move = WeaponComboConfig.GetStartMove(weaponId)
    end

    local now = os.clock()
    if move and move.Standalone then
        if now < (NextHeavyAt[character] or 0) then return false, "Cooldown" end
    elseif not self:TryStartCooldown(owner or character, weapon.Cooldown, now) then
        return false, "Cooldown"
    end

    local started, attackId = CombatStateService:StartAttack(character, GetMoveTiming(weapon, move), {
        WeaponId = weaponId, MoveId = moveId,
        ComboIndex = move and move.Index,
        SuperArmor = move and move.SuperArmor,
    })

    if not started then
        warn("[CombatService] Could not start attack:", weaponId, attackId)

        return false, attackId
    end

    if move and move.Standalone then
        NextHeavyAt[character] = now + move.Cooldown
    end
    RegisterAttack(character, owner, strength, weaponId, weapon, moveId, move, attackId)
    Log(owner and owner.Name or character.Name, "attack", attackId, weaponId, moveId or "Light1", "started")

    return true, attackId
end

-- Direct Dodging -> Attacking. CombatStateService owns the independent DashLight cooldown.
function CombatService:BeginDashAttack(player, dashId)
    if not DataService:GetProfile(player) then return false, "NoProfile" end
    local character = player.Character
    local allowed, weaponId = DashService:CanConvertToAttack(character, dashId)
    if not allowed then return false, weaponId end
    local weapon = WeaponRegistry.Get(weaponId)
    local move = WeaponComboConfig.GetMove(weaponId, "DashLight")
    if not weapon or not move then return false, "NoDashLight" end
    local momentum = DashService:GetMomentum(character, dashId, move.Startup)
    local started, attackId = CombatStateService:StartDashAttack(character, GetMoveTiming(weapon, move), {
        WeaponId = weaponId, MoveId = "DashLight", ComboIndex = move.Index, DashMomentum = momentum,
    }, dashId)
    if not started then return false, attackId end
    RegisterAttack(character, player, nil, weaponId, weapon, "DashLight", move, attackId)
    Log(player.Name, "attack", attackId, "DashLight", "converted from dash", dashId)
    return true, attackId
end

function CombatService:RequestDashAttack(player, requestId)
    if not DataService:GetProfile(player) then return false, "NoProfile" end
    return DashService:RequestAttack(player, requestId,
        function(dashId) return self:BeginDashAttack(player, dashId) end,
        function() return self:PerformAttack(player) end)
end

-- Атака игрока по запросу клиента.
function CombatService:PerformAttack(player)
    local profile = DataService:GetProfile(player)

    if not profile then
        return false, "NoProfile"
    end

    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")

    if character and character.Parent and humanoid and humanoid.Health > 0
        and CombatStateService:GetState(character) == CombatStates.Attacking
    then
        local attack = Attacks[character]

        if not attack or attack.Player ~= player
            or attack.AttackId ~= CombatStateService:GetAttackId(character)
            or not CanTrackCombo(attack)
        then
            return false, "NoCombo"
        end

        local buffered, reason = ComboService:BufferAttack(character)
        if buffered then
            Log(player.Name, "attack", attack.AttackId, "combo input buffered")
        end
        return buffered, reason
    end

    return BeginMove(self, character, player)
end

-- Атака NPC (вызывается только сервером, например поведением манекена).
-- Использует тот же путь, что и игрок: проверку состояния, кулдаун, область удара,
-- лимит целей и ApplyDamage. options.Strength - сила NPC (влияет на урон так же, как у игрока).
-- Бить NPC может только по игрокам (см. IsPvPAllowed).
function CombatService:PerformHeavy(player)
    if not DataService:GetProfile(player) then return false, "NoProfile" end
    return BeginMove(self, player.Character, player, nil, "Heavy")
end

local function BeginNPCMove(self, character, moveId, options)
    if typeof(character) ~= "Instance" or not character:IsA("Model") then return false, "InvalidCharacter" end
    if Players:GetPlayerFromCharacter(character) then return false, "NotNPC" end
    return BeginMove(self, character, nil, options and options.Strength, moveId)
end

function CombatService:PerformNPCMove(character, moveId, options)
    if moveId ~= "Heavy" and moveId ~= "Light1" then return false, "UnknownMove" end
    return BeginNPCMove(self, character, moveId, options)
end

function CombatService:PerformNPCAttack(character, options)
    -- Existing NPCs retain the weapon's original light timing and damage.
    return BeginNPCMove(self, character, nil, options)
end

local function ContinueCombo(character, attackId)
    local attack = Attacks[character]
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not attack or attack.AttackId ~= attackId or not character.Parent
        or not humanoid or humanoid.Health <= 0
        or not attack.Player or attack.Player.Character ~= character or not CanTrackCombo(attack)
    then
        return
    end

    local now = os.clock()
    local moveId, move = ComboService:GetContinuation(character, attackId, now)
    if not move then
        return
    end

    local started, nextAttackId = CombatStateService:StartComboAttack(
        character,
        GetMoveTiming(attack.Weapon, move),
        { WeaponId = attack.WeaponId, MoveId = moveId, ComboIndex = move.Index },
        attackId
    )
    if not started then
        return
    end

    ComboService:Advance(character, nextAttackId, attackId, now)
    if attack.Move and attack.Move.ParryInterrupt then
        CombatStateService:OpenComboParryWindow(
            character, nextAttackId, attackId, attack.Move.InterruptWindow
        )
    end
    local nextAttack = table.clone(attack)
    nextAttack.AttackId = nextAttackId
    nextAttack.Move = move
    Attacks[character] = nextAttack
    Log(attack.Player.Name, "attack", nextAttackId, moveId, "continued", attackId)
end

-- СОСТОЯНИЕ И БЛОК (СЕТЬ) -----------------------------------------------

local STATE_REQUEST_ACTIONS = {
    BlockStart = true,
    ComboParry = true,
    Dodge = true,
    DashSteer = true,
    DashEnd = true,
    DashAttack = true,
    BlockEnd = true,
    Sync = true,
}

-- Отправляет игроку его текущее боевое состояние.
local function SendState(player, payload)
    payload.Character = player.Character
    payload.AbilityAnimation = CombatStateService:GetAbilityAnimation(player.Character)
    payload.DodgeAnimation = CombatStateService:GetDodgeAnimationState(player.Character)
    payload.StunAnimation = CombatStateService:GetStunAnimationState(player.Character)
    payload.AttackAnimation = CombatStateService:GetAttackAnimationState(player.Character)
    payload.AttackId, payload.MoveId, payload.ComboIndex =
        CombatStateService:GetAttackIdentity(player.Character)
    RemoteService:GetEvent("CombatStateChanged"):FireClient(player, payload)
end

-- Клиент сообщает только о намерении ("BlockStart" / "BlockEnd" / "Sync").
-- Разрешено ли действие, решает CombatStateService; запрещённые запросы просто отклоняются.
-- Запоздавший или повторный BlockEnd безопасен: StopBlock действует только во время блока.
function CombatService:HandleStateRequest(player, action, direction, requestId)
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")

    if action == "Dodge" then
        local accepted, result = DashService:PerformDodge(player, direction, requestId)
        RemoteService:GetEvent("CombatStateChanged"):FireClient(player, {
            DashReply = {
                RequestId = requestId, Character = character, Accepted = accepted,
                DashId = accepted and result or nil, Reason = not accepted and result or nil,
                Direction = accepted and DashService:GetDirection(character) or nil,
                CooldownRemaining = CombatStateService:GetDodgeCooldownRemaining(character, direction),
            },
        })
        return accepted, result
    end
    if not humanoid or humanoid.Health <= 0 then return false, "CharacterUnavailable" end

    if action == "DashAttack" then
        return self:RequestDashAttack(player, direction)
    elseif action == "DashEnd" then
        return DashService:EndMovement(player, direction)
    elseif action == "DashSteer" then
        return DashService:Steer(player, direction)
    elseif action == "ComboParry" then
        return CombatStateService:TryComboParry(character)
    elseif action == "BlockStart" then
        return CombatStateService:StartBlock(character)
    elseif action == "BlockEnd" then
        return CombatStateService:StopBlock(character)
    end

    -- Sync: клиент запрашивает актуальное состояние (после появления персонажа и т.п.)
    SendState(player, {
        State = CombatStateService:GetState(character),
        Sync = true,
        Phase = CombatStateService:GetAttackPhase(character),
    })

    return true
end



function CombatService:Init()
    -- Ошибка конфигурации должна проявиться при запуске, а не в бою
    WeaponRegistry.Validate()
    HitboxPose.Validate()

    Players.PlayerRemoving:Connect(function(player)
        NextAttackAt[player] = nil
    end)

    -- Фаза Active началась: запускаем окно попаданий этого удара
    CombatStateService:OnAttackPhaseChanged(function(character, phase, attackId)
        if phase ~= CombatStates.AttackPhases.Active then
            ClearDebugHitbox(character, attackId)
            return
        end

        local attack = Attacks[character]

        if attack and attack.AttackId == attackId then
            task.spawn(function()
                self:RunActiveWindow(attack)
            end)
        end
    end)

    CombatStateService:OnAbilityPhaseChanged(function(character, ability)
        local player = Players:GetPlayerFromCharacter(character)
        if player then SendState(player, { State = CombatStates.UsingAbility, Phase = ability.Phase }) end
    end)
    CombatStateService:OnRecoveryFinished(ContinueCombo)
    CombatStateService:OnStunUpdated(function(character)
        local owner = Players:GetPlayerFromCharacter(character)
        if owner and CombatStateService:GetState(character) == CombatStates.Stunned then
            SendState(owner, { State = CombatStates.Stunned })
        end
    end)

    -- Удар закончился (в том числе прерван): данные удара больше не нужны
    CombatStateService:OnStateChanged(function(character, newState, oldState)
        if oldState == CombatStates.Attacking and newState ~= CombatStates.Attacking then
            ClearDebugHitbox(character)
            local attack = Attacks[character]

            if attack and attack.TracksCombo then
                ComboService:Reset(character, "AttackEnded")
            end

            Attacks[character] = nil
        end
    end)

    -- Репликация состояния владельцу персонажа (для интерфейса и анимаций).
    -- Клиент состояние не определяет, а только отображает то, что сообщил сервер.
    CombatStateService:OnStateChanged(function(character, newState, oldState, transitionId)
        local owner = Players:GetPlayerFromCharacter(character)

        if owner then
            SendState(owner, {
                State = newState,
                OldState = oldState,
                Phase = CombatStateService:GetAttackPhase(character),
                TransitionId = transitionId,
            })
        end
    end)

    CombatStateService:OnAttackPhaseChanged(function(character, phase, attackId)
        if CombatStateService:GetAttackId(character) ~= attackId then
            return
        end

        local owner = Players:GetPlayerFromCharacter(character)

        if owner then
            SendState(owner, {
                State = CombatStates.Attacking,
                Phase = phase,
            })
        end
    end)

    -- Блок: клиент присылает только "BlockStart" / "BlockEnd" / "Sync".
    RemoteService:OnEvent("CombatStateRequest", {
        RateLimit = 20,
        Validate = function(action, direction, requestId)
            if not RemoteService.Check.String(action, 16) or not STATE_REQUEST_ACTIONS[action] then return false end
            if action == "DashAttack" then
                return type(direction) == "number" and direction >= 1 and direction <= 2147483646
                    and direction % 1 == 0
            end
            if action == "DashEnd" then
                return type(direction) == "number" and direction > 0 and direction < math.huge
                    and direction % 1 == 0
            end
            if action == "Dodge" then
                return DashService.IsValidDirection(direction) and type(requestId) == "number"
                    and requestId >= 1 and requestId <= 2147483646 and requestId % 1 == 0
            end
            return action ~= "DashSteer" or DashService.IsValidDirection(direction)
        end,
    }, function(player, action, direction, requestId)
        self:HandleStateRequest(player, action, direction, requestId)
    end)

    -- Клиент присылает только команду "Attack": без урона, целей и координат.
    -- RemoteService добавляет лимит частоты и проверку аргументов.
    RemoteService:OnEvent("CombatRequest", {
        RateLimit = 15,
        Validate = function(action, ...)
            return select("#", ...) == 0 and (action == "Attack" or action == "Heavy")
        end,
    }, function(player, action)
        if action == "Heavy" then self:PerformHeavy(player) else self:PerformAttack(player) end
    end)

    print("[CombatService] Initialized")
end


return CombatService
