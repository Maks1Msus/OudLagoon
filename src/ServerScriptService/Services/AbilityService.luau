local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage").Shared
local Config = require(Shared.Config.AbilityConfig)
local Registry = require(Shared.Abilities.AbilityRegistry)
local StatRules = require(Shared.Progression.StatRules)
local State = require(script.Parent.CombatStateService)
local Combat = require(script.Parent.CombatService)
local Targeting = require(script.Parent.TargetingService)
local Remote = require(script.Parent.RemoteService)
local Data = require(script.Parent.DataService)
local Profiles = require(script.Parent.PlayerService)
local Service = {}
local casts = setmetatable({}, { __mode = "k" })
local cooldowns = setmetatable({}, { __mode = "k" })

local function reply(player, character, kind, text, id, abilityId)
    if player and player.Character == character then
        Remote:GetEvent("AbilityResult"):FireClient(player, character, kind, text, id, abilityId)
    end
end

local function direction(session)
    local now = os.clock()
    session.Direction = Targeting.Turn(session.Direction, session.Goal, (now - session.Time) * Config.AimRadiansPerSecond)
    session.Time = now
    return session.Direction
end

function Service:SetAim(character, id, aim)
    local s = casts[character]
    local ability = character and State:GetAbility(character)
    if not s or not ability or ability.CastId ~= id or ability.Phase ~= "Startup"
        or not Targeting.ValidDirection(aim) then return end
    direction(s)
    s.Goal = aim.Unit
end

-- Server-only entry for registered physical abilities and runtime spell definitions.
-- commit and afterRelease are synchronous. Released effects own their own lifetimes.
function Service:Start(character, definition, aim, commit, afterRelease)
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid or humanoid.Health <= 0 or not character:IsDescendantOf(workspace) then
        return false, "Character unavailable"
    end
    if not Targeting.ValidDirection(aim) then return false, "Invalid aim" end
    if State:GetState(character) ~= "Idle" then return false, "Finish the current action" end
    local player = Players:GetPlayerFromCharacter(character)
    local profile = player and Data:GetProfile(player)
    if player and not profile then return false, "Profile unavailable" end
    local weaponId, weapon = Combat:GetWeapon(character)
    if definition.Weapon and definition.Weapon ~= weaponId then return false, "Equip " .. definition.Weapon end
    local times = cooldowns[character]
    if times and (times[definition.Id] or 0) > os.clock() then return false, "Ability on cooldown" end
    local s = { Direction = root.CFrame.LookVector, Goal = aim.Unit, Time = os.clock(), Definition = definition, Player = player }
    local function release(id)
        if casts[character] ~= s or (player and (player.Character ~= character or Data:GetProfile(player) ~= profile))
            or (definition.Weapon and Combat:GetWeapon(character) ~= definition.Weapon) then return false end
        local plan = Targeting.Prepare(character, definition.Targeting, direction(s))
        if not plan then s.Error = "No ground in range" return false end
        local effect = table.clone(definition.Combat)
        if effect.DamageMultiplier then
            local base = profile and StatRules.GetPlayerBaseDamage(weapon, profile.Stats.Attributes, profile.Proficiencies[weaponId])
                or Combat:CalculateDamage(weapon, character:GetAttribute("Strength") or 10)
            effect.Damage = math.round(base * effect.DamageMultiplier)
        end
        if commit then
            local paid, reason = commit()
            if not paid then s.Error = reason return false end
        end
        s.Released = true
        reply(player, character, "Released", definition.Name, id)
        Targeting.Release({ Caster = character, Player = player, WeaponId = weaponId, CastId = id,
            AbilityId = definition.Id, Color = definition.Color, Targeting = definition.Targeting, Combat = effect,
            StillCasting = function() return casts[character] == s end }, plan)
        if afterRelease then afterRelease() end
        return true
    end
    local ok, id = State:StartAbility(character, definition, release)
    if not ok then return false, id end
    casts[character] = s
    s.Id = id
    local function cancelOnRemoval()
        if casts[character] == s then State:SetDead(character) end
    end
    s.Death = humanoid.Died:Connect(cancelOnRemoval)
    s.Removal = character.AncestryChanged:Connect(function()
        if not character:IsDescendantOf(workspace) then cancelOnRemoval() end
    end)
    reply(player, character, "Started", definition.Name, id, definition.Id)
    return true, id
end

function Service:Use(character, abilityId, aim)
    local definition = Registry[abilityId]
    if not definition then return false, "Empty ability slot" end
    return self:Start(character, definition, aim)
end

local function publish(character, ability)
    character:SetAttribute("AbilityId", ability and ability.AbilityId)
    character:SetAttribute("AbilityCastId", ability and ability.CastId)
    character:SetAttribute("AbilityPhase", ability and ability.Phase)
    character:SetAttribute("AbilityPhaseEndsAt", ability and ability.PhaseEndsAt)
end

function Service:Init()
    State:OnAbilityPhaseChanged(publish)
    State:OnStateChanged(function(character, state, previous)
        if state == "UsingAbility" then
            publish(character, State:GetAbility(character))
        elseif previous == "UsingAbility" then
            publish(character, nil)
            local s = casts[character]
            casts[character] = nil
            if not s then return end
            s.Death:Disconnect()
            s.Removal:Disconnect()
            if not s.Released then reply(s.Player, character, "Interrupted", s.Error or "Cast interrupted", s.Id) end
            local cooldown = s.Definition.Cooldown
            if cooldown then
                cooldowns[character] = cooldowns[character] or {}
                cooldowns[character][s.Definition.Id] = os.clock() + cooldown
                character:SetAttribute("Cooldown_" .. s.Definition.Id, workspace:GetServerTimeNow() + cooldown)
            end
        end
    end)
    Remote:OnEvent("AbilityRequest", {
        RateLimit = 20,
        Validate = function(action, value, arg, ...)
            if select("#", ...) ~= 0 then return false end
            if action == "Bind" then return type(value) == "string" and type(arg) == "string" and #arg <= 12 end
            if not Targeting.ValidDirection(arg) then return false end
            return (action == "Aim" and type(value) == "number")
                or (action == "Slot" and type(value) == "string" and Config.DefaultSlots[value] ~= nil)
        end,
    }, function(player, action, value, arg)
        local profile = Data:GetProfile(player)
        local character = player.Character
        if not profile or not character then return end
        if action == "Aim" then self:SetAim(character, value, arg) return end
        if action == "Bind" then
            if Config.CanBind(profile.Loadout.Bindings, value, arg) then
                profile.Loadout.Bindings[value] = arg
                Profiles:PushProfile(player)
            else reply(player, character, "Error", "Key reserved or already assigned") end
            return
        end
        local ok, reason = self:Use(character, profile.Loadout.Abilities[value], arg)
        if not ok then reply(player, character, "Error", reason) end
    end)
end
return Service
