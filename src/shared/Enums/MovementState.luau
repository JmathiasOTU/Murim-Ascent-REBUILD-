--!strict

export type MovementState = string

local MovementState = table.freeze({
	Idle = "Idle" :: MovementState,
	Walking = "Walking" :: MovementState,
	Running = "Running" :: MovementState,
	SprintCharging = "SprintCharging" :: MovementState,
	Sprinting = "Sprinting" :: MovementState,
	Jumping = "Jumping" :: MovementState,
	Falling = "Falling" :: MovementState,
	LightLanding = "LightLanding" :: MovementState,
	HeavyLanding = "HeavyLanding" :: MovementState,
	DashingForward = "DashingForward" :: MovementState,
	DashingSide = "DashingSide" :: MovementState,
	AirDashing = "AirDashing" :: MovementState,
	DoubleJumping = "DoubleJumping" :: MovementState,
	LedgeJumping = "LedgeJumping" :: MovementState,
	DodgeCancelling = "DodgeCancelling" :: MovementState,
	Sliding = "Sliding" :: MovementState,
	Crouching = "Crouching" :: MovementState,
	CrouchWalking = "CrouchWalking" :: MovementState,
	WallRunning = "WallRunning" :: MovementState,
	WallLeaping = "WallLeaping" :: MovementState,
	WallHanging = "WallHanging" :: MovementState,
	WallBoost = "WallBoost" :: MovementState,
	WallClingDoubleJump = "WallClingDoubleJump" :: MovementState,
	WallClimbLeaping = "WallClimbLeaping" :: MovementState,
})

return MovementState
