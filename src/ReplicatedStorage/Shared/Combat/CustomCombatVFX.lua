-- Client-only clones of artist templates. Never welds to or changes a gameplay part.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Renderer = {}
Renderer.__index = Renderer

local function Number(object, name, fallback, maximum)
    local value = object:GetAttribute(name)
    if type(value) ~= "number" or value ~= value or value < 0 then return fallback end
    return math.min(value, maximum)
end

local function Anchor(character, name)
    if name == "RightHand" or name == "LeftHand" then
        local hand = character:FindFirstChild(name)
        if hand and hand:IsA("BasePart") then return hand, CFrame.new() end
        local arm = character:FindFirstChild(name == "RightHand" and "Right Arm" or "Left Arm")
        if arm and arm:IsA("BasePart") then return arm, CFrame.new(0, -arm.Size.Y * 0.5, 0) end
    end
    return character:FindFirstChild("HumanoidRootPart"), CFrame.new()
end

local function FlatDirection(value, minSpeed)
    if typeof(value) ~= "Vector3" or value.X ~= value.X or value.Z ~= value.Z
        or math.abs(value.X) == math.huge or math.abs(value.Z) == math.huge then return nil end
    local flat = Vector3.new(value.X, 0, value.Z)
    return flat.Magnitude >= (minSpeed or 0.05) and flat.Unit or nil
end

local function EffectFrame(record, now, initial)
    local anchor = record.Anchor
    local base = anchor.CFrame
    if record.FaceVelocity then
        if not initial and not record.Stopped then
            record.Direction = FlatDirection(anchor.AssemblyLinearVelocity, 2) or record.Direction
        end
        base = CFrame.lookAt(anchor.Position, anchor.Position + record.Direction)
    end
    local cf = base * record.Offset
    if record.SpinDegrees then
        local t = math.clamp((now - record.StartedAt) / record.SpinDuration, 0, 1)
        local eased = 1 - (1 - t) ^ 3
        local spin = record.SpinDegrees * (math.pi / 180 * eased)
        cf = cf * CFrame.Angles(spin.X, spin.Y, spin.Z)
    end
    return cf
end

function Renderer.new(parent, config)
    return setmetatable({ Parent = parent, Config = config, Records = {}, Warned = {} }, Renderer)
end

function Renderer:Near(character, allowDead)
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local camera = workspace.CurrentCamera
    return character and character.Parent and root and humanoid and (allowDead or humanoid.Health > 0)
        and camera and (camera.CFrame.Position - root.Position).Magnitude <= self.Config.RenderDistance
end

function Renderer:Stop(character, scope, immediate)
    local now = workspace:GetServerTimeNow()
    for i = #self.Records, 1, -1 do
        local record = self.Records[i]
        if record.Character == character and (not scope or record.Scope == scope) then
            if immediate then
                record.Model:Destroy()
                table.remove(self.Records, i)
            elseif not record.Stopped then
                record.Stopped = true
                record.EndsAt = now
                for _, item in ipairs(record.Emitters) do item.Object.Enabled = false end
                for _, object in ipairs(record.Switches) do object.Enabled = false end
            end
        end
    end
end

function Renderer:Has(character, scope)
    for _, record in ipairs(self.Records) do
        if record.Character == character and record.Scope == scope and not record.Stopped then return true end
    end
    return false
end

function Renderer:Play(character, key, duration, scope, age, options)
    local config = self.Config
    local spec = config.Effects[key]
    if not spec or not config.Enabled or not self:Near(character, spec.AllowDead) then return false end
    local folder = ReplicatedStorage:FindFirstChild(config.FolderName)
    local template = folder and folder:FindFirstChild(spec.Template)
    if not template then
        if not self.Warned[key] then
            self.Warned[key] = true
            warn("[CustomCombatVFX] Missing template: " .. config.FolderName .. "/" .. spec.Template)
        end
        return false
    end
    if #template:GetDescendants() > config.MaxTemplateDescendants or not template.Archivable then return false end
    local anchor, handOffset = Anchor(character, spec.Anchor)
    if not anchor or not anchor:IsA("BasePart") then return false end
    self:Stop(character, scope)
    if #self.Records >= config.MaxEffects then return false end
    local clone = template:Clone()
    local model = Instance.new("Model")
    model.Name = "CustomCombatVFX_" .. key
    clone.Parent = model
    local carrier
    if clone:IsA("Attachment") or clone:IsA("ParticleEmitter") then
        carrier = Instance.new("Part")
        carrier.Size = Vector3.new(0.1, 0.1, 0.1)
        carrier.Transparency = 1
        carrier.Parent = model
        clone.Parent = carrier
    elseif clone:IsA("BasePart") then carrier = clone end
    local origin = carrier and carrier.CFrame or model:GetPivot()
    local now = workspace:GetServerTimeNow()
    duration = type(duration) == "number" and duration == duration and duration > 0
        and math.min(duration, 3) or (spec.Duration or 0.2)
    local record = { Character = character, Scope = scope, Model = model, Parts = {}, Emitters = {},
        Switches = {}, StartedAt = now - (age or 0), Tail = 0.15,
        EndsAt = spec.Loop and math.huge or now + math.max(0, duration - (age or 0)),
        Offset = handOffset * (spec.Offset or CFrame.new()), Anchor = anchor,
        AllowDead = spec.AllowDead, FaceVelocity = spec.FaceVelocity,
        Direction = FlatDirection(options and options.Direction)
            or FlatDirection(anchor.CFrame.LookVector) or Vector3.new(0, 0, -1),
        SpinDegrees = spec.SpinDegrees, SpinDuration = math.max(spec.SpinDuration or 0.3, 0.01) }
    local objects = model:GetDescendants()
    for _, object in ipairs(objects) do
        if object:IsA("LuaSourceContainer") or object:IsA("JointInstance") or object:IsA("Constraint") then
            object:Destroy()
        elseif object:IsA("BasePart") then
            object.Anchored = true
            object.CanCollide, object.CanTouch, object.CanQuery = false, false, false
            if object == carrier and spec.HideCarrier then object.Transparency = 1 end
            table.insert(record.Parts, { Object = object, Offset = origin:ToObjectSpace(object.CFrame),
                Transparency = object.Transparency })
        elseif object:IsA("ParticleEmitter") then
            object.Enabled = false
            local delay = Number(object, "EmitDelay", 0, 3)
            local emitDuration = Number(object, "EmitDuration", 0, 3)
            table.insert(record.Emitters, { Object = object, Delay = delay, Duration = emitDuration,
                Count = math.floor(Number(object, "EmitCount", config.DefaultEmitCount, 128)),
                Loop = spec.Loop == true or spec.Sustain == true })
            if not spec.Loop then
                record.EndsAt = math.max(record.EndsAt, record.StartedAt + delay + emitDuration + 0.03)
            end
            local tail = object.Lifetime.Max / math.max(object.TimeScale, 0.05)
            record.Tail = math.max(record.Tail, math.min(tail, config.MaxTail))
        elseif object:IsA("Beam") or object:IsA("Trail") then
            object.Enabled = false
            table.insert(record.Switches, object)
            if object:IsA("Trail") then record.Tail = math.max(record.Tail, math.min(object.Lifetime, config.MaxTail)) end
        end
    end
    -- Position before parenting, so there is never a visible frame at the template's stored location.
    local cf = EffectFrame(record, now, true)
    for _, part in ipairs(record.Parts) do part.Object.CFrame = cf * part.Offset end
    model.Parent = self.Parent
    table.insert(self.Records, record)
    return true
end

function Renderer:Update()
    local now = workspace:GetServerTimeNow()
    for i = #self.Records, 1, -1 do
        local record = self.Records[i]
        if not record.Anchor.Parent or not self:Near(record.Character, record.AllowDead) or now >= record.EndsAt + record.Tail then
            record.Model:Destroy()
            table.remove(self.Records, i)
        else
            if now >= record.EndsAt and not record.Stopped then self:Stop(record.Character, record.Scope) end
            local cf = EffectFrame(record, now)
            for _, part in ipairs(record.Parts) do
                part.Object.CFrame = cf * part.Offset
                if record.Stopped then
                    part.Object.Transparency = part.Transparency + (1 - part.Transparency)
                        * math.clamp((now - record.EndsAt) / 0.15, 0, 1)
                end
            end
            local elapsed = now - record.StartedAt
            for _, item in ipairs(record.Emitters) do
                if not record.Stopped and elapsed >= item.Delay then
                    if not item.Fired then item.Object:Emit(item.Count); item.Fired = true end
                    item.Object.Enabled = item.Loop or (item.Duration > 0 and elapsed < item.Delay + item.Duration)
                end
            end
            for _, object in ipairs(record.Switches) do object.Enabled = not record.Stopped end
        end
    end
end

function Renderer:Destroy()
    for _, record in ipairs(self.Records) do record.Model:Destroy() end
    self.Records = {}
end

return Renderer
