local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProgressionConfig = require(
    ReplicatedStorage.Shared.Config.ProgressionConfig
)

local DataService = require(script.Parent.DataService)
local CharacterService = require(script.Parent.CharacterService)
local RemoteService = require(script.Parent.RemoteService)

local PlayerService = {}

local PROFILE_WAIT_TIMEOUT = 20

local KICK_MESSAGES = {
    Locked = "Your previous session is still saving. Please rejoin in a minute.",
    Corrupt = "Your data could not be read. Please contact support.",
    Default = "Your data could not be loaded. Please try again later.",
}

-- Клиенту отправляем только то, что ему нужно для интерфейса.
-- Единственное место, где собирается профиль для клиента:
-- ProgressionService и DebugService тоже отправляют его через PushProfile.
local function BuildPublicProfile(profile)
    local nextLevelExperience = 0

    if profile.Level < ProgressionConfig.MaxLevel then
        nextLevelExperience =
            ProgressionConfig:GetExperienceForNextLevel(profile.Level)
    end

    return {
        Level = profile.Level,
        Experience = profile.Experience,
        NextLevelExperience = nextLevelExperience, -- 0 на максимальном уровне
        StatPoints = profile.StatPoints,
        Stats = profile.Stats,
        Resources = profile.Resources,
    }
end

-- Отправляет клиенту актуальный профиль (вызывайте после любого изменения).
function PlayerService:PushProfile(player)
    local profile = DataService:GetProfile(player)

    if not profile then
        return
    end

    RemoteService:GetEvent("ProfileUpdated"):FireClient(
        player,
        BuildPublicProfile(profile)
    )
end

local function OnCharacterAdded(player, character)
    local profile = DataService:GetProfile(player)

    if not profile then
        return
    end

    CharacterService:ApplyStats(player, character, profile)
end

local function OnPlayerAdded(player)
    local profile, reason = DataService:LoadProfile(player)

    if not profile then
        if reason == "AlreadyLoading" or reason == "PlayerLeft" then
            return
        end

        warn("[PlayerService] Could not load profile:", player.Name, reason)

        player:Kick(KICK_MESSAGES[reason] or KICK_MESSAGES.Default)

        return
    end

    -- Игрок мог выйти, пока грузился профиль
    if player.Parent ~= Players then
        DataService:ReleaseProfile(player)
        return
    end

    print("[PlayerService] Player initialized:", player.Name)

    player.CharacterAdded:Connect(function(character)
        OnCharacterAdded(player, character)
    end)

    -- Персонаж мог появиться, пока грузился профиль
    if player.Character then
        task.spawn(OnCharacterAdded, player, player.Character)
    end

    PlayerService:PushProfile(player)
end

local function OnPlayerRemoving(player)
    DataService:ReleaseProfile(player)

    print("[PlayerService] Player left:", player.Name)
end

function PlayerService:Init()
    Players.PlayerAdded:Connect(OnPlayerAdded)
    Players.PlayerRemoving:Connect(OnPlayerRemoving)

    -- Клиент сам запрашивает профиль, когда его интерфейс готов.
    -- Так мы не теряем первое событие, отправленное до подключения слушателей.
    RemoteService:OnFunction("RequestProfile", { RateLimit = 2 }, function(player)
        local deadline = os.clock() + PROFILE_WAIT_TIMEOUT
        local profile = DataService:GetProfile(player)

        while not profile and player.Parent == Players and os.clock() < deadline do
            task.wait(0.25)
            profile = DataService:GetProfile(player)
        end

        if not profile then
            return nil
        end

        return BuildPublicProfile(profile)
    end)

    -- Обработка игроков, которые уже находятся на сервере.
    for _, player in ipairs(Players:GetPlayers()) do
        task.spawn(OnPlayerAdded, player)
    end

    print("[PlayerService] Initialized")
end

return PlayerService