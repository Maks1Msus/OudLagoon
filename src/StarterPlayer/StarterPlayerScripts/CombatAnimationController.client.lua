-- Клиентская система боевых анимаций. Работает независимо от CombatController.
--
-- Источник правды - сервер: анимация запускается только после того, как сервер подтвердил
-- переход состояния (CombatStateChanged) или результат удара (CombatFeedback, Kind = "Received").
-- Эта система ничего не отправляет на сервер и не влияет на урон, кулдауны и тайминги.
--
-- Анимации проигрываются на Animator своего персонажа, поэтому другие игроки видят их
-- через стандартную репликацию Roblox.
--
-- Соответствие состояний и анимаций:
--   Attacking (переход из другого состояния) -> Attack (одна анимация на все фазы удара)
--   Blocking                                 -> BlockStart, затем BlockLoop (пока держится блок)
--   Stunned (переход состояния)              -> текущая поза (блок, атака) останавливается;
--                                               анимацию Stunned состояние само НЕ запускает
--   Dodging                                  -> Dodge
--   Idle / Dead                              -> боевая анимация останавливается
-- Смена фаз атаки (Startup/Active/Recovery) анимацию не перезапускает.
--
-- Результат удара по своему персонажу (CombatFeedback, Kind = "Received"):
--   Parried -> Parry заменяет блок, после неё снова включается BlockLoop;
--   Blocked -> BlockHit накладывается поверх блока (блок не прерывается);
--   Hit     -> один из Hit1..3 (getRandomHitSlot, без повтора подряд) поверх текущей позы,
--              кроме состояний из Settings.SuppressHitDuring (то же правило, что у NPC).
--
-- Явные реакции (CombatFeedback, Kind = "Reaction"):
--   Parried - мой удар парировали;
--   Stunned - меня оглушила способность (CombatService:ApplyAbilityStun). Это единственное,
--             что включает анимацию Stunned. Оглушение от удара и парирования её не включает.
--
-- Восстановление (Sync): ответ на Sync помечен Sync = true и содержит Elapsed (сколько секунд
-- состояние длится на сервере). Анимация запускается с этого места. Если Sync пришёл раньше,
-- чем загрузился Animator, он откладывается и применяется после загрузки.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContentProvider = game:GetService("ContentProvider")

local player = Players.LocalPlayer

local Shared = ReplicatedStorage:WaitForChild("Shared")

local CombatConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatConfig"))
local CombatAnimationConfig = require(Shared:WaitForChild("Config"):WaitForChild("CombatAnimationConfig"))
local CombatStates = require(Shared:WaitForChild("Constants"):WaitForChild("CombatStates"))
local WeaponRegistry = require(Shared:WaitForChild("Weapons"):WaitForChild("WeaponRegistry"))

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
local SLOT_PARRIED = "Parried"
local SLOT_STUNNED = "Stunned"

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

-- Короткая реакция (Hit / BlockHit), накладывается поверх активной анимации
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

-- Случайный слот Hit1..3 среди назначенных, не равный предыдущему. nil, если анимаций нет.
local function getRandomHitSlot(weaponId)
    local slot = CombatAnimationConfig.PickHitSlot(weaponId, lastHitSlot)

    if slot then
        lastHitSlot = slot
    end

    return slot
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
    currentState = CombatStates.Idle
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
        and slot ~= SLOT_ATTACK
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

-- СОСТОЯНИЕ ОТ СЕРВЕРА ---------------------------------------------------

-- restoring = true: это снимок состояния (Sync или отложенное сообщение), а не переход.
local function applyState(payload, restoring)
    local state = payload.State
    local elapsed = type(payload.Elapsed) == "number" and math.max(payload.Elapsed, 0) or 0
    local weaponId = getWeaponId()

    if state == CombatStates.Attacking then
        -- Событие со сменой фазы (без OldState) анимацию не запускает:
        -- запуск только на подтверждённом переходе в Attacking или при восстановлении.
        local isNewAttack = payload.OldState ~= nil and payload.OldState ~= CombatStates.Attacking

        if isNewAttack then
            unarmedIdleToken += 1
            unarmedIdleExpiresAt = 0

            if activeSlot == "UnarmedIdle" then
                stopActive()
            end
            playSlot(SLOT_ATTACK, weaponId)
        elseif restoring then
            -- Sync посреди удара: показываем атаку с текущего момента, если она ещё не идёт
            if not (activeSlot == SLOT_ATTACK and activeTrack and activeTrack.IsPlaying) then
                playSlot(SLOT_ATTACK, weaponId, elapsed)
            end
        end
    elseif state == CombatStates.Blocking then
        enterBlock(weaponId, restoring and elapsed or 0)
    elseif state == CombatStates.Stunned then
        -- Анимацию Stunned состояние не запускает. Но поза блока/атаки не должна оставаться.
        -- Реакции Parried/Stunned могли прийти раньше этого сообщения (разные события): их не трогаем.
        if activeSlot ~= SLOT_PARRIED and activeSlot ~= SLOT_STUNNED then
            stopActive()
        end
    elseif state == CombatStates.Dodging then
        playSlot("Dodge", weaponId, restoring and elapsed or nil)
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
    elseif state == CombatStates.Dead then
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
        if payload.Reaction == "Parried" then
            playSlot(SLOT_PARRIED, weaponId)
        elseif payload.Reaction == "Stunned" then
            if not playSlot(SLOT_STUNNED, weaponId) and activeSlot ~= SLOT_STUNNED then
                stopActive() -- анимации нет: хотя бы не оставляем позу блока/атаки
            end
        end

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

    elseif payload.Result == DamageResults.Hit then
        -- То же правило, что у NPC (Settings.SuppressHitDuring). Берём состояние в момент
        -- удара от сервера: к приходу Received currentState уже может быть Stunned от этого удара.
        local stateAtHit = type(payload.VictimState) == "string" and payload.VictimState or currentState

        if CombatAnimationConfig.ShouldPlayHit(stateAtHit) then
            local hitSlot = getRandomHitSlot(weaponId)

            if hitSlot then
                playReaction(hitSlot, weaponId)
            end
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