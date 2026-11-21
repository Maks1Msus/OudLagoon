-- Plays non-looped reactions across the authoritative stun interval.
-- Looped ability-stun clips keep their normal cadence until the state ends.
local RunService = game:GetService("RunService")
local CombatReactionSync = {}
local Sessions = {}
local END_FADE_TIME = 0.05
local SPEED_BLEND_TIME = 0.045

local function IsFinite(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

function CombatReactionSync.Stop(track)
    local session = Sessions[track]
    if session then
        session.Connection:Disconnect()
        Sessions[track] = nil
        track:AdjustSpeed(1)
    end
end

local function Step(session, deltaTime)
    local track = session.Track
    local state = session.State
    local now = workspace:GetServerTimeNow()
    if now >= state.EndsAt then
        CombatReactionSync.Stop(track)
        track:Stop(END_FADE_TIME)
        return
    end
    if not track.IsPlaying then
        CombatReactionSync.Stop(track)
        return
    end
    local length = track.Length
    if length <= 0 then
        return
    end

    if track.Looped then
        if not session.Aligned then
            track.TimePosition = math.max(0, now - state.StartedAt) % length
            track:AdjustSpeed(1)
            session.Aligned = true
        end
        return
    end

    if not session.Aligned then
        local progress = math.clamp((now - state.StartedAt) / (state.EndsAt - state.StartedAt), 0, 1)
        track.TimePosition = math.min(length * progress, math.max(0, length - 0.002))
        session.Speed = length / (state.EndsAt - state.StartedAt)
        session.Aligned = true
    end
    local remaining = math.max(0, length - 0.002 - track.TimePosition)
    local targetSpeed = remaining / math.max(0.001, state.EndsAt - now)
    local blend = 1 - math.exp(-math.max(0, deltaTime) / SPEED_BLEND_TIME)
    session.Speed = session.Speed + (targetSpeed - session.Speed) * blend
    if remaining <= 0.001 then
        session.Speed = 0
    end
    track:AdjustSpeed(session.Speed)
end

function CombatReactionSync.Update(track, state)
    if type(state) ~= "table" or not IsFinite(state.Id) or not IsFinite(state.Revision)
        or not IsFinite(state.StartedAt) or not IsFinite(state.EndsAt)
        or state.EndsAt <= state.StartedAt
    then
        return
    end

    local session = Sessions[track]
    if session and (state.Id < session.State.Id
        or (state.Id == session.State.Id and state.Revision < session.State.Revision))
    then
        return
    end
    if session and (state.Id ~= session.State.Id or state.Revision ~= session.State.Revision) then
        CombatReactionSync.Stop(track)
        session = nil
    end
    if not session then
        session = { Track = track }
        Sessions[track] = session
        session.Connection = RunService.Heartbeat:Connect(function(deltaTime)
            Step(session, deltaTime)
        end)
    end
    session.State = table.clone(state)
    Step(session, 0)
end

return CombatReactionSync
