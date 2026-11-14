-- Боевые анимации NPC (тренировочных манекенов). Работает на сервере: Animator NPC принадлежит
-- серверу, поэтому анимации видят все игроки. Использует те же ID и настройки, что и клиентская
-- система игроков (CombatAnimationConfig), и те же боевые состояния (CombatStateService).
--
-- Сервис только показывает состояние: урон, блок и парирование решает CombatStateService.
--
-- Сейчас подключены блок и реакции (этап 2):
--   Blocking                 -> BlockStart, затем BlockLoop
--   Parried (удар парирован) -> Parry, затем возврат в BlockLoop
--   Blocked (удар в блок)    -> BlockHit, затем возврат в BlockLoop
--   Hit (полный урон)        -> Hit (кроме состояний из Settings.SuppressHitDuring)
--   Idle / Dead              -> анимация останавливается
--   Attacking (новый удар)   -> Attack (одна анимация на все фазы удара)
--
-- Логика повторяет CombatAnimationController (клиент игроков). Если правила переходов
-- изменятся, менять нужно оба места; позже её можно вынести в общий модуль.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage.Shared.Config.CombatConfig)
local CombatAnimationConfig = require(ReplicatedStorage.Shared.Config.CombatAnimationConfig)
local CombatStates = require(ReplicatedStorage.Shared.Constants.CombatStates)

local CombatStateService = require(script.Parent.CombatStateService)

local NPCCombatAnimationService = {}

local Settings = CombatAnimationConfig.Settings
local DamageResults = CombatStates.DamageResults

-- Сколько секунд ждём, пока загрузится длина анимации (она неизвестна до загрузки ассета)
local LENGTH_WAIT_TIMEOUT = 2

local BLOCK_SLOTS = {
    BlockStart = true,
    BlockLoop = true,
    BlockHit = true,
    Parry = true,
}

local Entries = {} -- [model] = entry
local initialized = false

local function Log(...)
    if Settings.DebugLogging then
        print("[NPCCombatAnimation]", ...)
    end
end

-- ТРЕКИ ------------------------------------------------------------------

local function GetTrack(entry, slot)
    local animationId = CombatAnimationConfig.GetAnimationId(slot, CombatConfig.UnarmedId)

    if not animationId then
        return nil
    end

    local key = slot .. "|" .. animationId
    local cached = entry.Tracks[key]

    if cached ~= nil then
        return cached or nil -- false = загрузка уже провалилась
    end

    local animation = Instance.new("Animation")
    animation.AnimationId = animationId

    local ok, track = pcall(function()
        return entry.Animator:LoadAnimation(animation)
    end)

    if not ok then
        warn("[NPCCombatAnimation] Could not load", slot, animationId, track)
        animation:Destroy()
        entry.Tracks[key] = false

        return nil
    end

    local slotSettings = CombatAnimationConfig.Slots[slot]

    if slotSettings then
        track.Priority = slotSettings.Priority
        track.Looped = slotSettings.Looped
    end

    entry.Tracks[key] = track
    entry.Animations[key] = animation

    return track
end

local function StopActive(entry, fadeTime)
    -- Новый токен отменяет все отложенные переходы (BlockStart -> BlockLoop и т.п.)
    entry.Token += 1

    local track = entry.ActiveTrack

    entry.ActiveTrack = nil
    entry.ActiveSlot = nil

    if track then
        track:Stop(fadeTime or Settings.FadeOutTime)
    end
end

-- Запускает трек как активную анимацию. onFinished вызывается незадолго до её конца
-- (за LoopBlendTime), чтобы следующая анимация включилась плавно, без рывка.
local function StartTrack(entry, slot, track, onFinished)
    entry.Token += 1

    local token = entry.Token

    track:Play(Settings.FadeInTime)

    entry.ActiveTrack = track
    entry.ActiveSlot = slot

    Log(entry.Model.Name, "play", slot)

    if not onFinished then
        return
    end

    task.spawn(function()
        local waited = 0

        -- Длина известна только после загрузки ассета
        while track.Length <= 0 and waited < LENGTH_WAIT_TIMEOUT do
            waited += task.wait()
        end

        if entry.Token ~= token then
            return
        end

        local remaining = math.max(0, track.Length - Settings.LoopBlendTime - waited)

        if remaining > 0 then
            task.wait(remaining)
        end

        if entry.Token ~= token then
            return -- анимацию прервали, цепочку не продолжаем
        end

        onFinished()
    end)
end

-- Анимация состояния: заменяет текущую. Если анимации нет, текущая всё равно
-- останавливается (состояние сменилось), а onFinished выполняется сразу.
local function PlaySlot(entry, slot, opts)
    opts = opts or {}

    local track = GetTrack(entry, slot)

    if track and track == entry.ActiveTrack and track.IsPlaying and opts.KeepIfPlaying then
        return
    end

    StopActive(entry)

    if not track then
        Log(entry.Model.Name, slot, "has no animation assigned")

        if opts.OnFinished then
            opts.OnFinished()
        end

        return
    end

    StartTrack(entry, slot, track, opts.OnFinished)
end

-- Реакция на удар: прерывает текущую анимацию ТОЛЬКО если для неё есть анимация.
local function PlayReaction(entry, slot, onFinished)
    local track = GetTrack(entry, slot)

    if not track then
        Log(entry.Model.Name, slot, "has no animation assigned, current animation kept")
        return
    end

    StopActive(entry)
    StartTrack(entry, slot, track, onFinished)
end

-- БЛОК -------------------------------------------------------------------

local function PlayBlockLoop(entry)
    PlaySlot(entry, "BlockLoop", { KeepIfPlaying = true })
end

-- Возврат в удержание блока: только если сервер всё ещё считает NPC блокирующим.
local function ResumeBlock(entry)
    if entry.Model.Parent and CombatStateService:GetState(entry.Model) == CombatStates.Blocking then
        PlayBlockLoop(entry)
    end
end

local function PlayBlock(entry)
    if not GetTrack(entry, "BlockStart") then
        PlayBlockLoop(entry)
        return
    end

    PlaySlot(entry, "BlockStart", {
        KeepIfPlaying = true,
        OnFinished = function()
            ResumeBlock(entry)
        end,
    })
end

-- СОБЫТИЯ БОЯ ------------------------------------------------------------

local function OnStateChanged(character, newState, oldState)
    local entry = Entries[character]

    if not entry then
        return
    end

    if newState == CombatStates.Attacking then
        -- Смена фаз удара состояние не меняет, поэтому сюда попадает только начало нового удара
        if oldState ~= CombatStates.Attacking then
            PlaySlot(entry, "Attack")
        end
    elseif newState == CombatStates.Blocking then
        -- Блок уже показывается (или идёт его реакция): повтор события ничего не меняет
        if not (entry.ActiveSlot and BLOCK_SLOTS[entry.ActiveSlot]) then
            PlayBlock(entry)
        end
    elseif newState == CombatStates.Idle or newState == CombatStates.Dead then
        StopActive(entry)
    end
end

local function OnDamageApplied(character, outcome)
    local entry = Entries[character]

    if not entry then
        return
    end

    local state = CombatStateService:GetState(character)
    local result = outcome.Result

    local function backToBlock()
        ResumeBlock(entry)
    end

    if result == DamageResults.Parried then
        if state == CombatStates.Blocking then
            PlayReaction(entry, "Parry", backToBlock)
        end
    elseif result == DamageResults.Blocked then
        if state == CombatStates.Blocking then
            PlayReaction(entry, "BlockHit", backToBlock)
        end
    elseif result == DamageResults.Hit then
        if not Settings.SuppressHitDuring[state] then
            PlayReaction(entry, "Hit", backToBlock)
        end
    end
end

-- ПУБЛИЧНЫЙ API ----------------------------------------------------------

-- Подключает NPC к системе анимаций. model - Model с Humanoid (R6/R15).
-- Возвращает true, если анимации NPC будут работать.
function NPCCombatAnimationService:Register(model)
    if Entries[model] then
        return true
    end

    local humanoid = model:FindFirstChildOfClass("Humanoid")

    if not humanoid then
        warn("[NPCCombatAnimation] No Humanoid in", model.Name)
        return false
    end

    -- Animator есть у стандартных рига; для самодельной модели создаём на сервере
    local animator = humanoid:FindFirstChildOfClass("Animator")

    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end

    local entry = {
        Model = model,
        Animator = animator,
        Tracks = {},
        Animations = {},
        ActiveTrack = nil,
        ActiveSlot = nil,
        Token = 0,
    }

    Entries[model] = entry

    -- Удаление модели освобождает всё без участия вызывающего кода
    model.Destroying:Once(function()
        NPCCombatAnimationService:Unregister(model)
    end)

    return true
end

function NPCCombatAnimationService:Unregister(model)
    local entry = Entries[model]

    if not entry then
        return
    end

    Entries[model] = nil

    StopActive(entry, 0)

    for _, track in pairs(entry.Tracks) do
        if track then
            pcall(function()
                track:Destroy()
            end)
        end
    end

    for _, animation in pairs(entry.Animations) do
        animation:Destroy()
    end
end

function NPCCombatAnimationService:Init()
    -- Повторный вызов не должен удваивать подписки
    if initialized then
        return
    end

    initialized = true

    CombatStateService:OnStateChanged(OnStateChanged)
    CombatStateService:OnDamageApplied(OnDamageApplied)

    print("[NPCCombatAnimationService] Initialized")
end

return NPCCombatAnimationService
