-- Shared by local movement, animation and the SFX receiver. Cosmetic playback only.
local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")
local Config = require(script.Parent.Parent.Config.CombatSFXConfig)
local SoundPlayer = require(script.Parent.CombatSFXPlayer)
local Client = {}
local audio = SoundPlayer.new(Config)
local seen = setmetatable({}, { __mode = "k" })
local initialized = false
local stopped = false
local preloadSounds = {}

function Client:Init()
    if initialized then return end
    Config.Validate()
    initialized = true
    if not Config.Enabled or not Config.Preload then return end
    task.spawn(function()
        local ids = {}
        for key in pairs(Config.Clips) do
            local clip = Config.Get(key)
            if clip and not ids[clip.SoundId] then
                ids[clip.SoundId] = true
                local sound = Instance.new("Sound")
                sound.SoundId = clip.SoundId
                table.insert(preloadSounds, sound)
            end
        end
        if #preloadSounds > 0 and not stopped then
            local ok, message = pcall(function() ContentProvider:PreloadAsync(preloadSounds) end)
            if not ok then warn("[CombatSFX] Preload failed: " .. tostring(message)) end
        end
        for _, sound in ipairs(preloadSounds) do sound:Destroy() end
        preloadSounds = {}
    end)
end

local function Play(character, key, token)
    if stopped then return false end
    Client:Init()
    local entries = seen[character]
    local now = workspace:GetServerTimeNow()
    if token and entries and entries[token] and now < entries[token] then return false end
    if not audio:Play(character, key, token) then return false end
    if token then
        entries = entries or {}
        seen[character] = entries
        entries[token] = now + Config.DedupLifetime
    end
    return true
end

function Client:AttackStarted(character, weaponId, moveId, attackId)
    if not Config.LocalSwing or character ~= Players.LocalPlayer.Character or type(attackId) ~= "number" then return false end
    local moves = Config.Attacks[weaponId]
    return Play(character, moves and moves[moveId], "Attack:" .. attackId)
end

function Client:DashStarted(character, requestId)
    if not Config.LocalDash or character ~= Players.LocalPlayer.Character or type(requestId) ~= "number" then return false end
    return Play(character, "Dash", "Dash:" .. requestId)
end

function Client:RejectDash(character, requestId)
    if character and requestId then audio:Cancel(character, "Dash:" .. requestId) end
end

function Client:Receive(payload)
    local token
    if payload.AttackId then token = "Attack:" .. payload.AttackId
    elseif payload.DashRequestId then token = "Dash:" .. payload.DashRequestId
    elseif payload.DodgeId then token = "Dodge:" .. payload.DodgeId end
    return Play(payload.Character, payload.Key, token)
end

function Client:Update()
    audio:Update()
    local now = workspace:GetServerTimeNow()
    for character, entries in pairs(seen) do
        if not character.Parent then seen[character] = nil
        else
            for token, endsAt in pairs(entries) do if now >= endsAt then entries[token] = nil end end
        end
    end
end

function Client:Reset()
    audio:Destroy()
    seen = setmetatable({}, { __mode = "k" })
end

function Client:Destroy()
    stopped = true
    self:Reset()
    for _, sound in ipairs(preloadSounds) do sound:Destroy() end
    preloadSounds = {}
end

return Client
