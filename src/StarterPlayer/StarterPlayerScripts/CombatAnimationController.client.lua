-- Клиентская система боевых анимаций. Работает независимо от CombatController.
--
-- Источник правды - сервер: анимация запускается только после того, как сервер подтвердил
-- переход состояния (CombatStateChanged). Если сервер отклонил атаку, анимации не будет.
-- Эта система ничего не отправляет на сервер и не влияет на урон, кулдауны и тайминги.
--
-- Анимации проигрываются на Animator своего персонажа, поэтому другие игроки видят их
-- через стандартную репликацию Roblox.
--
-- Соответствие состояний и анимаций:
--   Attacking (переход из другого состояния) -> Attack (одна анимация на все фазы удара)
--   Blocking                                 -> Block (зациклена, пока держится блок)
--   Stunned                                  -> Stun
--   Dodging                                  -> Dodge
--   Idle / Dead                              -> боевая анимация останавливается
-- Смена фаз атаки (Startup/Active/Recovery) анимацию не перезапускает.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")

local player = Players.LocalPlayer

local Shared = ReplicatedStorage:WaitForChild("Shared")

local CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))
local CombatAnimationConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatAnimationConfig"))
local CombatStates = require(Shared:WaitForChild("Constants"):WaitForChild("CombatStates"))

local CombatStateChanged = ReplicatedStorage
    :WaitForChild("Remotes")
    :WaitForChild("Events")
    :WaitForChild("CombatStateChanged")

local Settings = CombatAnimationConfig.Settings

local SLOT_ATTACK = "Attack"

-- Animator и загруженные треки относятся только к текущему персонажу.
local animator = nil
local tracks = {}     -- [slot .. "|" .. animationId] = AnimationTrack
local animations = {} -- [slot .. "|" .. animationId] = Animation (для предзагрузки)

-- Сейчас проигрываемая боевая анимация (одна: бой не смешивает несколько поз сразу)
local activeSlot = nil
local activeTrack = nil

local function debugLog(...)
    if Settings.DebugLogging then
        print("[CombatAnimation]", ...)
    end
end

-- Оружие определяем так же, как CombatController: по атрибуту экипированного Tool.
-- Для выбора анимации достаточно; урон и таймингами всё равно занимается сервер.
local function getWeaponId()
    local character = player.Character
    local tool = character and character:FindFirstChildOfClass("Tool")

    if tool then
        local weaponId = tool:GetAttribute(CombatConfig.WeaponAttribute)

        if type(weaponId) == "string" and CombatConfig.Weapons[weaponId] then
            return weaponId
        end
    end

    return CombatConfig.UnarmedId
end

-- ТРЕКИ ------------------------------------------------------------------

-- Возвращает AnimationTrack для слота или nil (не назначена, нет Animator, не загрузилась).
-- Треки загружаются один раз на персонажа и кэшируются.
local function getTrack(slot, weaponId)
    if not animator then
        return nil
    end

    local animationId = CombatAnimationConfig.GetAnimationId(slot, weaponId)

    if not animationId then
        return nil
    end

    local key = slot .. "|" .. animationId
    local cached = tracks[key]

    if cached ~= nil then
        return cached or nil -- false = загрузка уже провалилась, повторно не пробуем
    end

    local animation = Instance.new("Animation")
    animation.AnimationId = animationId

    local ok, result = pcall(function()
        return animator:LoadAnimation(animation)
    end)

    if not ok then
        warn("[CombatAnimation] Could not load", slot, animationId, result)
        animation:Destroy()
        tracks[key] = false

        return nil
    end

    local slotSettings = CombatAnimationConfig.Slots[slot]

    if slotSettings then
        result.Priority = slotSettings.Priority
        result.Looped = slotSettings.Looped
    end

    tracks[key] = result
    animations[key] = animation

    return result
end

local function stopActive(fadeTime)
    if activeTrack then
        activeTrack:Stop(fadeTime or Settings.FadeOutTime)
    end

    activeTrack = nil
    activeSlot = nil
end

-- Забывает все треки текущего персонажа (респавн, удаление персонажа).
local function resetTracks()
    stopActive(0)

    for _, track in pairs(tracks) do
        if track then
            pcall(function()
                track:Stop(0)
                track:Destroy()
            end)
        end
    end

    for _, animation in pairs(animations) do
        animation:Destroy()
    end

    tracks = {}
    animations = {}
    animator = nil
end

-- Заранее загружает все назначенные анимации, чтобы первый удар не запаздывал.
-- Заодно сверяет длину анимаций атаки с серверным таймингом (подсказка при создании анимаций).
local function preload()
    local toPreload = {}
    local attackTracks = {} -- [weaponId] = track

    local function add(slot, weaponId)
        local track = getTrack(slot, weaponId)

        if track then
            local animationId = CombatAnimationConfig.GetAnimationId(slot, weaponId)
            local animation = animations[slot .. "|" .. animationId]

            if animation then
                table.insert(toPreload, animation)
            end

            -- Длину сверяем только для анимаций конкретного оружия (у него есть тайминг)
            if slot == SLOT_ATTACK and weaponId then
                attackTracks[weaponId] = track
            end
        end
    end

    for slot in pairs(CombatAnimationConfig.Slots) do
        add(slot, nil) -- общие анимации

        for weaponId in pairs(CombatAnimationConfig.Weapons) do
            add(slot, weaponId)
        end
    end

    if #toPreload == 0 then
        return
    end

    local currentAnimator = animator

    task.spawn(function()
        pcall(function()
            ContentProvider:PreloadAsync(toPreload)
        end)

        -- Персонаж мог смениться, пока шла загрузка
        if animator ~= currentAnimator then
            return
        end

        if not Settings.WarnOnLengthMismatch then
            return
        end

        for weaponId, track in pairs(attackTracks) do
            local weapon = CombatConfig.Weapons[weaponId]
            local timing = weapon and weapon.AttackTiming

            if timing and track.Length > 0 then
                local expected = timing.Startup + timing.Active + timing.Recovery

                if math.abs(track.Length - expected) > Settings.LengthTolerance then
                    warn(string.format(
                        "[CombatAnimation] %s Attack: animation is %.2fs, server swing is %.2fs",
                        weaponId,
                        track.Length,
                        expected
                    ))
                end
            end
        end
    end)
end

-- ВОСПРОИЗВЕДЕНИЕ --------------------------------------------------------

local function playSlot(slot, weaponId)
    local track = getTrack(slot, weaponId)

    -- Блок/оглушение пришли повторно (например, после Sync): не перезапускаем
    if track and track == activeTrack and slot ~= SLOT_ATTACK and track.IsPlaying then
        return
    end

    if track and track == activeTrack then
        stopActive(0) -- та же анимация подряд (новый удар): начинаем сначала
    else
        stopActive()
    end

    if not track then
        debugLog(slot, "has no animation assigned")
        return
    end

    track:Play(Settings.FadeInTime)

    activeTrack = track
    activeSlot = slot

    debugLog("play", slot, weaponId or "")
end

local function onStateChanged(payload)
    if type(payload) ~= "table" or type(payload.State) ~= "string" then
        return
    end

    local state = payload.State

    if state == CombatStates.Attacking then
        -- Событие со сменой фазы (без OldState) и Sync посреди удара анимацию не запускают:
        -- запуск только на подтверждённом переходе в Attacking.
        if payload.OldState ~= nil and payload.OldState ~= CombatStates.Attacking then
            playSlot(SLOT_ATTACK, getWeaponId())
        end
    elseif state == CombatStates.Blocking then
        playSlot("Block", getWeaponId())
    elseif state == CombatStates.Stunned then
        playSlot("Stun", getWeaponId())
    elseif state == CombatStates.Dodging then
        playSlot("Dodge", getWeaponId())
    elseif state == CombatStates.Idle or state == CombatStates.Dead then
        stopActive()
    end
end

CombatStateChanged.OnClientEvent:Connect(onStateChanged)

-- ПЕРСОНАЖ ---------------------------------------------------------------

local function bindCharacter(character)
    resetTracks()

    local humanoid = character:WaitForChild("Humanoid", 10)

    if not humanoid then
        return
    end

    local characterAnimator = humanoid:WaitForChild("Animator", 10)

    if not characterAnimator then
        warn("[CombatAnimation] Animator not found, combat animations disabled")
        return
    end

    -- Пока ждали, персонаж мог смениться
    if player.Character ~= character then
        return
    end

    animator = characterAnimator

    -- Смерть всегда обрывает боевую анимацию (сервер может сообщить о ней позже)
    humanoid.Died:Connect(function()
        stopActive()
    end)

    preload()
end

player.CharacterAdded:Connect(bindCharacter)

player.CharacterRemoving:Connect(function()
    resetTracks()
end)

if player.Character then
    task.spawn(bindCharacter, player.Character)
end
