--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementState = require(ReplicatedStorage.Shared.Enums.MovementState)

local FootstepConstants = table.freeze({
	Intervals = table.freeze({
		[MovementState.Running] = 0.33,
		-- Same cadence as Running -- footsteps keep playing through the Qinggong Sprinting
		-- technique's charge (see FootstepController), just fading out in volume as it ramps, rather
		-- than cutting the instant SprintCharging begins.
		[MovementState.SprintCharging] = 0.33,
		[MovementState.Walking] = 0.48,
		[MovementState.CrouchWalking] = 0.53,
	}),

	BaseVolume = 0.5, -- Sound's own default -- named here so the sprint fade-out has something to scale
	GroundCheckDistance = 5,
	SoundCleanupTime = 2,
	PitchVariance = 0.1,
	MoveDirectionDeadzone = 0.1,

	AudibleRange = 60,
	NotifyCooldown = 0.2,
})

return FootstepConstants
