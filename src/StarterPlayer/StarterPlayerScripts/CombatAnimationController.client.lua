-- Client animation of authoritative combat states and stun reactions.
-- Hit/Parried/Stunned clips follow server stun deadlines.
-- Parry and BlockHit feedback provide short defensive reactions.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")

local player = Players.LocalPlayer

local Shared = ReplicatedStorage:WaitForChild("Shared")

local CombatAnimationConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatAnimationConfig"))
local CombatStates = require(Shared:WaitForChild("Constants"):WaitForChild("CombatStates"))
local WeaponRegistry = require(Shared:WaitForChild("Weapons"):WaitForChild("WeaponRegistry"))
local AttackAnimationSync = require(Shared:WaitForChild("Combat"):WaitForChild("AttackAnimationSync"))
local DashConfig = require(Shared:WaitForChild("Config"):WaitForChild("DashConfig"))
local LocalSFX = require(Shared.Combat.CombatSFXClient)
local CombatReactionSync = require(Shared:WaitForChild("Combat"):WaitForChild("CombatReactionSync"))

local Events = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Events")
local CombatStateChanged = Events:WaitForChild("CombatStateChanged")
local CombatFeedback = Events:WaitForChild("CombatFeedback")

local Settings = CombatAnimationConfig.Settings
local DamageResults = CombatStates.DamageResults

local SLOT_ATTACK = "Attack"
local SLOT_BLOCK_START = "BlockStart"
local SLOT_BLOCK_LOOP = "BlockLoop"
local SLOT_BLOCK_HIT = "BlockHit"
local SLOT_PARRY = "Parry"

-- Слоты, из которых состоит блок (для проверки "блок уже показывается")
local BLOCK_SLOTS = {
    [SLOT_BLOCK_START] = true,
    [SLOT_BLOCK_LOOP] = true,
    [SLOT_PARRY] = true,
}

-- Animator и загруженные треки относятся только к текущему персонажу.
local animator = nil
local characterHumanoid = nil
local tracks = {}     -- [slot .. "|" .. animationId] = AnimationTrack
local animations = {} -- [slot .. "|" .. animationId] = Animation (для предзагрузки)

-- Сейчас проигрываемая боевая анимация (одна: бой не смешивает несколько поз сразу)
local activeSlot = nil
local activeTrack = nil

-- Короткая реакция BlockHit поверх активной позы блока
local reactionTrack = nil

-- Последний показанный вариант Hit (чтобы одна и та же реакция не шла подряд)
local lastHitSlot = nil

-- Последнее состояние, сообщённое сервером (нужно, чтобы решить, что делать после Parry)
local currentState = CombatStates.Idle

-- Меняется при любой остановке/замене активной анимации. Отложенные переходы
-- (BlockStart -> BlockLoop, Parry -> BlockLoop) проверяют его и не срабатывают,
-- если за это время анимация уже сменилась (например, игрок отпустил блок).
local playToken = 0
local unarmedIdleExpiresAt = 0
local unarmedIdleToken = 0
local characterConnections = {}

-- Состояние от сервера, пришедшее раньше, чем загрузился Animator
local pendingPayload = nil
local animatedAttackId = nil
local animatedDodgeId = nil
local animatedStunId = nil
local animatedStunRevision = nil

local function debugLog(...)
    if Settings.DebugLogging then
        print("[CombatAnimation]", ...)
    end
end

-- Оружие определяем через WeaponRegistry, как сервер и CombatController.
-- Для выбора анимации достаточно; урон и таймингами всё равно занимается сервер.
local function getWeaponId()
    return (WeaponRegistry.ResolveFromCharacter(player.Character))
end

local function hasAnimation(slot, weaponId)
    return CombatAnimationConfig.GetAnimationId(slot, weaponId) ~= nil
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

    if CombatAnimationConfig.IsAttackSlot(slot) then
        AttackAnimationSync.Preload(animationId)
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
    playToken += 1

    if activeTrack then
        AttackAnimationSync.Stop(activeTrack)
        CombatReactionSync.Stop(activeTrack)
        activeTrack:Stop(fadeTime or Settings.FadeOutTime)
    end

    activeTrack = nil
    activeSlot = nil
end

local function stopReaction(fadeTime)
    if reactionTrack then
        reactionTrack:Stop(fadeTime or Settings.FadeOutTime)
    end

    reactionTrack = nil
end

-- Забывает все треки текущего персонажа (респавн, удаление персонажа).
local function resetTracks()
    stopActive(0)
    stopReaction(0)

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
    unarmedIdleToken += 1
    unarmedIdleExpiresAt = 0

    for _, connection in ipairs(characterConnections) do
        connection:Disconnect()
    end

    table.clear(characterConnections)

    tracks = {}
    animations = {}
    animator = nil
    characterHumanoid = nil
    pendingPayload = nil
    lastHitSlot = nil
    animatedDodgeId = nil
    animatedStunId = nil
    animatedStunRevision = nil
    currentState = CombatStates.Idle
end

-- Заранее загружает все назначенные анимации, чтобы первый удар не запаздывал.
local function preload()
    local toPreload = {}

    local function add(slot, weaponId)
        local track = getTrack(slot, weaponId)

        if track then
            local animationId = CombatAnimationConfig.GetAnimationId(slot, weaponId)
            local animation = animations[slot .. "|" .. animationId]

            if animation then
                table.insert(toPreload, animation)
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

    task.spawn(function()
        pcall(function()
            ContentProvider:PreloadAsync(toPreload)
        end)
    end)
end

-- ВОСПРОИЗВЕДЕНИЕ --------------------------------------------------------

-- Проигрывает основную анимацию (заменяет предыдущую).
--   startAt    - с какой секунды начать (восстановление при Sync); nil = с начала;
--   onFinished - вызывается незадолго до конца НЕ зацикленной анимации (за LoopBlendTime),
--                если за это время она не была заменена. Так следующая анимация
--                плавно перекрывает конец текущей.
-- Возвращает true, если анимация запущена.
local function playSlot(slot, weaponId, startAt, onFinished)
    local track = getTrack(slot, weaponId)

    -- Повторное подтверждение (например, Sync во время блока): не перезапускаем.
    -- Атака и парирование при повторе начинаются сначала.
    if track
        and track == activeTrack
        and track.IsPlaying
        and not CombatAnimationConfig.IsAttackSlot(slot)
        and slot ~= SLOT_PARRY
    then
        return true
    end

    if track and track == activeTrack then
        stopActive(0) -- та же анимация подряд (новый удар): начинаем сначала
    else
        stopActive()
    end

    if not track then
        debugLog(slot, "has no animation assigned")
        return false
    end

    local length = track.Length

    startAt = startAt or 0

    if startAt > 0 and length > 0 then
        if track.Looped then
            startAt %= length
        elseif startAt >= length then
            return false -- к моменту восстановления анимация уже закончилась
        end
    end

    local token = playToken

    track:Play(Settings.FadeInTime)

    if startAt > 0 then
        track.TimePosition = startAt
    end

    activeTrack = track
    activeSlot = slot

    if onFinished then
        local remaining = length - startAt
        local delay = 0

        if remaining > 0 then
            delay = remaining / math.max(track.Speed, 0.01) - Settings.LoopBlendTime
        end

        task.delay(math.max(delay, 0), function()
            if token == playToken then
                onFinished()
            end
        end)
    end

    debugLog("play", slot, weaponId or "", startAt > 0 and string.format("from %.2f", startAt) or "")

    return true
end
local function isUnarmedIdleAllowed()
    if not animator or not characterHumanoid then
        return false
    end

    if characterHumanoid.Health <= 0 then
        return false
    end

    if currentState ~= CombatStates.Idle then
        return false
    end

    if getWeaponId() ~= "Unarmed" then
        return false
    end

    if characterHumanoid.MoveDirection.Magnitude > 0.05 then
        return false
    end

    local humanoidState = characterHumanoid:GetState()

    if humanoidState == Enum.HumanoidStateType.Jumping
        or humanoidState == Enum.HumanoidStateType.Freefall
        or humanoidState == Enum.HumanoidStateType.FallingDown
        or humanoidState == Enum.HumanoidStateType.Swimming
        or humanoidState == Enum.HumanoidStateType.Climbing
        or humanoidState == Enum.HumanoidStateType.Seated
    then
        return false
    end

    return true
end

local function refreshUnarmedIdle()
    if unarmedIdleExpiresAt <= os.clock() then
        if activeSlot == "UnarmedIdle" then
            stopActive(Settings.UnarmedIdleFadeOut)
        end

        return
    end

    if isUnarmedIdleAllowed() then
        playSlot("UnarmedIdle", "Unarmed")
    elseif activeSlot == "UnarmedIdle" then
        stopActive(Settings.UnarmedIdleFadeOut)
    end
end

local function startUnarmedIdleWindow()
    if getWeaponId() ~= "Unarmed" then
        return
    end

    unarmedIdleToken += 1
    local token = unarmedIdleToken

    unarmedIdleExpiresAt = os.clock() + Settings.UnarmedIdleDuration

    refreshUnarmedIdle()

    task.delay(Settings.UnarmedIdleDuration, function()
        if token ~= unarmedIdleToken then
            return
        end

        unarmedIdleExpiresAt = 0

        if activeSlot == "UnarmedIdle" then
            stopActive(Settings.UnarmedIdleFadeOut)
        end
    end)
end

-- Короткая реакция поверх текущей позы. Основную анимацию не трогает.
local function playReaction(slot, weaponId)
    local track = getTrack(slot, weaponId)

    if not track then
        return
    end

    if reactionTrack and reactionTrack ~= track then
        reactionTrack:Stop(Settings.FadeOutTime)
    end

    if track.IsPlaying then
        track:Stop(0) -- повторная реакция начинается сначала
    end

    reactionTrack = track
    track:Play(Settings.FadeInTime)

    debugLog("reaction", slot)
end

-- БЛОК -------------------------------------------------------------------

local function startBlockLoop(weaponId)
    if currentState ~= CombatStates.Blocking then
        return
    end

    if hasAnimation(SLOT_BLOCK_LOOP, weaponId) then
        playSlot(SLOT_BLOCK_LOOP, weaponId)
    end
end

-- Вход в блок после подтверждения сервера: BlockStart, затем BlockLoop.
-- elapsed - сколько блок уже длится на сервере (при Sync); при обычном входе 0.
local function enterBlock(weaponId, elapsed)
    -- Блок уже показывается (повторный Sync): ничего не перезапускаем
    if BLOCK_SLOTS[activeSlot] and activeTrack and activeTrack.IsPlaying then
        return
    end

    local hasStart = hasAnimation(SLOT_BLOCK_START, weaponId)
    local hasLoop = hasAnimation(SLOT_BLOCK_LOOP, weaponId)

    if not hasStart and not hasLoop then
        stopActive() -- блока нет в анимациях: не оставляем позу атаки
        return
    end

    local startTrack = hasStart and getTrack(SLOT_BLOCK_START, weaponId) or nil
    local startLength = startTrack and startTrack.Length or 0

    -- Игрок мог отпустить блок во время BlockStart: тогда придёт Idle, и playToken
    -- отменит переход к BlockLoop (весь цикл не доигрывается).
    if startTrack and elapsed < startLength - Settings.LoopBlendTime then
        playSlot(SLOT_BLOCK_START, weaponId, elapsed, function()
            startBlockLoop(weaponId)
        end)
    else
        startBlockLoop(weaponId)
    end
end

local function applyStunReaction(snapshot, weaponId)
    if not snapshot or snapshot.EndsAt <= workspace:GetServerTimeNow() then
        return
    end

    if animatedStunId ~= snapshot.Id or animatedStunRevision ~= snapshot.Revision then
        animatedStunId = snapshot.Id
        animatedStunRevision = snapshot.Revision
        stopReaction(0)
        local slot = CombatAnimationConfig.GetStunSlot(snapshot.Source, weaponId, lastHitSlot)
        if snapshot.Source == "Hit" and slot then
            lastHitSlot = slot
        end
        if not slot or not playSlot(slot, weaponId) then
            stopActive()
            return
        end
    end

    if activeTrack and CombatAnimationConfig.IsStunSlot(activeSlot) then
        CombatReactionSync.Update(activeTrack, snapshot)
    end
end

-- СОСТОЯНИЕ ОТ СЕРВЕРА ---------------------------------------------------

-- restoring = true: это снимок состояния (Sync или отложенное сообщение), а не переход.
local function applyState(payload, restoring)
    local state = payload.State
    local elapsed = type(payload.Elapsed) == "number" and math.max(payload.Elapsed, 0) or 0
    local weaponId = getWeaponId()

    if activeTrack and (
        (CombatAnimationConfig.IsAttackSlot(activeSlot) and state ~= CombatStates.Attacking)
        or (CombatAnimationConfig.IsStunSlot(activeSlot) and state ~= CombatStates.Stunned)
        or (BLOCK_SLOTS[activeSlot] and state ~= CombatStates.Blocking)
        or (CombatAnimationConfig.IsDodgeSlot(activeSlot) and state ~= CombatStates.Dodging)
    ) then
        stopActive(0.05)
    end
    if state ~= CombatStates.Blocking then
        stopReaction(0.05)
    end

    if state == CombatStates.Attacking then
        if payload.AttackId ~= nil and payload.AttackId ~= animatedAttackId then
            animatedAttackId = payload.AttackId
            unarmedIdleToken += 1
            unarmedIdleExpiresAt = 0
            local moveId = payload.MoveId
            local startAt = restoring and elapsed or nil
            if not (moveId ~= SLOT_ATTACK and CombatAnimationConfig.IsAttackSlot(moveId)
                and playSlot(moveId, weaponId, startAt))
            then
                playSlot(SLOT_ATTACK, weaponId, startAt)
            end
            if not restoring and activeTrack and CombatAnimationConfig.IsAttackSlot(activeSlot)
                and characterHumanoid then
                LocalSFX:AttackStarted(characterHumanoid.Parent, weaponId, moveId or "Light1", payload.AttackId)
            end
        end
        if activeTrack and CombatAnimationConfig.IsAttackSlot(activeSlot) then
            AttackAnimationSync.Update(activeTrack, payload.AttackAnimation)
        end
    elseif state == CombatStates.Blocking then
        enterBlock(weaponId, restoring and elapsed or 0)
    elseif state == CombatStates.Stunned then
        applyStunReaction(payload.StunAnimation, weaponId)
    elseif state == CombatStates.Dodging then
        if characterHumanoid and characterHumanoid:GetAttribute(DashConfig.MotionFinishedAttribute) then
            if activeTrack and CombatAnimationConfig.IsDodgeSlot(activeSlot) then
                stopActive(DashConfig.HandoffAnimationFade)
            end
            return -- delayed confirmations must not cover locomotion with an old dash clip
        end
        local snapshot = payload.DodgeAnimation
        if snapshot and snapshot.Id ~= animatedDodgeId then
            animatedDodgeId = snapshot.Id
            local slot = CombatAnimationConfig.GetDodgeSlot(snapshot.DirectionId, weaponId)
            if slot then
                playSlot(slot, weaponId)
            else
                stopActive()
            end
        end
        if snapshot and activeTrack and CombatAnimationConfig.IsDodgeSlot(activeSlot) then
            CombatReactionSync.Update(activeTrack, snapshot)
        end
    elseif state == CombatStates.Idle then
        if payload.OldState == CombatStates.Attacking
            and weaponId == "Unarmed"
        then
            startUnarmedIdleWindow()
        else
            refreshUnarmedIdle()

            if unarmedIdleExpiresAt <= os.clock() then
                stopActive()
            end
        end
    elseif state == CombatStates.Dead or state == CombatStates.Ragdolled then
        stopActive()
        stopReaction()
    end
end

local function onStateChanged(payload)
    if type(payload) ~= "table" or type(payload.State) ~= "string" then
        return
    end

    currentState = payload.State

    -- Animator ещё не готов (персонаж только появился): запоминаем и применим позже
    if not animator then
        pendingPayload = payload
        return
    end

    applyState(payload, payload.Sync == true)
end

CombatStateChanged.OnClientEvent:Connect(onStateChanged)

CombatAnimationConfig.WarnIfInvalid("client")

-- РЕЗУЛЬТАТ УДАРА ПО СВОЕМУ ПЕРСОНАЖУ -------------------------------------

local function onFeedback(payload)
    if type(payload) ~= "table" then
        return
    end

    if not animator or (characterHumanoid and characterHumanoid.Health <= 0) then
        return
    end

    local weaponId = getWeaponId()

    if payload.Kind == "Reaction" then
        -- Stun reactions are driven by authoritative state, avoiding cross-remote races.
        return
    end

    if payload.Kind ~= "Received" then
        return
    end

    if payload.Result == DamageResults.Parried then
        -- Защищающийся парировал удар: Parry заменяет блок, затем снова BlockLoop.
        -- Без назначенной анимации блок не трогаем. Реакция BlockHit гасится, чтобы не
        -- перекрывать Parry.
        if currentState == CombatStates.Blocking and hasAnimation(SLOT_PARRY, weaponId) then
            stopReaction(0)

            playSlot(SLOT_PARRY, weaponId, nil, function()
                startBlockLoop(weaponId)
            end)
        end

    elseif payload.Result == DamageResults.Blocked then
        if currentState == CombatStates.Blocking then
            playReaction(SLOT_BLOCK_HIT, weaponId)
        end


    end
end

CombatFeedback.OnClientEvent:Connect(onFeedback)

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
    characterHumanoid = humanoid
    table.insert(characterConnections, humanoid:GetAttributeChangedSignal(DashConfig.MotionFinishedAttribute):Connect(function()
        if humanoid:GetAttribute(DashConfig.MotionFinishedAttribute)
            and activeTrack and CombatAnimationConfig.IsDodgeSlot(activeSlot) then
            stopActive(DashConfig.HandoffAnimationFade)
        end
    end))
        table.insert(
        characterConnections,
        humanoid.Running:Connect(function(speed)
            if speed > 0.1 then
                if activeSlot == "UnarmedIdle" then
                    stopActive(Settings.UnarmedIdleFadeOut)
                end
            else
                refreshUnarmedIdle()
            end
        end)
    )

    table.insert(
        characterConnections,
        humanoid.StateChanged:Connect(function(_, newState)
            if newState == Enum.HumanoidStateType.Jumping
                or newState == Enum.HumanoidStateType.Freefall
            then
                if activeSlot == "UnarmedIdle" then
                    stopActive(Settings.UnarmedIdleFadeOut)
                end
            else
                refreshUnarmedIdle()
            end
        end)
    )

    local function onEquipmentChanged(child)
        if child:IsA("Tool") then
            task.defer(refreshUnarmedIdle)
        end
    end

    table.insert(
        characterConnections,
        character.ChildAdded:Connect(onEquipmentChanged)
    )

    table.insert(
        characterConnections,
        character.ChildRemoved:Connect(onEquipmentChanged)
    )

    -- Смерть всегда обрывает боевую анимацию (сервер может сообщить о ней позже)
    humanoid.Died:Connect(function()
        stopActive()
        stopReaction()
    end)

    preload()

    -- Sync или переход, пришедший, пока загружался Animator
    if pendingPayload then
        local payload = pendingPayload

        pendingPayload = nil
        applyState(payload, true)
    end
end

player.CharacterAdded:Connect(bindCharacter)

player.CharacterRemoving:Connect(function()
    resetTracks()
end)

if player.Character then
    task.spawn(bindCharacter, player.Character)
end
