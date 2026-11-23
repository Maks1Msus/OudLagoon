local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config.ProgressionConfig)
local StatRules = require(Shared.Progression.StatRules)
local WeaponRegistry = require(Shared.Weapons.WeaponRegistry)
local Interface = script.Parent:WaitForChild("Interface")
local CharacterMenu = require(Interface.CharacterMenu)
local Hud = require(Interface.Hud)
local Theme = require(Interface.Theme)

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local functions = remotes:WaitForChild("Functions")
local requestProfile = functions:WaitForChild("RequestProfile")
local commitAllocation = functions:WaitForChild("CommitStatAllocation")
local resetAttributes = functions:WaitForChild("ResetAttributes")
local events = remotes:WaitForChild("Events")
local profileUpdated = events:WaitForChild("ProfileUpdated")
local debugRequest = RunService:IsStudio() and events:WaitForChild("DebugRequest")
local screen = player:WaitForChild("PlayerGui"):WaitForChild("OudLagoonGui")
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local OPEN_ATTRIBUTE = "OudLagoonMenuOpen"
local Errors = {
    InvalidAllocation = "Check your attribute allocation.",
    StatCap = "An attribute would exceed its cap. Adjust your draft.",
    NotEnoughPoints = "You do not have enough unspent points. Adjust your draft.",
    ProfileUnavailable = "Your profile is unavailable.",
    NothingToReset = "There are no invested attribute points to refund.",
}

local state = {
    Draft = {},
    DraftCost = 0,
    Loading = false,
    Busy = false,
    ResetArmed = false,
    Message = "",
    Error = false,
}

local root = Theme.frame(screen, "Interface", UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1))
local hud, menu
local previousPlayerList

local function render()
    local profile = state.Profile
    local weaponId, weapon = WeaponRegistry.ResolveFromCharacter(player.Character)
    local attributes = profile and profile.Stats.Attributes
    local spent = attributes and StatRules.GetSpentPoints(attributes) or 0
    local cost, reason
    if attributes and next(state.Draft) then
        cost, reason = StatRules.GetAllocationCost(attributes, profile.StatPoints, state.Draft)
    end
    state.CanConfirm = cost ~= nil and not state.Busy and not state.Loading
    local message = Errors[reason] or state.Message
    if state.ResetArmed then
        message = string.format("Reset all attributes and refund %d points? Your draft will be cleared.", spent)
    end

    menu:render({
        Profile = profile,
        Draft = state.Draft,
        DraftCost = state.DraftCost,
        Loading = state.Loading,
        Busy = state.Busy,
        CanConfirm = state.CanConfirm,
        Spent = spent,
        ResetArmed = state.ResetArmed,
        WeaponId = weaponId,
        Weapon = weapon,
        Message = message,
        Error = not state.ResetArmed and (reason ~= nil or state.Error),
    })
end

local function acceptProfile(profile)
    if type(profile) ~= "table" or type(profile.Revision) ~= "number" then
        return
    end
    if not state.Profile or profile.Revision >= state.Profile.Revision then
        if state.Profile and profile.Revision > state.Profile.Revision then
            state.ResetArmed = false
        end
        state.Profile = profile
    end
end

local function fetchProfile()
    if state.Loading then
        return
    end
    state.Loading = true
    if not state.Profile then
        state.Message, state.Error = "", false
    end
    render()
    task.spawn(function()
        local ok, profile = pcall(function()
            return requestProfile:InvokeServer()
        end)
        state.Loading = false
        if ok then
            acceptProfile(profile)
        end
        if not state.Profile then
            state.Message, state.Error = "Could not load your profile.", true
        end
        render()
    end)
end

local function adjust(statName, delta)
    local profile = state.Profile
    if state.Busy or state.ResetArmed or not profile or delta == 0 then
        return
    end
    local change = state.Draft[statName] or 0
    local value = profile.Stats.Attributes[statName]
    if delta > 0 then
        delta = math.min(delta, Config.MaxStatValue - value - change, profile.StatPoints - state.DraftCost)
        if delta <= 0 then
            return
        end
    elseif change == 0 then
        return
    end

    change += delta
    state.Draft[statName] = change > 0 and change or nil
    state.DraftCost += delta
    state.Message, state.Error = "", false
    render()
end

local function clear()
    if state.Busy then
        return
    end
    if state.ResetArmed then
        state.ResetArmed = false
    else
        table.clear(state.Draft)
        state.DraftCost = 0
    end
    state.Message, state.Error = "", false
    render()
end

local function mutate(invoke, successMessage)
    state.Busy = true
    state.ResetArmed = false
    state.Message, state.Error = "", false
    render()

    task.spawn(function()
        local ok, result = pcall(invoke)
        state.Busy = false
        if ok and type(result) == "table" and result.Profile then
            acceptProfile(result.Profile)
            table.clear(state.Draft)
            state.DraftCost = 0
            state.Message = successMessage
        elseif ok and type(result) == "table" and Errors[result.Reason] then
            state.Message, state.Error = Errors[result.Reason], true
        else
            -- The result is unknown. Refresh before letting the player draft another allocation.
            table.clear(state.Draft)
            state.DraftCost = 0
            state.Message, state.Error = "The server response was unavailable. Check your updated attributes.", true
            fetchProfile()
        end
        render()
    end)
end

local function apply()
    if state.CanConfirm and not state.Busy and not state.ResetArmed then
        local changes = table.clone(state.Draft)
        mutate(function()
            return commitAllocation:InvokeServer(changes)
        end, "Attribute points applied.")
    end
end

local function reset()
    if state.Busy or state.Loading or not state.Profile
        or StatRules.GetSpentPoints(state.Profile.Stats.Attributes) == 0 then
        return
    end
    if not state.ResetArmed then
        state.ResetArmed = true
        render()
        return
    end

    mutate(function()
        return resetAttributes:InvokeServer()
    end, "Attributes reset. Invested points were refunded.")
end

local function setOpen(open)
    if open == menu.Overlay.Visible then
        return
    end
    if open then
        previousPlayerList = StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.PlayerList)
        StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
    elseif previousPlayerList ~= nil then
        StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, previousPlayerList)
        previousPlayerList = nil
    end
    if not open then
        state.ResetArmed = false
    end
    player:SetAttribute(OPEN_ATTRIBUTE, open)
    menu.Overlay.Visible = open
    hud.OpenButton.Visible = not open
    hud.Status.Visible = not open
    menu.Preview:setCharacter(open and player.Character or nil)
    if open then
        render()
    end
end

local function toggle()
    setOpen(not menu.Overlay.Visible)
end

menu = CharacterMenu.new(root, player.DisplayName, {
    Adjust = adjust,
    Apply = apply,
    Clear = clear,
    Reset = reset,
    Retry = fetchProfile,
    TabChanged = function()
        if state.ResetArmed then
            state.ResetArmed = false
            render()
        end
    end,
    Debug = debugRequest and function(action, amount)
        debugRequest:FireServer(action, amount)
    end,
    Close = function()
        setOpen(false)
    end,
})
hud = Hud.new(root, toggle)
StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
-- Keep the overlay above the HUD even when it is opened from a button.
menu.Overlay.ZIndex = 3
player:SetAttribute(OPEN_ATTRIBUTE, false)

local collection = game:GetService("CollectionService")
local npcBars = {}
local function addNpcBar(model)
    if npcBars[model] or not model:IsA("Model") then return end
    local bar = Instance.new("BillboardGui")
    bar.Name = "PostureMeter"
    bar.Size = UDim2.fromOffset(90, 6)
    bar.StudsOffsetWorldSpace = Vector3.new(0, 2.5, 0)
    bar.MaxDistance = 45
    bar.Parent = screen
    local track = Theme.frame(bar, "Track", UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), Theme.Colors.Surface)
    local fill = Theme.frame(track, "Posture", UDim2.fromScale(0, 0), UDim2.fromScale(0, 1), Theme.Colors.Accent)
    local function refresh()
        local maximum = model:GetAttribute("CombatMaxPosture") or 0
        local value = model:GetAttribute("CombatPosture") or 0
        bar.Adornee = model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart")
        bar.Enabled = bar.Adornee ~= nil and value > 0 and maximum > 0
        fill.Size = UDim2.fromScale(math.clamp(value / math.max(1, maximum), 0, 1), 1)
    end
    npcBars[model] = { Bar = bar, model:GetAttributeChangedSignal("CombatPosture"):Connect(refresh),
        model:GetAttributeChangedSignal("CombatMaxPosture"):Connect(refresh),
        model.ChildAdded:Connect(refresh), model.ChildRemoved:Connect(refresh) }
    refresh()
end
collection:GetInstanceAddedSignal("PostureNPC"):Connect(addNpcBar)
collection:GetInstanceRemovedSignal("PostureNPC"):Connect(function(model)
    local entry = npcBars[model]
    if entry then
        for _, connection in ipairs(entry) do connection:Disconnect() end
        entry.Bar:Destroy()
        npcBars[model] = nil
    end
end)
for _, model in ipairs(collection:GetTagged("PostureNPC")) do addNpcBar(model) end

local characterConnections = {}
local healthConnections = {}
local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
    table.clear(connections)
end

local function bindCharacter(character)
    disconnectAll(characterConnections)
    disconnectAll(healthConnections)
    hud.Health(0, 0)
    hud.Posture(0, 0)
    if menu.Overlay.Visible then
        menu.Preview:setCharacter(character)
        render()
    end
    if not character then
        return
    end

    local function refreshPosture()
        hud.Posture(character:GetAttribute("CombatPosture") or 0, character:GetAttribute("CombatMaxPosture") or 0)
    end
    for _, key in ipairs({ "CombatPosture", "CombatMaxPosture" }) do
        table.insert(characterConnections, character:GetAttributeChangedSignal(key):Connect(refreshPosture))
    end
    refreshPosture()

    local function bindHealth()
        disconnectAll(healthConnections)
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if not humanoid then
            hud.Health(0, 0)
            return
        end
        local function refreshHealth()
            hud.Health(humanoid.Health, humanoid.MaxHealth)
        end
        table.insert(healthConnections, humanoid.HealthChanged:Connect(refreshHealth))
        table.insert(healthConnections, humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(refreshHealth))
        refreshHealth()
    end

    local previewQueued = false
    local function onChildChanged(child)
        if child:IsA("Humanoid") then
            bindHealth()
        end
        if previewQueued or not menu.Overlay.Visible then
            return
        end
        if child:IsA("Accessory") or child:IsA("Tool") or child:IsA("Clothing")
            or child:IsA("BodyColors") or child:IsA("CharacterMesh") or child:IsA("BasePart") then
            previewQueued = true
            task.defer(function()
                previewQueued = false
                if menu.Overlay.Visible and player.Character == character then
                    menu.Preview:setCharacter(character)
                    render()
                end
            end)
        end
    end
    table.insert(characterConnections, character.ChildAdded:Connect(onChildChanged))
    table.insert(characterConnections, character.ChildRemoved:Connect(onChildChanged))
    bindHealth()
end

local function refreshMana()
    hud.Mana(player:GetAttribute("Mana") or 0, player:GetAttribute("MaxMana") or 0)
end

player:GetAttributeChangedSignal("Mana"):Connect(refreshMana)
player:GetAttributeChangedSignal("MaxMana"):Connect(refreshMana)
player.CharacterAdded:Connect(bindCharacter)
player.CharacterRemoving:Connect(function()
    bindCharacter(nil)
end)
bindCharacter(player.Character)
refreshMana()

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then
        return
    end
    if input.KeyCode == Enum.KeyCode.B then
        toggle()
    elseif debugRequest and input.KeyCode == Enum.KeyCode.F8 then
        if menu.Overlay.Visible and menu.ActiveTab == "Debugging" then
            setOpen(false)
        else
            menu:selectTab("Debugging")
            setOpen(true)
        end
    end
end)

profileUpdated.OnClientEvent:Connect(function(profile)
    acceptProfile(profile)
    render()
end)
fetchProfile()
