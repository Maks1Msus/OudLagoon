local Theme = require(script.Parent.Theme)

local CharacterPreview = {}
CharacterPreview.__index = CharacterPreview

function CharacterPreview.new(parent)
    local viewport = Theme.create("ViewportFrame", parent, {
        Name = "CharacterPreview",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Ambient = Color3.fromRGB(146, 142, 138),
        LightColor = Color3.fromRGB(255, 231, 196),
        LightDirection = Vector3.new(-1, -1, -1),
    })
    local camera = Theme.create("Camera", viewport, { FieldOfView = 29 })
    viewport.CurrentCamera = camera

    local self = setmetatable({
        Viewport = viewport,
        Camera = camera,
        World = Theme.create("WorldModel", viewport, {}),
    }, CharacterPreview)
    viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        self:frameModel()
    end)
    return self
end

function CharacterPreview:frameModel()
    if not self.Model then
        return
    end
    local center, size = self.Model:GetBoundingBox()
    local viewportSize = self.Viewport.AbsoluteSize
    local aspect = math.max(0.2, viewportSize.X / math.max(viewportSize.Y, 1))
    local halfHeight = math.max(size.Y, size.X / aspect) / 2
    local distance = halfHeight / math.tan(math.rad(self.Camera.FieldOfView / 2)) * 1.18 + size.Z / 2
    local target = center.Position
    local direction = Vector3.new(0.20, 0.04, -1).Unit
    self.Camera.CFrame = CFrame.lookAt(target + direction * distance, target)
end

function CharacterPreview:setCharacter(character)
    if self.Model then
        self.Model:Destroy()
        self.Model = nil
    end
    if not character or not character:FindFirstChild("HumanoidRootPart") then
        return
    end

    local wasArchivable = character.Archivable
    character.Archivable = true
    local clone = character:Clone()
    character.Archivable = wasArchivable

    for _, descendant in ipairs(clone:GetDescendants()) do
        if descendant:IsA("LuaSourceContainer") or descendant:IsA("Sound")
            or descendant:IsA("ParticleEmitter") or descendant:IsA("Trail")
            or descendant:IsA("Beam") or descendant:IsA("Highlight") then
            descendant:Destroy()
        elseif descendant:IsA("BasePart") then
            descendant.Anchored = true
            descendant.LocalTransparencyModifier = 0
            descendant.CanCollide = false
            descendant.CanQuery = false
            descendant.CanTouch = false
        end
    end

    -- A live character may be rotated or mid-animation when the overlay opens.
    -- Align the clone relative to its root while leaving the live rig untouched.
    clone.PrimaryPart = clone:FindFirstChild("HumanoidRootPart")
    if not clone.PrimaryPart then
        clone:Destroy()
        return
    end
    clone:PivotTo(CFrame.new())
    clone.Parent = self.World
    self.Model = clone
    self:frameModel()
end

return CharacterPreview
