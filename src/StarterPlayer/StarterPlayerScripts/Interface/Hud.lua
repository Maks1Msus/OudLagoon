local PostureUI = require(game:GetService("ReplicatedStorage").Shared.Config.PostureConfig).UI
local Theme = require(script.Parent.Theme)
local Colors = Theme.Colors
local px = UDim2.fromOffset
local Hud = {}

local function createMeter(parent, name, y, color)
    local track = Theme.frame(parent, name, px(0, y), px(232, 20), Colors.Surface)
    local fill = Theme.frame(track, "Fill", px(0, 0), UDim2.fromScale(0, 1), color)
    local label = Theme.label(track, "Value", "", px(8, 0), px(216, 20), 12)
    label.TextColor3 = Colors.Text
    label.ZIndex = 2
    Theme.outline(track)

    return function(current, maximum)
        local ratio = maximum > 0 and math.clamp(current / maximum, 0, 1) or 0
        if name == "Posture" then
            fill.BackgroundColor3 = ratio >= PostureUI.CriticalThreshold and Colors.Health
                or ratio >= PostureUI.HighThreshold and Color3.fromRGB(239, 165, 68) or color
        end
        fill.Size = UDim2.fromScale(ratio, 1)
        label.Text = maximum > 0 and string.format("%s   %d / %d",
            name, math.round(current), math.round(maximum)) or name .. "   —"
    end
end

function Hud.new(parent, toggle)
    local status = Theme.frame(parent, "Vitals", UDim2.new(0, 24, 1, -24), px(232, 68))
    status.AnchorPoint = Vector2.new(0, 1)

    local button = Theme.button(parent, "OpenCharacter", "Character  [B]",
        UDim2.new(1, -24, 1, -24), px(152, 40), toggle)
    button.AnchorPoint = Vector2.one
    Theme.outline(button)

    local runService = game:GetService("RunService")
    local shared = game:GetService("ReplicatedStorage").Shared
    if runService:IsStudio() and require(shared.Config.CombatConfig).DebugHitboxes then
        local attrs = require(shared.Config.CombatVFXConfig).Attributes
        local player = game:GetService("Players").LocalPlayer
        local debugLabel = Theme.label(status, "HeavyDebug", "", px(0, -24), px(310, 20), 12)
        local connection = runService.Heartbeat:Connect(function()
            local character = player.Character
            debugLabel.Visible = character ~= nil and character:GetAttribute(attrs.MoveId) == "Heavy"
            if debugLabel.Visible then
                local now = workspace:GetServerTimeNow()
                local starts = character:GetAttribute(attrs.ArmorStartsAt)
                local ends = character:GetAttribute(attrs.ArmorEndsAt)
                local armor = starts and ends and now >= starts and now < ends
                debugLabel.Text = "Heavy  " .. (character:GetAttribute(attrs.Phase) or "")
                    .. (armor and "   Super Armor" or "")
            end
        end)
        status.Destroying:Connect(function() connection:Disconnect() end)
    end

    return {
        Status = status,
        OpenButton = button,
        Health = createMeter(status, "Health", 0, Colors.Health),
        Posture = createMeter(status, "Posture", 24, Colors.Accent),
        Mana = createMeter(status, "Mana", 48, Colors.Mana),
    }
end

return Hud
