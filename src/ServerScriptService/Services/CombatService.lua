local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(
    ReplicatedStorage.Shared.Config.CombatConfig
)

local GameConstants = require(
    ReplicatedStorage.Shared.Constants.GameConstants
)

local CombatStates = require(
    ReplicatedStorage.Shared.Constants.CombatStates
)

local DataService = require(script.Parent.DataService)
local RemoteService = require(script.Parent.RemoteService)
local CombatStateService = require(script.Parent.CombatStateService)

local CombatService = {}

-- [player] = момент времени (os.clock), раньше которого следующая атака запрещена
local NextAttackAt = {}

-- [character] = данные текущего удара, пока он не завершился:
-- { AttackId, Player, Character, WeaponId, Weapon }
local Attacks = setmetatable({}, { __mode = "k" })

local function Log(...)
    if CombatConfig.DebugLogging then
        print("[CombatService]", ...)
    end
end

-- ОРУЖИЕ ----------------------------------------------------------------

-- Оружие определяется сервером по экипированному Tool с атрибутом CombatWeaponId.
-- Неизвестный или отсутствующий id означает бой без оружия.
function CombatService:GetWeapon(character)
    local tool = character:FindFirstChildOfClass("Tool")

    if tool then
        local weaponId = tool:GetAttribute(CombatConfig.WeaponAttribute)
        local weapon = type(weaponId) == "string" and CombatConfig.Weapons[weaponId]

        if weapon then
            return weaponId, weapon
        end
    end

    return CombatConfig.UnarmedId, CombatConfig.Weapons[CombatConfig.UnarmedId]
end

-- УРОН ------------------------------------------------------------------

-- Damage = BaseDamage + Strength * Scaling (округляется, минимум 1).
-- Округление защищает от ошибок чисел с плавающей точкой (22.9999 вместо 23).
function CombatService:CalculateDamage(weapon, strength)
    local damage = weapon.BaseDamage + strength * weapon.Scaling

    return math.max(1, math.floor(damage + 0.5))
end

-- КУЛДАУН ---------------------------------------------------------------

-- Если атака разрешена, фиксирует следующее допустимое время и возвращает true.
-- Время следующей атаки считается от запланированного момента (а не от прихода запроса),
-- поэтому допуск на сетевые задержки не позволяет атаковать быстрее положенного.
function CombatService:TryStartCooldown(player, cooldown, now)
    local nextAllowed = NextAttackAt[player] or 0

    if now < nextAllowed - CombatConfig.CooldownTolerance then
        return false
    end

    NextAttackAt[player] = math.max(now, nextAllowed) + cooldown

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
local function IsRootReachable(attackerRoot, targetRoot, weapon)
    local offset = targetRoot.Position - attackerRoot.Position
    local look = attackerRoot.CFrame.LookVector

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

local function IsPvPAllowed(attacker, model)
    local targetPlayer = Players:GetPlayerFromCharacter(model)

    if not targetPlayer then
        return true
    end

    return targetPlayer ~= attacker and CombatConfig.PvPEnabled
end

-- Область удара определяется сервером по положению и направлению персонажа.
-- Клиент не присылает ни цели, ни координаты.
-- Кандидат должен пройти по порядку: жив -> корень в пределах дальности и угла ->
-- PvP разрешён.
-- options (необязательно) нужны окну попаданий Active, где область проверяется много раз:
--   Excluded - набор моделей, уже поражённых этим ударом (пропускаются ДО подсчёта лимита);
--   Limit    - сколько целей ещё можно поразить (по умолчанию weapon.MaxTargets).
-- Возвращает (targets, stats):
--   targets - список { Model, Humanoid, Distance }, ближайшие первыми, не больше лимита;
--   stats   - сколько кандидатов найдено и почему часть отсеяна (для отладки).
function CombatService:FindTargets(attacker, character, root, weapon, options)
    local excluded = options and options.Excluded
    local limit = options and options.Limit or weapon.MaxTargets

    local overlapParams = OverlapParams.new()
    overlapParams.FilterType = Enum.RaycastFilterType.Exclude
    overlapParams.FilterDescendantsInstances = { character }

    local boxSize = Vector3.new(
        weapon.HitboxWidth,
        CombatConfig.HitboxHeight,
        weapon.AttackRange
    )

    local boxCFrame = root.CFrame * CFrame.new(0, 0, -weapon.AttackRange / 2)

    local parts = workspace:GetPartBoundsInBox(boxCFrame, boxSize, overlapParams)

    local stats = { Candidates = 0, Distance = 0, Direction = 0 }
    local seen = {} -- одна модель = одна цель, сколько бы её частей ни попало в область
    local targets = {}

    for _, part in ipairs(parts) do
        local model, humanoid = FindHumanoidModel(part)

        if model and not seen[model] then
            seen[model] = true

            local targetRoot = model:FindFirstChild("HumanoidRootPart")

            if humanoid.Health > 0 and targetRoot and not (excluded and excluded[model]) then
                stats.Candidates += 1

                local reachable, reason = IsRootReachable(root, targetRoot, weapon)

                if not reachable then
                    stats[reason] += 1
                elseif IsPvPAllowed(attacker, model) then
                    table.insert(targets, {
                        Model = model,
                        Humanoid = humanoid,
                        Distance = (targetRoot.Position - root.Position).Magnitude,
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

    return targets, stats
end

-- АТАКА -----------------------------------------------------------------

-- Окно попаданий. Пока удар находится в фазе Active, область удара проверяется каждые
-- ActiveScanInterval секунд. Каждая цель поражается не более одного раза за удар
-- (учёт ведёт CombatStateService:RegisterHit), а всего за удар не больше MaxTargets.
-- Фазы, прерывание и устаревшие таймеры контролирует CombatStateService: как только удар
-- перестаёт быть активным (оглушение, смерть, конец фазы), цикл завершается.
function CombatService:RunActiveWindow(attack)
    local player = attack.Player
    local character = attack.Character
    local weapon = attack.Weapon
    local attackId = attack.AttackId

    local profile = DataService:GetProfile(player)

    if not profile then
        return
    end

    local strength = profile.Stats.Strength

    if type(strength) ~= "number" then
        strength = GameConstants.BaseStatValue
    end

    -- Базовый урон считается один раз на удар, в момент начала Active.
    -- Итог для каждой цели (блок, парирование) определяет ApplyDamage.
    local damage = self:CalculateDamage(weapon, strength)
    local feedback = RemoteService:GetEvent("CombatFeedback")

    local hits = 0
    local scans = 0

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

        local targets, stats = self:FindTargets(player, character, root, weapon, {
            Excluded = CombatStateService:GetHitTargets(character, attackId),
            Limit = remaining,
        })

        for _, target in ipairs(targets) do
            -- RegisterHit подтверждает, что удар ещё в Active и цель ещё не поражена
            if CombatStateService:RegisterHit(character, attackId, target.Model) then
                hits += 1

                -- Направление блока берётся от позиции атакующего на момент попадания
                local outcome = CombatStateService:ApplyDamage(
                    target.Model,
                    damage,
                    root.Position
                )

                -- Подтверждение попадания только атакующему (числа урона, эффекты).
                -- Damage - сколько урона реально нанесено, Result - Hit | Blocked | Parried.
                if outcome.Result ~= CombatStates.DamageResults.Ignored then
                    feedback:FireClient(player, {
                        Kind = "Hit",
                        Target = target.Model,
                        Damage = outcome.Damage,
                        Result = outcome.Result,
                    })
                end
            end
        end

        if #targets > 0 or stats.Candidates > 0 then
            Log(
                player.Name,
                "scan",
                scans,
                "| hit",
                #targets,
                "| candidates",
                stats.Candidates,
                "rejected: distance",
                stats.Distance,
                "direction",
                stats.Direction
            )
        end

        task.wait(CombatConfig.ActiveScanInterval)
    end

    Log(player.Name, "attack", attackId, "window closed | hits", hits, "| scans", scans)
end

-- Запускает удар. Урон здесь НЕ наносится: он регистрируется в фазе Active
-- (см. RunActiveWindow). Единый алгоритм для атаки без оружия и с оружием.
-- Возвращает true, <AttackId> либо false, <причина>.
function CombatService:PerformAttack(player)
    local profile = DataService:GetProfile(player)

    if not profile then
        return false, "NoProfile"
    end

    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")

    if not humanoid or not root or humanoid.Health <= 0 then
        return false, "CharacterUnavailable"
    end

    -- Допустимость действия по боевому состоянию (не атакует, не блокирует, не оглушён...).
    -- Сначала состояние: отклонённый запрос не должен расходовать кулдаун.
    local canAttack, stateReason = CombatStateService:CanAttack(character)

    if not canAttack then
        return false, stateReason
    end

    local weaponId, weapon = self:GetWeapon(character)

    -- Кулдаун оружия не зависит от длительности самого удара
    if not self:TryStartCooldown(player, weapon.Cooldown, os.clock()) then
        return false, "Cooldown"
    end

    local started, attackId = CombatStateService:StartAttack(character, weapon.AttackTiming)

    if not started then
        warn("[CombatService] Could not start attack:", weaponId, attackId)

        return false, attackId
    end

    Attacks[character] = {
        AttackId = attackId,
        Player = player,
        Character = character,
        WeaponId = weaponId,
        Weapon = weapon,
    }

    Log(player.Name, "attack", attackId, weaponId, "started")

    return true, attackId
end

-- СОСТОЯНИЕ И БЛОК (СЕТЬ) -----------------------------------------------

local STATE_REQUEST_ACTIONS = {
    BlockStart = true,
    BlockEnd = true,
    Sync = true,
}

-- Отправляет игроку его текущее боевое состояние.
local function SendState(player, payload)
    RemoteService:GetEvent("CombatStateChanged"):FireClient(player, payload)
end

-- Клиент сообщает только о намерении ("BlockStart" / "BlockEnd" / "Sync").
-- Разрешено ли действие, решает CombatStateService; запрещённые запросы просто отклоняются.
-- Запоздавший или повторный BlockEnd безопасен: StopBlock действует только во время блока.
function CombatService:HandleStateRequest(player, action)
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")

    if not humanoid or humanoid.Health <= 0 then
        return false, "CharacterUnavailable"
    end

    if action == "BlockStart" then
        return CombatStateService:StartBlock(character)
    elseif action == "BlockEnd" then
        return CombatStateService:StopBlock(character)
    end

    -- Sync: клиент запрашивает актуальное состояние (после появления персонажа и т.п.)
    SendState(player, {
        State = CombatStateService:GetState(character),
        Phase = CombatStateService:GetAttackPhase(character),
    })

    return true
end

function CombatService:Init()
    -- Ошибка конфигурации должна проявиться при запуске, а не в бою
    for weaponId, weapon in pairs(CombatConfig.Weapons) do
        assert(
            type(weapon.AttackTiming) == "table",
            "[CombatService] Weapon '" .. tostring(weaponId) .. "' has no AttackTiming"
        )
    end

    Players.PlayerRemoving:Connect(function(player)
        NextAttackAt[player] = nil
    end)

    -- Фаза Active началась: запускаем окно попаданий этого удара
    CombatStateService:OnAttackPhaseChanged(function(character, phase, attackId)
        if phase ~= CombatStates.AttackPhases.Active then
            return
        end

        local attack = Attacks[character]

        if attack and attack.AttackId == attackId then
            task.spawn(function()
                self:RunActiveWindow(attack)
            end)
        end
    end)

    -- Удар закончился (в том числе прерван): данные удара больше не нужны
    CombatStateService:OnStateChanged(function(character, _newState, oldState)
        if oldState == CombatStates.Attacking then
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

    CombatStateService:OnAttackPhaseChanged(function(character, phase)
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
        Validate = function(action)
            return RemoteService.Check.String(action, 16)
                and STATE_REQUEST_ACTIONS[action] == true
        end,
    }, function(player, action)
        self:HandleStateRequest(player, action)
    end)

    -- Клиент присылает только команду "Attack": без урона, целей и координат.
    -- RemoteService добавляет лимит частоты и проверку аргументов.
    RemoteService:OnEvent("CombatRequest", {
        RateLimit = 10,
        Validate = function(action)
            return action == "Attack"
        end,
    }, function(player)
        self:PerformAttack(player)
    end)

    print("[CombatService] Initialized")
end

return CombatService