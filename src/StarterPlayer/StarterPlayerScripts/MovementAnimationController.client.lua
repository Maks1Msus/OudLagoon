--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ContentProvider = game:GetService("ContentProvider")

local Player = Players.LocalPlayer

local Config = require(
	ReplicatedStorage
		:WaitForChild("Shared")
		:WaitForChild("Config")
		:WaitForChild("MovementAnimationConfig")
)

local CombatStateConfig = require(
    ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("CombatStateConfig")
)
local MovementRestrictions = CombatStateConfig.Movement
local DashConfig = require(ReplicatedStorage.Shared.Config.DashConfig)
local Settings = Config.Settings

--------------------------------------------------
-- STATE
--------------------------------------------------

local Character: Model? = nil
local Humanoid: Humanoid? = nil
local Animator: Animator? = nil
local RootPart: BasePart? = nil

local Tracks = {}
local Animations = {}

local ActiveLocomotionTracks = {}

local CurrentMode = "Idle"
local CurrentShiftLock = false

local IsMoving = false
local IsSprinting = false
local IsInAir = false

local LastWPress = 0
local LastFallVelocity = 0

local BaseWalkSpeed = 16
local ExpectedWalkSpeed: number? = nil
local SavedJumpEnabled: boolean? = nil

local CharacterConnections = {}
local GlobalConnections = {}

local IdleVariationToken = 0

--------------------------------------------------
-- DEBUG
--------------------------------------------------

local function DebugLog(...)
	if Settings.DebugLogging then
		print("[MovementAnimationController]", ...)
	end
end

--------------------------------------------------
-- ANIMATION HELPERS
--------------------------------------------------

local function IsValidAnimationId(animationId: string?): boolean
	return animationId ~= nil
		and animationId ~= ""
		and animationId ~= "rbxassetid://0"
end

local function GetTrack(slotName: string): AnimationTrack?
	return Tracks[slotName]
end

local function StopTrack(
	track: AnimationTrack?,
	fadeTime: number?
)
	if not track then
		return
	end

	if track.IsPlaying then
		track:Stop(fadeTime or Settings.FadeOut)
	end
end

local function PlayOneShot(slotName: string)
	local track = GetTrack(slotName)

	if not track then
		return
	end

	if track.IsPlaying then
		track:Stop(0.05)
	end

	track.Looped = false
	track:Play(Settings.FadeIn)
end

local function PlayLoop(slotName: string)
	local track = GetTrack(slotName)

	if not track then
		return
	end

	track.Looped = true

	if not track.IsPlaying then
		track:Play(Settings.FadeIn)
	end

	track:AdjustWeight(1, Settings.FadeIn)
end
--------------------------------------------------
-- ANIMATION PHASE SYNCHRONIZATION
--------------------------------------------------

local function GetTrackPhase(track: AnimationTrack?): number?
	if not track or not track.IsPlaying then
		return nil
	end

	local length = track.Length

	if length <= 0 then
		return nil
	end

	return (track.TimePosition % length) / length
end

local function GetActiveLocomotionPhase(): number
	if not Settings.PhaseSyncEnabled then
		return 0
	end

	for _, track in pairs(ActiveLocomotionTracks) do
		local phase = GetTrackPhase(track)

		if phase ~= nil then
			return phase
		end
	end

	return 0
end

local function PlayTrackAtPhase(
	track: AnimationTrack,
	phase: number,
	fadeTime: number
)
	track.Looped = true
	track:Play(fadeTime, 0)

	if not Settings.PhaseSyncEnabled then
		return
	end

	if track.Length > 0 then
		track.TimePosition = phase * track.Length
	end
end

local function StopAllLocomotion(fadeTime: number?)
	for slotName, track in pairs(ActiveLocomotionTracks) do
		StopTrack(track, fadeTime)
		ActiveLocomotionTracks[slotName] = nil
	end
end

--------------------------------------------------
-- TRACK LOADING
--------------------------------------------------

local function LoadAnimations()
	if not Animator then
		return
	end

	table.clear(Tracks)
	table.clear(Animations)

	local preloadList = {}

	for slotName, animationId in pairs(Config.Slots) do
		if IsValidAnimationId(animationId) then
			local animation = Instance.new("Animation")
			animation.Name = slotName
			animation.AnimationId = animationId

			local success, track = pcall(function()
				return Animator:LoadAnimation(animation)
			end)

			if success and track then
				track.Priority = Enum.AnimationPriority.Movement
				Tracks[slotName] = track
				Animations[slotName] = animation

				table.insert(preloadList, animation)
			else
				warn(
					"[MovementAnimationController] Failed to load:",
					slotName,
					track
				)
			end
		end
	end

	if #preloadList > 0 then
		task.spawn(function()
			pcall(function()
				ContentProvider:PreloadAsync(preloadList)
			end)
		end)
	end

	DebugLog("Loaded", #preloadList, "animations")
end

--------------------------------------------------
-- DEFAULT ANIMATE
--------------------------------------------------

local function DisableDefaultAnimate()
	if not Character then
		return
	end

	local animate = Character:FindFirstChild("Animate")

	if animate and (
		animate:IsA("LocalScript")
		or animate:IsA("Script")
	) then
		animate.Disabled = true
		DebugLog("Default Animate disabled")
	end
end

--------------------------------------------------
-- SHIFT LOCK
--------------------------------------------------

local function IsShiftLockEnabled(): boolean
	if not Character then
		return false
	end

	-- Allows a custom Shift Lock controller to override detection.
	local attributeValue = Player:GetAttribute(
		Settings.ShiftLockAttribute
	)

	if typeof(attributeValue) == "boolean" then
		return attributeValue
	end

	-- Fallback for Roblox's standard mouse-lock behavior.
	return UserInputService.MouseBehavior
		== Enum.MouseBehavior.LockCenter
end

--------------------------------------------------
-- DIRECTIONAL BLENDING
--------------------------------------------------

local function GetDirectionalBlend(direction: Vector3)
	local camera = workspace.CurrentCamera

	if not camera then
		return "Forward", "ForwardRight", 0
	end

	local cameraForward = Vector3.new(
		camera.CFrame.LookVector.X,
		0,
		camera.CFrame.LookVector.Z
	)

	local cameraRight = Vector3.new(
		camera.CFrame.RightVector.X,
		0,
		camera.CFrame.RightVector.Z
	)

	if cameraForward.Magnitude < 0.001
		or cameraRight.Magnitude < 0.001 then
		return "Forward", "ForwardRight", 0
	end

	cameraForward = cameraForward.Unit
	cameraRight = cameraRight.Unit

	local localX = direction:Dot(cameraRight)
	local localForward = direction:Dot(cameraForward)

	local angle = math.deg(
		math.atan2(localX, localForward)
	)

	angle = (angle + 360) % 360

	local sector = 45
	local index = math.floor(angle / sector)

	local alpha = (angle - index * sector) / sector

	local directions = Config.Directions

	local firstIndex = (index % 8) + 1
	local secondIndex = ((index + 1) % 8) + 1

	return directions[firstIndex],
		directions[secondIndex],
		alpha
end

local function ApplyDirectionalBlend(
	movementMode: string,
	direction: Vector3
)
	local syncPhase = GetActiveLocomotionPhase()

	local firstDirection, secondDirection, alpha =
		GetDirectionalBlend(direction)

	local firstSlot = Config.GetLocomotionSlot(
		movementMode,
		firstDirection
	)

	local secondSlot = Config.GetLocomotionSlot(
		movementMode,
		secondDirection
	)

	local firstTrack = GetTrack(firstSlot)
	local secondTrack = GetTrack(secondSlot)

	local targetTracks = {}

	if firstTrack and secondTrack then
		targetTracks[firstSlot] = {
			track = firstTrack,
			weight = 1 - alpha,
		}

		targetTracks[secondSlot] = {
			track = secondTrack,
			weight = alpha,
		}
	elseif firstTrack then
		targetTracks[firstSlot] = {
			track = firstTrack,
			weight = 1,
		}
	elseif secondTrack then
		targetTracks[secondSlot] = {
			track = secondTrack,
			weight = 1,
		}
	else
		-- Fallback if directional clips are not assigned.
		local fallbackSlot = movementMode .. "Forward"
		local fallbackTrack = GetTrack(fallbackSlot)

		if fallbackTrack then
			targetTracks[fallbackSlot] = {
				track = fallbackTrack,
				weight = 1,
			}
		end
	end

	-- Stop tracks that are no longer needed.
	for slotName, track in pairs(ActiveLocomotionTracks) do
		if not targetTracks[slotName] then
			StopTrack(track, Settings.DirectionBlendTime)
			ActiveLocomotionTracks[slotName] = nil
		end
	end

	-- Start and adjust the two required tracks.
	for slotName, data in pairs(targetTracks) do
		local track = data.track

		if not track.IsPlaying then
			PlayTrackAtPhase(track, syncPhase, 0)
		end

		track:AdjustWeight(
			data.weight,
			Settings.DirectionBlendTime
		)

		ActiveLocomotionTracks[slotName] = track
	end
end

--------------------------------------------------
-- NON-SHIFTLOCK LOCOMOTION
--------------------------------------------------

local function ApplyForwardLocomotion(movementMode: string)
	local slotName = movementMode .. "Forward"
	local track = GetTrack(slotName)

	if not track then
		return
	end
	local syncPhase = GetActiveLocomotionPhase()
	for activeSlot, activeTrack in pairs(ActiveLocomotionTracks) do
		if activeSlot ~= slotName then
			StopTrack(activeTrack, Settings.DirectionBlendTime)
			ActiveLocomotionTracks[activeSlot] = nil
		end
	end

	if not track.IsPlaying then
		PlayTrackAtPhase(
			track,
			syncPhase,
			Settings.FadeIn
		)
	end

	track:AdjustWeight(1, Settings.DirectionBlendTime)

	ActiveLocomotionTracks[slotName] = track
end

--------------------------------------------------
-- LOCOMOTION
--------------------------------------------------

local function UpdateLocomotion(
	movementMode: string,
	moveDirection: Vector3
)
	if IsInAir then
		return
	end

	if movementMode == "Idle" then
		StopAllLocomotion()
		PlayLoop("Idle")
		return
	end

	StopTrack(GetTrack("Idle"), Settings.FadeOut)

	if CurrentShiftLock then
		ApplyDirectionalBlend(movementMode, moveDirection)
	else
		ApplyForwardLocomotion(movementMode)
	end
end

--------------------------------------------------
-- TRANSITIONS
--------------------------------------------------

local function PlayMovementTransition(slotName: string)
	PlayOneShot(slotName)
end

local function HandleMovementStart()
	if IsSprinting then
		PlayMovementTransition("SprintStart")
	else
		PlayMovementTransition("WalkStart")
	end
end

local function HandleMovementStop()
	if IsSprinting then
		PlayMovementTransition("SprintStop")
	else
		PlayMovementTransition("WalkStop")
	end
end

--------------------------------------------------
-- IDLE VARIATIONS
--------------------------------------------------

local function ScheduleIdleVariation()
	IdleVariationToken += 1
	local token = IdleVariationToken

	local delayTime = Random.new():NextNumber(
		Settings.IdleVariationMinDelay,
		Settings.IdleVariationMaxDelay
	)

	task.delay(delayTime, function()
		if token ~= IdleVariationToken then
			return
		end

		if not Character or not Humanoid then
			return
		end

		if IsMoving or IsInAir then
			return
		end

		if CurrentMode ~= "Idle" then
			return
		end

		local variation = math.random(1, 2)
		PlayOneShot("IdleVariation" .. variation)

		ScheduleIdleVariation()
	end)
end

local function CancelIdleVariations()
	IdleVariationToken += 1
end

--------------------------------------------------
-- SPRINT INPUT
--------------------------------------------------

local function GetMovementRestriction()
    if not Humanoid then
        return nil
    end
    local state = Humanoid:GetAttribute(MovementRestrictions.StateAttribute)
    if state ~= "Stunned" and state ~= "Ragdolled" and state ~= "Dead" and Humanoid:GetAttribute(DashConfig.DashAttackAttribute) then
        return MovementRestrictions.States.Attacking
    end
    if state ~= "Attacking" and state ~= "Stunned" and state ~= "Ragdolled" and state ~= "Dead"
        and Humanoid:GetAttribute(DashConfig.PredictionAttribute) then
        return DashConfig.ActiveMovementRestriction
    end
    return MovementRestrictions.States[state]
end

local function RestoreJump()
    if Humanoid and SavedJumpEnabled ~= nil then
        Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, SavedJumpEnabled)
    end
    SavedJumpEnabled = nil
end

local function HandleWPressed()
    local restriction = GetMovementRestriction()
    if restriction and not restriction.CanSprint then
        IsSprinting = false
        LastWPress = 0
        return
    end
	local now = os.clock()

	if now - LastWPress <= Settings.SprintDoubleTapWindow then
		IsSprinting = true
		DebugLog("Sprint activated")
		LastWPress = 0
	else
		LastWPress = now
	end
end

local function HandleInputBegan(
	input: InputObject,
	gameProcessed: boolean
)
	if gameProcessed then
		return
	end

	if input.KeyCode == Enum.KeyCode.W then
		HandleWPressed()
	end
end

--------------------------------------------------
-- MOVEMENT SPEED
--------------------------------------------------

local function UpdateMovementSpeed()
    if not Humanoid then
        return
    end

    local restriction = GetMovementRestriction()
    local sprintMultiplier = IsSprinting and (not restriction or restriction.CanSprint)
        and Settings.SprintSpeedMultiplier or 1
    local combatMultiplier = restriction and restriction.WalkSpeedMultiplier or 1
    local base = Humanoid:GetAttribute(MovementRestrictions.BaseSpeedAttribute)

    if type(base) == "number" then
        BaseWalkSpeed = base
    elseif not restriction and ExpectedWalkSpeed
        and math.abs(Humanoid.WalkSpeed - ExpectedWalkSpeed) > 0.05
    then
        BaseWalkSpeed = Humanoid.WalkSpeed / sprintMultiplier
    end

    -- Publish the unrestricted locomotion intent for the dash-to-movement blend.
    Humanoid:SetAttribute(DashConfig.SprintIntentAttribute, IsSprinting)
    Humanoid:SetAttribute(DashConfig.LocomotionSpeedAttribute,
        BaseWalkSpeed * (IsSprinting and Settings.SprintSpeedMultiplier or 1))
    local targetSpeed = BaseWalkSpeed * combatMultiplier * sprintMultiplier
    if math.abs(Humanoid.WalkSpeed - targetSpeed) > 0.05 then
        Humanoid.WalkSpeed = targetSpeed
    end
    ExpectedWalkSpeed = targetSpeed

    if restriction and not restriction.CanJump then
        if SavedJumpEnabled == nil then
            SavedJumpEnabled = Humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping)
        end
        Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
        Humanoid.Jump = false
    else
        RestoreJump()
    end
end

--------------------------------------------------
-- CHARACTER ROTATION
--------------------------------------------------

local function UpdateCharacterRotation(
	moveDirection: Vector3,
	deltaTime: number
)
	if not Humanoid or not RootPart then
		return
	end

    local restriction = GetMovementRestriction()
    if restriction and restriction.LockRotation then
        return
    end

	local targetDirection: Vector3? = nil
	local responsiveness = Settings.WalkTurnResponsiveness

	if CurrentShiftLock then
		local camera = workspace.CurrentCamera

		if camera then
			local look = camera.CFrame.LookVector

			targetDirection = Vector3.new(
				look.X,
				0,
				look.Z
			)

			responsiveness =
				Settings.ShiftLockTurnResponsiveness
		end
	else
		if moveDirection.Magnitude > 0.05 then
			targetDirection = Vector3.new(
				moveDirection.X,
				0,
				moveDirection.Z
			)

			responsiveness = IsSprinting
				and Settings.SprintTurnResponsiveness
				or Settings.WalkTurnResponsiveness
		end
	end

	if not targetDirection
		or targetDirection.Magnitude < 0.001 then
		return
	end

	targetDirection = targetDirection.Unit

	local targetCFrame = CFrame.lookAt(
		RootPart.Position,
		RootPart.Position + targetDirection
	)

	local alpha = 1 - math.exp(-responsiveness * deltaTime)

	RootPart.CFrame = RootPart.CFrame:Lerp(
		targetCFrame,
		alpha
	)
end

--------------------------------------------------
-- AIR ANIMATIONS
--------------------------------------------------

local function EnterJump()
	if IsInAir then
		return
	end

	IsInAir = true
	LastFallVelocity = 0

	CancelIdleVariations()
	StopAllLocomotion()

	PlayOneShot("JumpStart")
end

local function EnterFall()
	if not IsInAir then
		IsInAir = true
		StopAllLocomotion()
	end

	PlayLoop("JumpFall")
end

local function EnterLanding()
	if not IsInAir then
		return
	end

	IsInAir = false

	StopTrack(GetTrack("JumpFall"), 0.05)

	if math.abs(LastFallVelocity)
		>= Settings.HardLandingVelocity then

		PlayOneShot("HardLanding")
	else
		PlayOneShot("Landing")
	end

	LastFallVelocity = 0
end

--------------------------------------------------
-- CHARACTER UPDATE
--------------------------------------------------

local function UpdateCharacter(deltaTime: number)
	if not Character
		or not Humanoid
		or not RootPart then
		return
	end

	if Humanoid.Health <= 0 then
		return
	end

    local restriction = GetMovementRestriction()
    if Humanoid:GetAttribute(MovementRestrictions.StateAttribute) == "Ragdolled" then
        IsSprinting = false
        IsMoving = false
        LastWPress = 0
        CancelIdleVariations()
        StopAllLocomotion(0.05)
        UpdateMovementSpeed()
        return
    end
    local keepSprint = Humanoid:GetAttribute(DashConfig.PreserveSprintAttribute)
        and Humanoid:GetAttribute(DashConfig.PredictionAttribute)
        and Humanoid:GetAttribute(MovementRestrictions.StateAttribute) ~= "Attacking"
        and Humanoid:GetAttribute(MovementRestrictions.StateAttribute) ~= "Stunned"
        and Humanoid:GetAttribute(MovementRestrictions.StateAttribute) ~= "Dead"
    local state = Humanoid:GetAttribute(MovementRestrictions.StateAttribute)
    if state == "Stunned" or state == "Dead"
        or (restriction and not restriction.CanSprint and not keepSprint) then
        IsSprinting = false
        LastWPress = 0
    end

	local moveDirection = Humanoid.MoveDirection
	local moving = moveDirection.Magnitude > 0.05

	local newShiftLock = IsShiftLockEnabled()

	if newShiftLock ~= CurrentShiftLock then
		CurrentShiftLock = newShiftLock
		StopAllLocomotion(0.08)

		DebugLog(
			"Shift Lock:",
			CurrentShiftLock
		)
	end

	if not moving then
		if IsMoving then
			HandleMovementStop()
		end

		IsMoving = false
		IsSprinting = false

		CurrentMode = "Idle"

		UpdateMovementSpeed()
		UpdateLocomotion("Idle", Vector3.zero)

		ScheduleIdleVariation()
        if CurrentShiftLock then
            UpdateCharacterRotation(moveDirection, deltaTime)
        end

		return
	end

	CancelIdleVariations()

	if not IsMoving then
		HandleMovementStart()
	end

	IsMoving = true

	CurrentMode = IsSprinting and "Sprint" or "Walk"

	UpdateMovementSpeed()

	UpdateCharacterRotation(
		moveDirection,
		deltaTime
	)

	UpdateLocomotion(
		CurrentMode,
		moveDirection
	)

	if IsInAir and Humanoid:GetState()
		== Enum.HumanoidStateType.Freefall then

		LastFallVelocity = math.min(
			LastFallVelocity,
			RootPart.AssemblyLinearVelocity.Y
		)
	end
end

--------------------------------------------------
-- CHARACTER CLEANUP
--------------------------------------------------

local function DisconnectCharacterConnections()
	for _, connection in ipairs(CharacterConnections) do
		connection:Disconnect()
	end

	table.clear(CharacterConnections)
end

local function ResetCharacterState()
    RestoreJump()
	StopAllLocomotion(0)

	for _, track in pairs(Tracks) do
		StopTrack(track, 0)
	end

	table.clear(Tracks)
	table.clear(Animations)

	CancelIdleVariations()

	CurrentMode = "Idle"
	CurrentShiftLock = false

	IsMoving = false
	IsSprinting = false
	IsInAir = false

	LastWPress = 0
	LastFallVelocity = 0

	ExpectedWalkSpeed = nil
end

--------------------------------------------------
-- CHARACTER SETUP
--------------------------------------------------

local function SetupCharacter(character: Model)
	DisconnectCharacterConnections()
	ResetCharacterState()

	Character = character

	local humanoid = character:WaitForChild(
		"Humanoid",
		Settings.CharacterWaitTimeout
	)

	if not humanoid or not humanoid:IsA("Humanoid") then
		warn("[MovementAnimationController] Humanoid not found")
		return
	end

	Humanoid = humanoid

	local rootPart = character:WaitForChild(
		"HumanoidRootPart",
		Settings.CharacterWaitTimeout
	)

	if not rootPart or not rootPart:IsA("BasePart") then
		warn("[MovementAnimationController] RootPart not found")
		return
	end

	RootPart = rootPart

	local animator = Humanoid:FindFirstChildOfClass("Animator")

	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = Humanoid
	end

	Animator = animator

	BaseWalkSpeed = Humanoid.WalkSpeed

	-- Rotation is handled by this controller.
	Humanoid.AutoRotate = true

	DisableDefaultAnimate()
	LoadAnimations()

	PlayLoop("Idle")
	ScheduleIdleVariation()

	table.insert(
		CharacterConnections,
		Humanoid.StateChanged:Connect(function(_, newState)
			if newState == Enum.HumanoidStateType.Jumping then
				EnterJump()

			elseif newState == Enum.HumanoidStateType.Freefall then
				EnterFall()

			elseif newState == Enum.HumanoidStateType.Landed then
				EnterLanding()
			end
		end)
	)

	table.insert(
		CharacterConnections,
		Humanoid.Died:Connect(function()
			ResetCharacterState()
		end)
	)

	DebugLog("Character initialized")
end

--------------------------------------------------
-- GLOBAL CONNECTIONS
--------------------------------------------------

table.insert(
	GlobalConnections,
	UserInputService.InputBegan:Connect(HandleInputBegan)
)

table.insert(
	GlobalConnections,
	RunService.RenderStepped:Connect(UpdateCharacter)
)

table.insert(
	GlobalConnections,
	Player.CharacterAdded:Connect(SetupCharacter)
)

if Player.Character then
	task.spawn(SetupCharacter, Player.Character)
end

DebugLog("Controller initialized")
