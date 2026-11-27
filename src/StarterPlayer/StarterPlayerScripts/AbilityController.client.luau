local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Context = game:GetService("ContextActionService")
local Input = game:GetService("UserInputService")
local Run = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config.AbilityConfig)
local Magic = require(Shared.Config.MagicConfig)
local Registry = require(Shared.Abilities.AbilityRegistry)
local Composer = require(Shared.Magic.SpellComposer)
local Hud = require(script.Parent.Interface.AbilityHud)
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local events = remotes:WaitForChild("Events")
local request = events:WaitForChild("AbilityRequest")
local magicRequest = events:WaitForChild("MagicRequest")
local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name, gui.ResetOnSpawn = "AbilityHUD", false
gui.Parent = player:WaitForChild("PlayerGui")

local profile, element, form, binding, pendingCast
local bindings = table.clone(Config.Bindings)
local intensity, revision = 0, 0
local compose, settings = false, false
local message, messageUntil = "", 0
local render
local previousBackpack

local function notify(text)
    message, messageUntil = text, os.clock() + 2
end

local function recipe()
    return { Elements = element and { [element] = intensity } or {}, Form = form }
end

local function aim()
    local camera = workspace.CurrentCamera
    local c = player.Character
    local root = c and c:FindFirstChild("HumanoidRootPart")
    if not camera or not root then return nil end
    local params = RaycastParams.new()
    params.FilterDescendantsInstances = { c }
    local ray = camera.CFrame.LookVector * 100
    local hit = workspace:Raycast(camera.CFrame.Position, ray, params)
    local point = hit and hit.Position or camera.CFrame.Position + ray
    local delta = point - (root.Position + Vector3.yAxis)
    return delta.Magnitude > 0.01 and delta.Unit or camera.CFrame.LookVector
end

local function action(id)
    if player:GetAttribute("OudLagoonMenuOpen") or Input:GetFocusedTextBox() then return end
    if id == "Keys" then settings = not settings; binding = nil
    elseif id == "MagicMode" then compose = not compose; settings = false; binding = nil
    elseif settings or not profile then return
    elseif Config.DefaultSlots[id] ~= nil then
        if profile.Loadout.Abilities[id] ~= "" and aim() then request:FireServer("Slot", id, aim()) end
    elseif compose then
        if Magic.Elements[id] then
            intensity = element == id and math.min(intensity + 1, #Magic.Intensity) or 1
            element = id
            revision += 1
        elseif Magic.Forms[id] then
            form = id
            revision += 1
        elseif id == "Clear" then
            element, intensity, form = nil, 0, nil
            revision += 1
        elseif id == "CastMagic" and aim() then
            local spell, reason = Composer.Resolve(recipe(), Composer.Stats(profile))
            if spell and pendingCast and os.clock() < pendingCast.Expires then return end
            if spell then
                pendingCast = { RecipeId = spell.Id, Revision = revision, Expires = os.clock() + 2 }
                magicRequest:FireServer(recipe(), aim())
            else notify(reason) end
        end
    end
    render()
end

local draw = Hud.new(gui, Config, action, function(id)
    binding = id
    notify("Press a free key. Escape cancels.")
    render()
end)

render = function()
    local hideBackpack = compose and not player:GetAttribute("OudLagoonMenuOpen")
    if hideBackpack and previousBackpack == nil then
        previousBackpack = StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.Backpack)
        StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
    elseif not hideBackpack and previousBackpack ~= nil then
        StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, previousBackpack)
        previousBackpack = nil
    end
    local c = player.Character
    local wear = c and c:GetAttribute("GateWear") or 0
    local overloaded = c and c:GetAttribute("GateOverloaded")
    local spell = element and form and Composer.Resolve(recipe(), Composer.Stats(profile))
    local slots = {}
    for slot, abilityId in pairs(profile and profile.Loadout.Abilities or Config.DefaultSlots) do
        local definition = Registry[abilityId]
        if definition then
            local remaining = math.ceil((c and c:GetAttribute("Cooldown_"..abilityId) or 0) - workspace:GetServerTimeNow())
            slots[slot] = { Label = remaining > 0 and remaining.."s" or definition.Name, Ready = remaining <= 0 }
        end
    end
    local projected = wear + (spell and spell.GateWear or 0)
    draw({ Hidden = player:GetAttribute("OudLagoonMenuOpen"), Settings = settings, Compose = compose,
        Binding = binding, Bindings = bindings, Wear = wear, MaxWear = Magic.Gate.Max, Overloaded = overloaded,
        Slots = slots, Element = element, Form = form, Name = spell and spell.Name or
            ((element and element.." ×"..intensity or "Choose an element") .. "  ·  " .. (form or "Choose a form")),
        Estimate = spell and string.format("Mana %d   ·   Gate %d → %d%s", spell.ManaCost, wear, projected,
            projected >= Magic.Gate.Max and "  OVERLOAD" or "") or "",
        Risk = projected >= Magic.Gate.Max, CanCast = spell ~= nil and not overloaded
            and (player:GetAttribute("Mana") or 0) >= (spell and spell.ManaCost or 0),
        Message = os.clock() < messageUntil and message or (c and c:GetAttribute("AbilityPhase") or ""),
    })
end

local function bindKeys()
    for _, id in ipairs(Config.ActionOrder) do
        local name = "OudAbility_"..id
        Context:UnbindAction(name)
        Context:BindActionAtPriority(name, function(_, state)
            if binding or player:GetAttribute("OudLagoonMenuOpen") or Input:GetFocusedTextBox() then
                return Enum.ContextActionResult.Pass
            end
            if id ~= "MagicMode" and Config.DefaultSlots[id] == nil and not compose then
                return Enum.ContextActionResult.Pass
            end
            if state == Enum.UserInputState.Begin then action(id) end
            return Enum.ContextActionResult.Sink
        end, false, Enum.ContextActionPriority.High.Value + 1, Enum.KeyCode[bindings[id]])
    end
end

Input.InputBegan:Connect(function(input)
    if not binding or input.UserInputType ~= Enum.UserInputType.Keyboard or Input:GetFocusedTextBox() then return end
    local key, id = input.KeyCode.Name, binding
    binding = nil
    if key ~= "Escape" then
        if Config.CanBind(bindings, id, key) then request:FireServer("Bind", id, key)
        else notify("Key reserved or already assigned") end
    end
    render()
end)

local function onProfile(snapshot)
    if not snapshot or not snapshot.Loadout or (profile and snapshot.Revision < profile.Revision) then return end
    profile, bindings = snapshot, snapshot.Loadout.Bindings
    bindKeys()
    render()
end
events:WaitForChild("ProfileUpdated").OnClientEvent:Connect(onProfile)
events:WaitForChild("AbilityResult").OnClientEvent:Connect(function(c, kind, text, id, abilityId)
    if c ~= player.Character then return end
    if kind == "Started" and pendingCast and abilityId == pendingCast.RecipeId then
        pendingCast.CastId = id
    elseif kind == "Released" and pendingCast and pendingCast.CastId == id then
        if pendingCast.Revision == revision then element, form, intensity = nil, nil, 0 end
        pendingCast = nil
    elseif kind == "Interrupted" and pendingCast and pendingCast.CastId == id then
        pendingCast = nil
    elseif kind == "Error" and pendingCast and not pendingCast.CastId then
        pendingCast = nil
    end
    notify(text)
    render()
end)
player.CharacterAdded:Connect(function()
    compose, settings, binding, element, form, intensity, pendingCast = false, false, nil, nil, nil, 0, nil
end)
player:GetAttributeChangedSignal("OudLagoonMenuOpen"):Connect(function()
    if player:GetAttribute("OudLagoonMenuOpen") then binding = nil; settings = false end
    render()
end)
local elapsed = 0
Run.Heartbeat:Connect(function(dt)
    elapsed += dt
    if elapsed < 0.12 then return end
    elapsed = 0
    local c = player.Character
    if c and c:GetAttribute("AbilityPhase") == "Startup" and aim() then
        request:FireServer("Aim", c:GetAttribute("AbilityCastId"), aim())
    end
    render()
end)
script.Destroying:Connect(function()
    for _, id in ipairs(Config.ActionOrder) do Context:UnbindAction("OudAbility_"..id) end
    if previousBackpack ~= nil then StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, previousBackpack) end
    gui:Destroy()
end)
bindKeys()
render()
task.spawn(function()
    local fetch = remotes:WaitForChild("Functions"):WaitForChild("RequestProfile")
    local ok, snapshot = pcall(function() return fetch:InvokeServer() end)
    if ok then onProfile(snapshot) end
end)
