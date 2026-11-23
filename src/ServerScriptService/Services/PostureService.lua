local Shared = game:GetService("ReplicatedStorage").Shared
local RunService = game:GetService("RunService")
local Config = require(Shared.Config.PostureConfig)
local Constants = require(Shared.Constants.GameConstants)
local Stun = require(Shared.Config.CombatStateConfig).Stun
local State = require(script.Parent.CombatStateService)

local Service = {}
local records = setmetatable({}, { __mode = "k" })
local changed = Instance.new("BindableEvent")
local broken = Instance.new("BindableEvent")
local initialized = false

local function finite(n)
    return type(n) == "number" and n == n and math.abs(n) < math.huge
end

local function publish(character, record, reason)
    record.Revision += 1
    character:SetAttribute("CombatMaxPosture", record.Max)
    character:SetAttribute("CombatPosture", record.Value)
    changed:Fire(character, record.Value, record.Max, reason, record.Revision)
end

function Service:OnChanged(callback)
    return changed.Event:Connect(callback)
end

function Service:OnBroken(callback)
    return broken.Event:Connect(callback)
end

function Service:RegisterCharacter(character, options)
    if records[character] then return end
    options = options or {}
    local maximum = options.Max or Constants.DefaultPosture
    local rate = options.RecoveryPerSecond or Config.Recovery.BasePerSecond
    assert(finite(maximum) and maximum > 0 and finite(rate) and rate >= 0, "Invalid posture parameters")
    local humanoid = assert(character:FindFirstChildOfClass("Humanoid"), "Missing Humanoid")
    local record = {
        Value = 0, Max = maximum, RecoveryPerSecond = rate, LastPressureAt = 0,
        BreakImmunityUntil = 0, Revision = 0, Infinite = options.Infinite == true, Humanoid = humanoid,
    }
    records[character] = record
    record.Destroying = character.Destroying:Connect(function() self:UnregisterCharacter(character) end)
    record.Died = humanoid.Died:Connect(function() self:ResetPosture(character, "Death") end)
    publish(character, record, "Spawn")
end

function Service:UnregisterCharacter(character)
    local r = records[character]
    if not r then return end
    records[character] = nil
    r.Destroying:Disconnect()
    r.Died:Disconnect()
    character:SetAttribute("CombatPosture", nil)
    character:SetAttribute("CombatMaxPosture", nil)
end

function Service:Configure(character, maximum, rate)
    assert(finite(maximum) and maximum > 0 and finite(rate) and rate >= 0, "Invalid posture parameters")
    local r = records[character]
    if not r then
        self:RegisterCharacter(character, { Max = maximum, RecoveryPerSecond = rate })
        return
    end
    r.Max, r.RecoveryPerSecond = maximum, rate
    r.Value = math.min(r.Value, maximum)
    publish(character, r, "Configure")
end

function Service:GetPosture(character)
    local r = records[character]
    return r and r.Value or 0
end

function Service:GetMaxPosture(character)
    local r = records[character]
    return r and r.Max or 0
end

function Service:GetRatio(character)
    local r = records[character]
    return r and r.Value / r.Max or 0
end

function Service:ReducePosture(character, amount, reason)
    local r = records[character]
    if not r or not finite(amount) or amount <= 0 or r.Value == 0 then return 0 end
    local removed = math.min(r.Value, amount)
    r.Value -= removed
    publish(character, r, reason)
    return removed
end

function Service:ResetPosture(character, reason)
    local r = records[character]
    if not r then return end
    r.LastPressureAt, r.BreakImmunityUntil = 0, 0
    self:ReducePosture(character, r.Value, reason)
end

function Service:AddPosture(character, amount, context)
    local r = records[character]
    local previous = self:GetPosture(character)
    local result = { Previous = previous, Applied = 0, Current = previous,
        Maximum = self:GetMaxPosture(character), Broke = false }
    if not r or not finite(amount) or amount <= 0 or r.Infinite or not character.Parent
        or r.Humanoid.Health <= 0 then return result end
    local state = State:GetState(character)
    local now = os.clock()
    if state == "Stunned" or state == "Ragdolled" or state == "Dead" or now < r.BreakImmunityUntil then
        return result
    end
    local nextValue = previous + amount
    if nextValue >= r.Max then
        local immunity = r.BreakImmunityUntil
        r.BreakImmunityUntil = now + Stun.PostureBreakDuration + Config.Break.ImmunityDuration
        if not State:ApplyStun(character, Stun.PostureBreakDuration, "PostureBreak") then
            r.BreakImmunityUntil = immunity
            return result
        end
        result.Broke = true
        nextValue = Config.Break.ResetValue
    end
    r.LastPressureAt = now
    result.Applied, result.Current = amount, nextValue
    r.Value = nextValue
    publish(character, r, context and context.Reason)
    if result.Broke then broken:Fire(character, context, result) end
    return result
end

function Service:Init()
    if initialized then return end
    initialized = true
    State:OnStateChanged(function(character, state)
        if state == "Dead" then self:ResetPosture(character, "Death") end
        local r = records[character]
        if r then r.IdleSince = state == "Idle" and os.clock() or nil end
    end)
    local elapsed = 0
    RunService.Heartbeat:Connect(function(dt)
        elapsed += dt
        if elapsed < Config.Recovery.TickInterval then return end
        local now, step = os.clock(), elapsed
        elapsed = 0
        for character, r in pairs(records) do
            if r.Value > 0 and r.Humanoid.Health > 0 and Config.Recovery.AllowedStates[State:GetState(character)] then
                local start = math.max(now - step, r.LastPressureAt + Config.Recovery.Delay, r.IdleSince or 0)
                self:ReducePosture(character, r.RecoveryPerSecond * (now - start), "Recovery")
            end
        end
    end)
end

return Service
