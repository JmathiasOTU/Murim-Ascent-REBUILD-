--!strict

export type MovementState = string

local MovementState = table.freeze({
	Idle = "Idle" :: MovementState,
	Walking = "Walking" :: MovementState,
	Running = "Running" :: MovementState,
	Jumping = "Jumping" :: MovementState,
	Falling = "Falling" :: MovementState,
	LightLanding = "LightLanding" :: MovementState,
	HeavyLanding = "HeavyLanding" :: MovementState,
	Dashing = "Dashing" :: MovementState,
	Sliding = "Sliding" :: MovementState,
})

return MovementState
