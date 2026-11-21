-- Local voxel dust; no physics, external textures or gameplay state changes.
local DashDust = {}
DashDust.__index = DashDust

function DashDust.new(parent, config)
    local folder = Instance.new("Folder")
    folder.Name = "DashPixelDust"
    folder.Parent = parent
    return setmetatable({ Folder = folder, Config = config, Particles = {}, Emitters = {}, Random = Random.new() }, DashDust)
end

function DashDust:Forget(character)
    self.Emitters[character] = nil
end

function DashDust:Step(character, root, humanoid, dashing, deltaTime)
    local config = self.Config
    local camera = workspace.CurrentCamera
    if not config.Enabled or not dashing or not character.Parent or humanoid.Health <= 0
        or not camera or (camera.CFrame.Position - root.Position).Magnitude > config.RenderDistance then
        self:Forget(character)
        return
    end
    local state = humanoid:GetState()
    if humanoid.FloorMaterial == Enum.Material.Air or humanoid.FloorMaterial == Enum.Material.Water
        or state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall
        or state == Enum.HumanoidStateType.Swimming then
        self:Forget(character)
        return
    end
    local velocity = root.AssemblyLinearVelocity
    local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
    if horizontal.Magnitude < config.MinSpeed then return end
    local emitter = self.Emitters[character]
    if not emitter then
        emitter = { Cooldown = 0 }
        self.Emitters[character] = emitter
    end
    emitter.Cooldown = math.max(0, emitter.Cooldown - math.max(0, deltaTime))
    if emitter.Cooldown > 0 or #self.Particles >= config.MaxParticles then return end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { character, self.Folder.Parent }
    params.RespectCanCollide = true
    params.IgnoreWater = true
    params.CollisionGroup = root.CollisionGroup
    local leg = character:FindFirstChild("Left Leg")
    local legHeight = leg and leg:IsA("BasePart") and leg.Size.Y or 0
    local reach = humanoid.HipHeight + root.Size.Y * 0.5 + legHeight + config.GroundProbePadding
    local hit = workspace:Raycast(root.Position, Vector3.new(0, -reach, 0), params)
    if not hit or hit.Normal.Y < config.MinGroundNormal then return end

    emitter.Cooldown = config.Interval -- no accumulated catch-up bursts on slow frames
    local surface = config.Color
    if hit.Instance:IsA("BasePart") then
        surface = hit.Instance.Color
    elseif hit.Instance:IsA("Terrain") then
        surface = hit.Instance:GetMaterialColor(hit.Material)
    end
    local color = config.Color:Lerp(surface, config.SurfaceTint)
    local backward = -horizontal.Unit
    local right = Vector3.new(-backward.Z, 0, backward.X)
    for _ = 1, math.min(config.ParticlesPerBurst, config.MaxParticles - #self.Particles) do
        local size = self.Random:NextNumber(config.MinSize, config.MaxSize)
        local origin = hit.Position + hit.Normal * (size * 0.5 + 0.03)
            + right * self.Random:NextNumber(-0.55, 0.55)
        local part = Instance.new("Part")
        part.Name = "DustPixel"
        part.Anchored = true
        part.CanCollide = false
        part.CanTouch = false
        part.CanQuery = false
        part.CastShadow = false
        part.Material = Enum.Material.SmoothPlastic
        part.Color = color
        part.Transparency = 0.15
        part.Size = Vector3.new(size, size, size)
        part.Position = origin
        part.Parent = self.Folder
        table.insert(self.Particles, {
            Part = part, Origin = origin, Normal = hit.Normal, Size = size, Age = 0,
            Velocity = backward * self.Random:NextNumber(1, config.BackwardSpeed)
                + right * self.Random:NextNumber(-config.Spread, config.Spread),
            UpSpeed = self.Random:NextNumber(config.UpSpeed * 0.7, config.UpSpeed),
        })
    end
end

function DashDust:Update(deltaTime)
    local config = self.Config
    for index = #self.Particles, 1, -1 do
        local particle = self.Particles[index]
        particle.Age = particle.Age + math.max(0, deltaTime)
        local progress = particle.Age / config.Lifetime
        if progress >= 1 or not particle.Part.Parent then
            particle.Part:Destroy()
            table.remove(self.Particles, index)
        else
            local age = particle.Age
            local lift = math.max(0, particle.UpSpeed * age - 0.5 * config.Gravity * age * age)
            particle.Part.Position = particle.Origin + particle.Velocity * age + particle.Normal * lift
            local size = particle.Size * (1 - 0.6 * progress)
            particle.Part.Size = Vector3.new(size, size, size)
            particle.Part.Transparency = 0.15 + 0.85 * progress
        end
    end
end

function DashDust:Destroy()
    self.Folder:Destroy()
    table.clear(self.Particles)
    table.clear(self.Emitters)
end

return DashDust
