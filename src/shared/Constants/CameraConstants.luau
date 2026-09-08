--!strict

local CameraConstants = table.freeze({
	-- Strafe lean: rolls the camera toward/away from the strafe direction, smoothed toward its
	-- target rather than snapping.
	LeanMaxAngleDegrees = 2,
	LeanSpeed = 6,
	StrafeThreshold = 0.05,

	-- Wall-run lean: rolls the camera away from whichever side the wall is on (see
	-- WallRunController.GetWallLeanAmount), overriding the strafe lean above for as long as it's
	-- nonzero -- a plain strafe reading during a wall run is driven by residual MoveDirection input
	-- along the wall, not a meaningful side-to-side strafe, so it shouldn't compete with this instead.
	-- Reuses LeanSpeed for the same smoothing feel rather than a second tunable.
	WallRunLeanMaxAngleDegrees = 4,

	-- A small fixed dip the instant a jump starts.
	JumpDipDistance = 0.5,

	-- Landing dip scales with how hard the fall was, between these two fall-speed thresholds.
	LandingDipMinFallSpeed = 25,
	LandingDipMaxFallSpeed = 90,
	LandingDipMinDistance = 1.5,
	LandingDipMaxDistance = 3,

	LandingDipHoldTime = 0.12,
	LandingDipAttackSpeed = 16,
	LandingDipRecoverySpeed = 5,

	-- Sinks the camera while crouched/crouch-walking, smoothed the same way as the dips above.
	CrouchDistance = 2,
	CrouchSpeed = 8,

	-- Widens FOV as the Qinggong Sprinting technique's ramp progresses (see SprintController's
	-- GetSprintTarget) -- tracks the charge continuously rather than snapping on/off.
	SprintFovBoost = 15,
	SprintFovSpeed = 4,
	DefaultFOV = 70, -- fallback if CurrentCamera isn't set yet when this module first samples it
})

return CameraConstants
