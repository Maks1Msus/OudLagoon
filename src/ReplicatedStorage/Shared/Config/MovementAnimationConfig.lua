--!strict

local Config = {}

Config.Settings = {
	-- Animation blending
	FadeIn = 0.12,
	FadeOut = 0.12,
	DirectionBlendTime = 0.15,

	-- Movement
	SprintSpeedMultiplier = 2,

	-- Double-tap W
	SprintDoubleTapWindow = 0.30,

	-- Character rotation
	WalkTurnResponsiveness = 12,
	SprintTurnResponsiveness = 8,
	ShiftLockTurnResponsiveness = 18,

	-- Idle variations
	IdleVariationMinDelay = 8,
	IdleVariationMaxDelay = 16,

	-- Landing
	HardLandingVelocity = 45,

	-- Character loading
	CharacterWaitTimeout = 10,

	-- Shift Lock detection
	ShiftLockAttribute = "OudLagoonShiftLock",

	-- Debug
	DebugLogging = false,
}

-- Direction order is clockwise, starting from Forward.
-- These directions are used only while Shift Lock is enabled.

Config.Directions = {
	"Forward",
	"ForwardRight",
	"Right",
	"BackwardRight",
	"Backward",
	"BackwardLeft",
	"Left",
	"ForwardLeft",
}

Config.DirectionAngles = {
	Forward = 0,
	ForwardRight = 45,
	Right = 90,
	BackwardRight = 135,
	Backward = 180,
	BackwardLeft = 225,
	Left = 270,
	ForwardLeft = 315,
}

Config.Slots = {
	-- Basic
	Idle = "rbxassetid://75878436802753",

	-- Walk: forward is used without Shift Lock.
	-- All eight directions are used with Shift Lock.
	WalkForward = "rbxassetid://129752366656564",
	WalkForwardRight = "rbxassetid://99144410919846",
	WalkRight = "rbxassetid://87671699903974",
	WalkBackwardRight = "rbxassetid://97054043939839",
	WalkBackward = "rbxassetid://137155747927534",
	WalkBackwardLeft = "rbxassetid://90919531928603",
	WalkLeft = "rbxassetid://111304610917028",
	WalkForwardLeft = "rbxassetid://125216930056241",

	-- Sprint: same directional rules as Walk.
	SprintForward = "rbxassetid://113412604423061",
	SprintForwardRight = "rbxassetid://100676216178589",
	SprintRight = "rbxassetid://100676216178589",
	SprintBackwardRight = "rbxassetid://79388354807046",
	SprintBackward = "rbxassetid://82376640244229",
	SprintBackwardLeft = "rbxassetid://103829490602029",
	SprintLeft = "rbxassetid://114512910144501",
	SprintForwardLeft = "rbxassetid://114512910144501",

	-- Transitions
	WalkStart = "rbxassetid://0",
	WalkStop = "rbxassetid://0",

	SprintStart = "rbxassetid://0",
	SprintStop = "rbxassetid://0",

	-- Idle variations
	IdleVariation1 = "rbxassetid://133940101957529",
	IdleVariation2 = "rbxassetid://86150099556403",

	-- Jumping and falling
	JumpStart = "rbxassetid://0",
	JumpFall = "rbxassetid://0",

	-- Landing
	Landing = "rbxassetid://0",
	HardLanding = "rbxassetid://0",
}

function Config.GetAnimationId(slotName: string): string?
	return Config.Slots[slotName]
end

function Config.IsAssigned(slotName: string): boolean
	local animationId = Config.GetAnimationId(slotName)

	if not animationId then
		return false
	end

	return animationId ~= "" and animationId ~= "rbxassetid://0"
end

function Config.GetLocomotionSlot(
	movementMode: string,
	direction: string
): string

	return movementMode .. direction
end

function Config.GetDirectionalSlots(movementMode: string)
	local result = {}

	for _, direction in ipairs(Config.Directions) do
		table.insert(
			result,
			Config.GetLocomotionSlot(movementMode, direction)
		)
	end

	return result
end

return Config