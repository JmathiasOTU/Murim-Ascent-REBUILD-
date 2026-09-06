--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementState = require(ReplicatedStorage.Shared.Enums.MovementState)

local FootstepConstants = table.freeze({
	Intervals = table.freeze({
		[MovementState.Running] = 0.33,
		[MovementState.Walking] = 0.48,
		[MovementState.CrouchWalking] = 0.53,
	}),

	GroundCheckDistance = 5,
	SoundCleanupTime = 2,
	PitchVariance = 0.1,
	MoveDirectionDeadzone = 0.1,

	AudibleRange = 60,
	NotifyCooldown = 0.2,
})

return FootstepConstants
