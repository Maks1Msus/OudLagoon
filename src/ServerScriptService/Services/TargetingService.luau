local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local Combat = require(script.Parent.CombatService)
local Targeting = {}

function Targeting.ValidDirection(v)
    return typeof(v) == "Vector3" and v.Magnitude >= 0.99 and v.Magnitude <= 1.01
end

function Targeting.Turn(current, aim, radians)
    local angle = math.acos(math.clamp(current:Dot(aim), -1, 1))
    if angle <= radians or angle < 0.0001 then return aim end
    local tangent = aim - current * current:Dot(aim)
    if tangent.Magnitude < 0.0001 then
        tangent = current:Cross(math.abs(current.Y) < 0.9 and Vector3.yAxis or Vector3.xAxis)
    end
    return (current * math.cos(radians) + tangent.Unit * math.sin(radians)).Unit
end

local function filter(caster)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { caster }
    return params
end

local function actor(part)
    local model = part:FindFirstAncestorOfClass("Model")
    while model and not model:FindFirstChildOfClass("Humanoid") do
        model = model:FindFirstAncestorOfClass("Model")
    end
    return model
end

-- Resolve the release point from server geometry before committing resources.
function Targeting.Prepare(caster, targeting, aim)
    local root = caster:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local origin = root.Position + Vector3.new(0, 1, 0)
    local plan = { Origin = origin, Direction = aim, Filter = filter(caster) }
    if targeting.Type == "Area" then
        local hit = workspace:Raycast(origin, aim * targeting.Range, plan.Filter)
        local endpoint = hit and hit.Position or origin + aim * targeting.Range
        local groundFilter = plan.Filter
        if hit then
            local model = actor(hit.Instance)
            if model then
                groundFilter = filter(caster)
                groundFilter.FilterDescendantsInstances = { caster, model }
            elseif hit.Normal.Y < 0.45 then
                endpoint = endpoint + hit.Normal * 0.3
            end
        end
        local ground = workspace:Raycast(endpoint + Vector3.yAxis * 0.4, -Vector3.yAxis * targeting.Range, groundFilter)
        if not ground or ground.Normal.Y < 0.45 or actor(ground.Instance)
            or (ground.Position - origin).Magnitude > targeting.Range + 0.5 then return nil end
        plan.Center = ground.Position + Vector3.yAxis * 0.15
    end
    return plan
end

local function visual(name, color, shape, size, frame, lifetime)
    local part = Instance.new("Part")
    part.Name, part.Shape, part.Material = name, shape, Enum.Material.Neon
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.CastShadow, part.Transparency = false, 0.55
    part.Size, part.CFrame, part.Color = size, frame, color
    part.Parent = workspace
    Debris:AddItem(part, lifetime)
    return part
end

local function scan(ctx, plan, center, box)
    local overlap = OverlapParams.new()
    overlap.FilterDescendantsInstances = { ctx.Caster }
    local targeting = ctx.Targeting
    local parts
    if box then
        parts = workspace:GetPartBoundsInBox(box, Vector3.new(targeting.Width, 6, targeting.Range), overlap)
    else
        parts = workspace:GetPartBoundsInRadius(center, targeting.Radius, overlap)
    end
    local seen = {}
    for _, part in ipairs(parts) do
        local target = actor(part)
        if target and not seen[target] then
            seen[target] = true
            local root = target:FindFirstChild("HumanoidRootPart")
            if root and (box or (root.Position - center).Magnitude <= targeting.Radius) then
                local hit = workspace:Raycast(center, root.Position - center, plan.Filter)
                if not hit or hit.Instance:IsDescendantOf(target) then
                    Combat:ApplyAbilityEffect(ctx, target, center)
                    if ctx.Combat.ParryCaster and not ctx.StillCasting() then return end
                end
            end
        end
    end
end

local function projectile(ctx, plan)
    local t = ctx.Targeting
    local size = Vector3.one * t.Radius * 2
    local part = visual("SpellProjectile", ctx.Color, Enum.PartType.Ball, size, CFrame.new(plan.Origin), t.Range / t.Speed + 1)
    local position, remaining = plan.Origin, t.Range
    local connection
    connection = RunService.Heartbeat:Connect(function(dt)
        local distance = math.min(remaining, t.Speed * dt)
        local step = plan.Direction * distance
        local hit = workspace:Raycast(position, step, plan.Filter)
        if hit or remaining <= distance or not part.Parent then
            connection:Disconnect()
            part:Destroy()
            local target = hit and actor(hit.Instance)
            if target then Combat:ApplyAbilityEffect(ctx, target, position) end
            return
        end
        position = position + step
        remaining -= distance
        part.Position = position
    end)
end

function Targeting.Release(ctx, plan)
    local t = ctx.Targeting
    if t.Type == "Projectile" then
        projectile(ctx, plan)
    elseif t.Type == "Forward" then
        local box = CFrame.lookAt(plan.Origin, plan.Origin + plan.Direction) * CFrame.new(0, 0, -t.Range / 2)
        visual("AbilitySweep", ctx.Color, Enum.PartType.Block, Vector3.new(t.Width, 0.45, t.Range), box, 0.16)
        scan(ctx, plan, plan.Origin, box)
    elseif t.Type == "Area" then
        local disc = CFrame.new(plan.Center) * CFrame.Angles(0, 0, math.pi / 2)
        visual("SpellArea", ctx.Color, Enum.PartType.Cylinder, Vector3.new(0.2, t.Radius * 2, t.Radius * 2), disc, t.Duration)
        for tickIndex = 0, math.ceil(t.Duration / t.TickRate) - 1 do
            task.delay(tickIndex * t.TickRate, function() scan(ctx, plan, plan.Center) end)
        end
    elseif t.Type == "Self" then
        visual("SpellPulse", ctx.Color, Enum.PartType.Ball, Vector3.one * (ctx.Combat.Restore and 3 or t.Radius * 2),
            CFrame.new(plan.Origin), 0.2)
        if ctx.Combat.Restore then Combat:ApplyAbilityEffect(ctx, ctx.Caster, plan.Origin)
        else scan(ctx, plan, plan.Origin) end
    end
end
return Targeting
