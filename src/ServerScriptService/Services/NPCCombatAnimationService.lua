-- NPC reactions follow authoritative stun source, revision and expiry.
-- Attack and defense tracks use the same shared animation configuration.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage.Shared.Config.CombatConfig)
local CombatAnimationConfig = require(ReplicatedStorage.Shared.Config.CombatAnimationConfig)
local CombatStates = require(ReplicatedStorage.Shared.Constants.CombatStates)

local CombatStateService = require(script.Parent.CombatStateService)
local AttackAnimationSync = require(ReplicatedStorage.Shared.Combat.AttackAnimationSync)
local CombatReactionSync = require(ReplicatedStorage.Shared.Combat.CombatReactionSync)

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

    if CombatAnimationConfig.IsAttackSlot(slot) then
        AttackAnimationSync.Preload(animationId)
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
        AttackAnimationSync.Stop(track)
        CombatReactionSync.Stop(track)
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

local function ApplyStunReaction(entry)
    local snapshot = CombatStateService:GetStunAnimationState(entry.Model)
    if not snapshot or snapshot.EndsAt <= workspace:GetServerTimeNow() then
        return
    end

    if entry.StunId ~= snapshot.Id or entry.StunRevision ~= snapshot.Revision then
        entry.StunId = snapshot.Id
        entry.StunRevision = snapshot.Revision
        local slot = CombatAnimationConfig.GetStunSlot(
            snapshot.Source, CombatConfig.UnarmedId, entry.LastHitSlot
        )
        if snapshot.Source == "Hit" and slot then
            entry.LastHitSlot = slot
        end
        if not slot then
            StopActive(entry)
            return
        end
        PlaySlot(entry, slot)
    end

    if entry.ActiveTrack and CombatAnimationConfig.IsStunSlot(entry.ActiveSlot) then
        CombatReactionSync.Update(entry.ActiveTrack, snapshot)
    end
end

local function OnStateChanged(character, newState, oldState)
    local entry = Entries[character]

    if not entry then
        return
    end

    if newState == CombatStates.Attacking then
        local attackId, moveId = CombatStateService:GetAttackIdentity(character)
        if attackId and entry.AnimatedAttackId ~= attackId then
            entry.AnimatedAttackId = attackId

            local slot = moveId
            if not CombatAnimationConfig.IsAttackSlot(slot) or not GetTrack(entry, slot) then
                slot = "Light1"
            end
            if not GetTrack(entry, slot) then
                slot = "Attack"
            end
            PlaySlot(entry, slot)
            if entry.ActiveTrack then
                AttackAnimationSync.Update(
                    entry.ActiveTrack,
                    CombatStateService:GetAttackAnimationState(character)
                )
            end
        end
    elseif newState == CombatStates.Blocking then
        -- Блок уже показывается (или идёт его реакция): повтор события ничего не меняет
        if not (entry.ActiveSlot and BLOCK_SLOTS[entry.ActiveSlot]) then
            PlayBlock(entry)
        end
    elseif newState == CombatStates.Idle or newState == CombatStates.Dead then
        StopActive(entry)
    elseif newState == CombatStates.Stunned then
        ApplyStunReaction(entry)
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
        LastHitSlot = nil,
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

function NPCCombatAnimationService:PlayReaction(model, slot)
    local entry = Entries[model]

    if not entry then
        return false
    end

    if slot == "Parried" or slot == "Stunned" then
        if CombatStateService:GetState(model) ~= CombatStates.Stunned then
            return false
        end
        ApplyStunReaction(entry)
    else
        PlayReaction(entry, slot)
    end

    return true
end

function NPCCombatAnimationService:Init()
    -- Повторный вызов не должен удваивать подписки
    if initialized then
        return
    end

    initialized = true

    CombatAnimationConfig.WarnIfInvalid("server")

    CombatStateService:OnStateChanged(OnStateChanged)
    CombatStateService:OnStunUpdated(function(character)
        local entry = Entries[character]
        if entry then
            ApplyStunReaction(entry)
        end
    end)
    CombatStateService:OnAttackPhaseChanged(function(character, _phase, attackId)
        local entry = Entries[character]
        if entry and entry.ActiveTrack and entry.AnimatedAttackId == attackId
            and CombatAnimationConfig.IsAttackSlot(entry.ActiveSlot)
        then
            AttackAnimationSync.Update(
                entry.ActiveTrack,
                CombatStateService:GetAttackAnimationState(character)
            )
        end
    end)
    CombatStateService:OnDamageApplied(OnDamageApplied)

    print("[NPCCombatAnimationService] Initialized")
end

return NPCCombatAnimationService
