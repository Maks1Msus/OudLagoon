-- Applies movement restrictions from CombatStateService; owns no combat state.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CombatStateService = require(script.Parent.CombatStateService)
local Config = require(ReplicatedStorage.Shared.Config.CombatStateConfig).Movement

local CombatMovementService = {}
local Records = setmetatable({}, { __mode = "k" })
local initialized = false
local Jumping = Enum.HumanoidStateType.Jumping

local function ClearRecord(humanoid, restore)
    local record = Records[humanoid]
    if not record then
        return
    end
    Records[humanoid] = nil
    for _, connection in ipairs(record.Connections) do
        connection:Disconnect()
    end
    if restore then
        humanoid.JumpPower = record.JumpPower
        humanoid.JumpHeight = record.JumpHeight
        humanoid:SetStateEnabled(Jumping, record.JumpEnabled)
    end
end

local function RestrictJump(humanoid)
    local record = Records[humanoid]
    if not record then
        record = {
            JumpPower = humanoid.JumpPower,
            JumpHeight = humanoid.JumpHeight,
            JumpEnabled = humanoid:GetStateEnabled(Jumping),
            Connections = {},
        }
        Records[humanoid] = record
        for _, property in ipairs({ "JumpPower", "JumpHeight" }) do
            table.insert(record.Connections, humanoid:GetPropertyChangedSignal(property):Connect(function()
                -- Own zero writes are ignored, including deferred property signals.
                if Records[humanoid] == record and humanoid[property] ~= 0 then
                    record[property] = humanoid[property]
                    humanoid[property] = 0
                end
            end))
        end
        table.insert(record.Connections, humanoid.Destroying:Connect(function()
            ClearRecord(humanoid, false)
        end))
    end
    humanoid.JumpPower = 0
    humanoid.JumpHeight = 0
    humanoid.Jump = false
    humanoid:SetStateEnabled(Jumping, false)
end

local function Apply(character, state)
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        return
    end

    local baseSpeed = humanoid:GetAttribute(Config.BaseSpeedAttribute)
    if type(baseSpeed) ~= "number" then
        baseSpeed = humanoid.WalkSpeed
        humanoid:SetAttribute(Config.BaseSpeedAttribute, baseSpeed)
    end
    local restriction = Config.States[state]
    humanoid:SetAttribute(Config.StateAttribute, state)
    humanoid.WalkSpeed = baseSpeed * (restriction and restriction.WalkSpeedMultiplier or 1)

    if restriction and not restriction.CanJump then
        RestrictJump(humanoid)
    else
        ClearRecord(humanoid, true)
    end
end

function CombatMovementService:SetBaseWalkSpeed(humanoid, speed)
    assert(type(speed) == "number" and speed == speed and speed >= 0 and speed < math.huge,
        "Base walk speed must be a finite non-negative number")
    humanoid:SetAttribute(Config.BaseSpeedAttribute, speed)
    local character = humanoid.Parent
    if character then
        Apply(character, CombatStateService:GetState(character))
    else
        humanoid.WalkSpeed = speed
    end
end

function CombatMovementService:Init()
    if initialized then
        return
    end
    initialized = true
    for state, restriction in pairs(Config.States) do
        local multiplier = restriction.WalkSpeedMultiplier
        assert(type(multiplier) == "number" and multiplier == multiplier
            and multiplier >= 0 and multiplier < math.huge,
            "Invalid movement multiplier for " .. state)
    end

    CombatStateService:OnStateChanged(function(character, state)
        Apply(character, state)
    end)
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character then
            Apply(player.Character, CombatStateService:GetState(player.Character))
        end
    end
end

return CombatMovementService
