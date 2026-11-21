local player = game.Players.LocalPlayer
local char = player.Character or player.CharacterAdded:Wait()
local hum = char.Humanoid

local MaterialSounds = {
	[Enum.Material.Grass] = {SoundId = "rbxassetid://507863105", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.Metal] = {SoundId = "rbxassetid://5676620958", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.DiamondPlate] = {SoundId = "rbxassetid://944089664", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.Pebble] = {SoundId = "rbxassetid://944090255", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.Wood] = {SoundId = "rbxassetid://944075408", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.WoodPlanks] = {SoundId = "rbxassetid://944075408", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.Plastic] = {SoundId = "rbxassetid://78241561292777", Volume = .1, PlaybackSpeed = 0.75},
	[Enum.Material.SmoothPlastic] = {SoundId = "rbxassetid://944075408", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.Sand] = {SoundId = "rbxassetid://944090255", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.Brick] = {SoundId = "rbxassetid://4981969796", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.Cobblestone] = {SoundId = "rbxassetid://4981969796", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.Concrete] = {SoundId = "rbxassetid://944075408", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.CorrodedMetal] = {SoundId = "rbxassetid://4981969796", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.Fabric] = {SoundId = "rbxassetid://4981969796", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.Foil] = {SoundId = "rbxassetid://4981969796", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.ForceField] = {SoundId = "rbxassetid://4981969796", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.Glass] = {SoundId = "rbxassetid://944075408", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.Granite] = {SoundId = "rbxassetid://944075408", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.Ice] = {SoundId = "rbxassetid://4981969796", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.Marble] = {SoundId = "rbxassetid://80027112124187", Volume = .1, PlaybackSpeed = 0.9},
	[Enum.Material.Neon] = {SoundId = "rbxassetid://4981969796", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.Slate] = {SoundId = "rbxassetid://944075408", Volume = .2, PlaybackSpeed = 1},
	[Enum.Material.Snow] = {SoundId = "rbxassetid://80932364310315", Volume = .2, PlaybackSpeed = 0.75},
}

local Character = script.Parent
local Humanoid = Character:WaitForChild("Humanoid")
local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")
local FootStepsSound = HumanoidRootPart:WaitForChild("Running")
local baseSpeed = 13

Humanoid:GetPropertyChangedSignal("FloorMaterial"):Connect(function()
	local FloorMaterial = Humanoid.FloorMaterial
	local MaterialConfig = MaterialSounds[FloorMaterial]

	if MaterialConfig then
		-- Adjust baseSpeed for Grass
		if FloorMaterial == Enum.Material.Grass then
			baseSpeed = 16
		else
			baseSpeed = 13
		end

		-- Apply Volume and PlaybackSpeed
		if Humanoid.WalkSpeed < 8 then
			FootStepsSound.Volume = 0
		end
		FootStepsSound.Volume = MaterialConfig.Volume
		FootStepsSound.PlaybackSpeed = MaterialConfig.PlaybackSpeed * (Humanoid.WalkSpeed / baseSpeed*0.7)
		FootStepsSound.SoundId = MaterialConfig.SoundId
	else
		-- Default sound if no material match
		if Humanoid.WalkSpeed < 8 then
			FootStepsSound.Volume = 0
		end
		FootStepsSound.SoundId = "rbxasset://sounds/action_footsteps_plastic.mp3"
		FootStepsSound.Volume = 10
		FootStepsSound.PlaybackSpeed = 1
	end
end)

Humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
	local FloorMaterial = Humanoid.FloorMaterial
	local MaterialConfig = MaterialSounds[FloorMaterial]

	-- Adjust baseSpeed for Grass
	if FloorMaterial == Enum.Material.Grass then
		baseSpeed = 16
	else
		baseSpeed = 13
	end
	
	if Humanoid.WalkSpeed < 8 then
		FootStepsSound.Volume = 0
	else
		if MaterialConfig then
			FootStepsSound.Volume = MaterialConfig.Volume
		end
	end
	-- Update PlaybackSpeed dynamically with WalkSpeed
	if MaterialConfig then
		FootStepsSound.PlaybackSpeed = MaterialConfig.PlaybackSpeed * (Humanoid.WalkSpeed / baseSpeed*0.7)
	else
		FootStepsSound.PlaybackSpeed = Humanoid.WalkSpeed / baseSpeed
	end
end)
