-- Maps published animation marker intervals onto authoritative attack phases.
local AnimationClipProvider = game:GetService("AnimationClipProvider")
local RunService = game:GetService("RunService")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local AttackAnimationSync = {}
local Clips = {}
local Sessions = {}
local PhaseOrder = { Startup = 1, Active = 2, Recovery = 3 }
local PhaseNames = { "Startup", "Active", "Recovery" }

-- Correct small clock/packet drift without rewinding the animation.
local SPEED_BLEND_TIME = 0.045
local DRIFT_CORRECTION_TIME = 0.12
local MAX_SPEED_CORRECTION = 0.35
local INITIAL_SEEK_WINDOW = 0.05

local function IsFinite(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function ReadMarkers(clip)
    if not clip:IsA("KeyframeSequence") then
        return nil, "expected a KeyframeSequence animation"
    end

    local times = {}
    local length = 0
    local keyframes = clip:GetKeyframes()
    if #keyframes == 0 then
        return nil, "provider returned no keyframes"
    end

    local found = {}
    for _, keyframe in ipairs(keyframes) do
        length = math.max(length, keyframe.Time)
        for _, marker in ipairs(keyframe:GetMarkers()) do
            local name = string.lower(marker.Name):match("^%s*(.-)%s*$")
            table.insert(found, string.format("%s@%.3f", marker.Name, keyframe.Time))
            if name == "activestart" or name == "recoverystart" then
                if times[name] ~= nil then
                    return nil, "duplicate marker " .. name
                end
                times[name] = keyframe.Time
            end
        end
    end

    local active = times.activestart
    local recovery = times.recoverystart
    if not active or not recovery or active < 0 or recovery <= active or recovery > length then
        return nil, string.format(
            "expected 0 <= activestart < recoverystart <= length; active=%s recovery=%s length=%.3f; events=[%s]",
            tostring(active), tostring(recovery), length,
            table.concat(found, ", ", 1, math.min(#found, 12))
        )
    end
    return { Active = active, Recovery = recovery, Length = length }
end

function AttackAnimationSync.Preload(animationId)
    if Clips[animationId] then
        return
    end

    local entry = { Ready = false, Clips = {} }
    Clips[animationId] = entry
    task.spawn(function()
        local reason
        -- Runtime clip caching can return empty/stripped keyframes.
        -- Retry twice, then request the source sequence for marker metadata.
        for attempt = 1, 3 do
            local ok, clip = pcall(function()
                if attempt < 3 then
                    return AnimationClipProvider:GetAnimationClipAsync(animationId)
                end
                return KeyframeSequenceProvider:GetKeyframeSequenceAsync(animationId)
            end)
            if ok then
                -- Provider objects may share animation data with playing tracks.
                table.insert(entry.Clips, clip)
                local parsed, data, parseReason = pcall(ReadMarkers, clip)
                if parsed then
                    entry.Data = data
                    reason = parseReason
                else
                    reason = data
                end
            else
                reason = clip
            end
            if entry.Data then
                break
            end
            if attempt < 3 then
                task.wait(0.15)
            end
        end

        entry.Ready = true
        if entry.Data then
            print(string.format(
                "[AttackAnimationSync] %s markers ready: active=%.3f recovery=%.3f length=%.3f",
                animationId, entry.Data.Active, entry.Data.Recovery, entry.Data.Length
            ))
        else
            warn("[AttackAnimationSync]", animationId, reason, "- using ordinary playback")
        end
    end)
end

-- Follow planned phase boundaries while authoritative phase messages are in transit.
-- Every received phase supplies a fresh server-clock anchor.
local function SamplePhase(phase, data, now)
    local elapsed = math.max(0, now - phase.StartedAt)
    local first = PhaseOrder[phase.Phase]
    local boundaries = { 0, data.Active, data.Recovery, data.Length }
    local duration = phase.Duration

    for index = first, 3 do
        local from, to = boundaries[index], boundaries[index + 1]
        if duration > 0 and elapsed < duration then
            local speed = (to - from) / duration
            return from + speed * elapsed, speed, false
        end

        elapsed = math.max(0, elapsed - duration)
        if index == 3 then
            return data.Length, 0, true
        end

        local nextDuration = phase.Timing and phase.Timing[PhaseNames[index + 1]]
        if not IsFinite(nextDuration) or nextDuration < 0 then
            -- Older snapshots have no forecast. Keep moving until the next update.
            local speed = duration > 0 and (to - from) / duration or 1
            return to, speed, false
        end
        duration = nextDuration
    end
end

local function Apply(session, deltaTime)
    local track = session.Track
    if track.Length <= 0 then
        return
    end

    local entry = Clips[track.Animation.AnimationId]
    if not entry or not entry.Ready or not entry.Data then
        return
    end

    if not track.IsPlaying then
        AttackAnimationSync.Stop(track)
        return
    end

    local now = workspace:GetServerTimeNow()
    local position, baseSpeed, finished = SamplePhase(session.Phase, entry.Data, now)
    if finished then
        AttackAnimationSync.Stop(track)
        track:Stop(0.05)
        return
    end

    if not session.Applied then
        -- Align a newly started/restored track once. Late metadata loads catch up
        -- through speed correction, avoiding a mid-swing seek.
        if now - session.CreatedAt <= INITIAL_SEEK_WINDOW then
            track.TimePosition = math.clamp(position, 0, math.max(0, track.Length - 0.0001))
        end
        session.Applied = true
        session.Speed = baseSpeed
    end

    local error = position - track.TimePosition
    local correctionLimit = baseSpeed * MAX_SPEED_CORRECTION
    local correction = math.clamp(
        error / DRIFT_CORRECTION_TIME, -correctionLimit, correctionLimit
    )
    local targetSpeed = math.max(0, baseSpeed + correction)
    local blend = 1 - math.exp(-math.max(0, deltaTime) / SPEED_BLEND_TIME)
    session.Speed = session.Speed + (targetSpeed - session.Speed) * blend
    if math.abs(track.Speed - session.Speed) > 0.001 then
        track:AdjustSpeed(session.Speed)
    end
end

function AttackAnimationSync.Stop(track)
    local session = Sessions[track]
    if session then
        session.Connection:Disconnect()
        Sessions[track] = nil
        track:AdjustSpeed(1)
    end
end

function AttackAnimationSync.Update(track, phase)
    if type(phase) ~= "table" or not IsFinite(phase.AttackId)
        or not PhaseOrder[phase.Phase] or not IsFinite(phase.StartedAt)
        or not IsFinite(phase.Duration) or phase.Duration < 0
    then
        return
    end

    local session = Sessions[track]
    if session and (phase.AttackId < session.Phase.AttackId
        or (session.Phase.AttackId == phase.AttackId
            and (PhaseOrder[phase.Phase] < PhaseOrder[session.Phase.Phase]
                or phase.StartedAt < session.Phase.StartedAt)))
    then
        return
    end

    AttackAnimationSync.Preload(track.Animation.AnimationId)
    if session and session.Phase.AttackId ~= phase.AttackId then
        AttackAnimationSync.Stop(track)
        session = nil
    end

    if not session then
        session = {
            Track = track,
            CreatedAt = workspace:GetServerTimeNow(),
        }
        Sessions[track] = session
        session.Connection = RunService.Heartbeat:Connect(function(deltaTime)
            Apply(session, deltaTime)
        end)
    end
    session.Phase = table.clone(phase)
    session.Phase.Timing = type(phase.Timing) == "table" and table.clone(phase.Timing) or nil
    Apply(session, 0)
end

return AttackAnimationSync
