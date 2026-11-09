local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(
    ReplicatedStorage.Shared.Config.CombatConfig
)

local GameConstants = require(
    ReplicatedStorage.Shared.Constants.GameConstants
)

local DataService = require(script.Parent.DataService)
local RemoteService = require(script.Parent.RemoteService)

local CombatService = {}

-- [player] = момент времени (os.clock), раньше которого следующая атака запрещена
local NextAttackAt = {}

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
-- Возвращает (targets, stats):
--   targets - список { Model, Humanoid, Distance }, ближайшие первыми, не больше MaxTargets;
--   stats   - сколько кандидатов найдено и почему часть отсеяна (для отладки).
function CombatService:FindTargets(attacker, character, root, weapon)
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

            if humanoid.Health > 0 and targetRoot then
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

    while #targets > weapon.MaxTargets do
        table.remove(targets)
    end

    return targets, stats
end

-- АТАКА -----------------------------------------------------------------

-- Единый алгоритм для атаки без оружия и с оружием.
-- Возвращает true, <число пораженных целей> либо false, <причина>.
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

    local weaponId, weapon = self:GetWeapon(character)

    if not self:TryStartCooldown(player, weapon.Cooldown, os.clock()) then
        return false, "Cooldown"
    end

    local strength = profile.Stats.Strength

    if type(strength) ~= "number" then
        strength = GameConstants.BaseStatValue
    end

    local damage = self:CalculateDamage(weapon, strength)
    local targets, stats = self:FindTargets(player, character, root, weapon)

    local feedback = RemoteService:GetEvent("CombatFeedback")

    for _, target in ipairs(targets) do
        target.Humanoid:TakeDamage(damage)

        -- Подтверждение попадания только атакующему (числа урона, эффекты)
        feedback:FireClient(player, {
            Kind = "Hit",
            Target = target.Model,
            Damage = damage,
        })
    end

    Log(
        player.Name,
        "attack",
        weaponId,
        "damage",
        damage,
        "| hit",
        #targets,
        "| candidates",
        stats.Candidates,
        "rejected: distance",
        stats.Distance,
        "direction",
        stats.Direction
    )

    return true, #targets
end

function CombatService:Init()
    Players.PlayerRemoving:Connect(function(player)
        NextAttackAt[player] = nil
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