local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Config = require(game:GetService("ReplicatedStorage").Shared.Config.MagicConfig)
local State = require(script.Parent.CombatStateService)
local Gate = {}
local records = setmetatable({}, { __mode = "k" })

function Gate:Register(character, stability)
    local record = records[character]
    if record then
        record.Stability = stability
        return record
    end
    record = { Wear = 0, Stability = stability, LastCast = -math.huge, LockedUntil = 0, Overloaded = false }
    records[character] = record
    local function forget()
        records[character] = nil
        record.Ancestry:Disconnect()
        record.Destroying:Disconnect()
    end
    record.Ancestry = character.AncestryChanged:Connect(function()
        if not character:IsDescendantOf(workspace) then forget() end
    end)
    record.Destroying = character.Destroying:Connect(forget)
    character:SetAttribute("GateWear", 0)
    character:SetAttribute("GateOverloaded", false)
    return record
end

function Gate:Charge(character, wear)
    local r = records[character]
    local gate = Config.Gate
    r.LastCast = os.clock()
    r.Wear = math.min(gate.Max, r.Wear + wear)
    r.Overloaded = r.Wear >= gate.Max
    if r.Overloaded then
        r.LockedUntil = r.LastCast + gate.LockDuration / math.clamp(r.Stability / gate.Stability, 0.75, 1.5)
    end
    character:SetAttribute("GateWear", math.ceil(r.Wear))
    character:SetAttribute("GateOverloaded", r.Overloaded)
    return r.Overloaded
end

function Gate:Step(dt, now)
    local gate = Config.Gate
    for character, r in pairs(records) do
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid and humanoid.Health > 0 then
            local dtWear = math.clamp(now - r.LastCast - gate.Delay, 0, dt)
            if r.Wear > 0 and dtWear > 0 then
                local rate = gate.Recovery * math.clamp(r.Stability / gate.Stability, 0.75, 1.5)
                r.Wear = math.max(0, r.Wear - rate * (r.Overloaded and gate.OverloadRecoveryScale or 1) * dtWear)
                character:SetAttribute("GateWear", math.ceil(r.Wear))
                if r.Overloaded and now >= r.LockedUntil and r.Wear <= gate.UnlockWear then
                    r.Overloaded = false
                    character:SetAttribute("GateOverloaded", false)
                end
            end
            local dtMana = math.clamp(now - r.LastCast - Config.ManaDelay, 0, dt)
            if dtMana > 0 and State:GetState(character) == "Idle" then
                local holder = Players:GetPlayerFromCharacter(character) or character
                local current, maximum = holder:GetAttribute("Mana"), holder:GetAttribute("MaxMana")
                if current and maximum and current < maximum then
                    holder:SetAttribute("Mana", math.min(maximum, current + Config.ManaRecovery * dtMana))
                end
            end
        end
    end
end

function Gate:Init()
    local elapsed = 0
    RunService.Heartbeat:Connect(function(dt)
        elapsed += dt
        if elapsed >= 0.2 then
            self:Step(elapsed, os.clock())
            elapsed = 0
        end
    end)
end
return Gate
