-- Fill SoundId with "rbxassetid://123456789" or a numeric asset ID. Empty means silent.
local Config = {
    Enabled = true,
    Preload = true,
    LocalSwing = true,
    LocalDash = true,
    DedupLifetime = 10,
    BroadcastDistance = 100,
    MaxAge = 0.6,
    MaxVoices = 32,
    MaxVoicesPerCharacter = 4,
    Defaults = { Volume = 0.6, PlaybackSpeed = 1, RollOffMinDistance = 6,
        RollOffMaxDistance = 70, MaxDuration = 8 },
    Clips = {
        HeavyWindup = { SoundId = "120430503624654", Volume = 0.28, PlaybackSpeed = 0.62 },
        UnarmedHeavy = { SoundId = "120430503624654", PlaybackSpeed = 0.77 },
        SwordHeavy = { SoundId = "137628815514180", PlaybackSpeed = 0.78 },
        HeavyImpact = { SoundId = "136699507852787", PlaybackSpeed = 0.70 },
        HeavyBlock = { SoundId = "5763723309", PlaybackSpeed = 0.73 },
        ParryPressure = { SoundId = "" }, -- optional pressure accent on the attacker
        PostureBreak = { SoundId = "136159508882086", PlaybackSpeed = 0.75 }, -- provisional metallic accent
        UnarmedLight1 = { SoundId = "120430503624654" },
        UnarmedLight2 = { SoundId = "120430503624654" },
        UnarmedLight3 = { SoundId = "120430503624654" },
        UnarmedDashLight = { SoundId = "90586397812382" },
        SwordLight1 = { SoundId = "135315310485417" },
        SwordLight2 = { SoundId = "135315310485417" },
        SwordLight3 = { SoundId = "137628815514180" },
        SwordDashLight = { SoundId = "125914564702009" },
        Hit1 = { SoundId = "136699507852787" },
        Hit2 = { SoundId = "136699507852787" },
        Hit3 = { SoundId = "136699507852787" },
        DashHit = { SoundId = "" },
        Dash = { SoundId = "90586397812382" },
        BlockStart = { SoundId = "" },
        BlockEnd = { SoundId = "" },
        BlockHit = { SoundId = "5763723309" },
        Parry = { SoundId = "136159508882086" },
        Stun = { SoundId = "" },
        Ragdoll = { SoundId = "" },
        Death = { SoundId = "" },
    },
    Attacks = {
        Unarmed = { Light1 = "UnarmedLight1", Light2 = "UnarmedLight2", Light3 = "UnarmedLight3", Heavy = "UnarmedHeavy", DashLight = "UnarmedDashLight" },
        Sword = { Light1 = "SwordLight1", Light2 = "SwordLight2", Light3 = "SwordLight3", Heavy = "SwordHeavy", DashLight = "SwordDashLight" },
    },
    Hits = {
        Unarmed = { Light1 = "Hit1", Light2 = "Hit2", Light3 = "Hit3", Heavy = "HeavyImpact", DashLight = "DashHit" },
        Sword = { Light1 = "Hit1", Light2 = "Hit2", Light3 = "Hit3", Heavy = "HeavyImpact", DashLight = "DashHit" },
    },
    States = { Blocking = "BlockStart", Dodging = "Dash", Stunned = "Stun", Ragdolled = "Ragdoll", Dead = "Death" },
}

function Config.GetSoundId(value)
    if type(value) == "number" and value > 0 and value < math.huge and value % 1 == 0 then
        return "rbxassetid://" .. string.format("%.0f", value)
    end
    if type(value) ~= "string" then return nil end
    local digits = value:match("^rbxassetid://(%d+)$") or value:match("^(%d+)$")
    if digits and digits:find("[1-9]") then return "rbxassetid://" .. digits end
    return nil
end

function Config.Get(key)
    local clip = Config.Clips[key]
    if not clip or not Config.GetSoundId(clip.SoundId) then return nil end
    local result = table.clone(Config.Defaults)
    for name, value in pairs(clip) do result[name] = value end
    result.SoundId = Config.GetSoundId(clip.SoundId)
    return result
end

function Config.Validate()
    local function number(n, min, max)
        return type(n) == "number" and n == n and n >= min and n <= max
    end
    assert(number(Config.BroadcastDistance, 1, 500) and number(Config.MaxAge, 0.05, 3), "Invalid SFX distances/timing")
    assert(number(Config.MaxVoices, 1, 128) and Config.MaxVoices % 1 == 0, "Invalid SFX voice limit")
    assert(number(Config.MaxVoicesPerCharacter, 1, Config.MaxVoices)
        and Config.MaxVoicesPerCharacter % 1 == 0, "Invalid per-character SFX limit")
    local function check(clip)
        assert(number(clip.Volume, 0, 10) and number(clip.PlaybackSpeed, 0.1, 4), "Invalid SFX volume/speed")
        assert(number(clip.RollOffMinDistance, 0, clip.RollOffMaxDistance)
            and number(clip.RollOffMaxDistance, 1, Config.BroadcastDistance), "Invalid SFX rolloff")
        assert(number(clip.MaxDuration, 0.1, 30), "Invalid SFX cleanup timeout")
    end
    assert(number(Config.DedupLifetime, 2, 30), "Invalid SFX dedup lifetime")
    check(Config.Defaults)
    for key, clip in pairs(Config.Clips) do
        assert(type(clip) == "table" and (clip.SoundId == "" or Config.GetSoundId(clip.SoundId)), "Invalid SoundId: " .. key)
        local resolved = table.clone(Config.Defaults)
        for name, value in pairs(clip) do resolved[name] = value end
        check(resolved)
    end
    for _, map in ipairs({Config.Attacks, Config.Hits}) do
        for _, moves in pairs(map) do
            for _, key in pairs(moves) do assert(Config.Clips[key], "Unknown SFX clip: " .. key) end
        end
    end
    for _, key in pairs(Config.States) do assert(Config.Clips[key], "Unknown SFX state clip") end
    return true
end

return Config
