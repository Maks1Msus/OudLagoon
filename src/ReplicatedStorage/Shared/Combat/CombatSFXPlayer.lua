-- Spatial one-shots only. No gameplay state, client requests or indefinite sound loops.
local Player = {}
Player.__index = Player

function Player.new(config)
    return setmetatable({ Config = config, Voices = {} }, Player)
end

function Player:Remove(index)
    local voice = self.Voices[index]
    if not voice then return end
    voice.Connection:Disconnect()
    voice.Sound:Destroy()
    voice.Attachment:Destroy()
    table.remove(self.Voices, index)
end

function Player:Play(character, key, token)
    local config = self.Config
    local clip = config.Get(key)
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local camera = workspace.CurrentCamera
    if not config.Enabled or not clip or not character or not character.Parent or not root or not root:IsA("BasePart")
        or not camera or (camera.CFrame.Position - root.Position).Magnitude > clip.RollOffMaxDistance then return false end
    local count = 0
    local oldest
    for i, voice in ipairs(self.Voices) do
        if voice.Character == character then count = count + 1; oldest = oldest or i end
    end
    if count >= config.MaxVoicesPerCharacter then self:Remove(oldest) end
    if #self.Voices >= config.MaxVoices then self:Remove(1) end
    local attachment = Instance.new("Attachment")
    attachment.Name = "CombatSFXOrigin"
    attachment.Parent = root
    local sound = Instance.new("Sound")
    sound.Name = "CombatSFX_" .. key
    sound.SoundId, sound.Volume, sound.PlaybackSpeed = clip.SoundId, clip.Volume, clip.PlaybackSpeed
    sound.RollOffMode = Enum.RollOffMode.InverseTapered
    sound.RollOffMinDistance, sound.RollOffMaxDistance = clip.RollOffMinDistance, clip.RollOffMaxDistance
    sound.Looped, sound.PlayOnRemove = false, false
    sound.Parent = attachment
    local voice = { Character = character, Token = token, Sound = sound, Attachment = attachment,
        EndsAt = workspace:GetServerTimeNow() + clip.MaxDuration }
    voice.Connection = sound.Ended:Connect(function() voice.Ended = true end)
    table.insert(self.Voices, voice)
    sound:Play()
    return true
end

function Player:Cancel(character, token)
    for i = #self.Voices, 1, -1 do
        local voice = self.Voices[i]
        if voice.Character == character and voice.Token == token then self:Remove(i) end
    end
end

function Player:Update()
    local now = workspace:GetServerTimeNow()
    for i = #self.Voices, 1, -1 do
        local voice = self.Voices[i]
        if voice.Ended or now >= voice.EndsAt or not voice.Character.Parent
            or not voice.Attachment.Parent or not voice.Sound.Parent then self:Remove(i) end
    end
end

function Player:Destroy()
    for i = #self.Voices, 1, -1 do self:Remove(i) end
end

return Player
