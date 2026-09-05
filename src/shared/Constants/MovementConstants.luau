--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementState = require(ReplicatedStorage.Shared.Enums.MovementState)

local MovementConstants = table.freeze({
	WalkSpeed = 16,

	RunSpeed = 24,
	SprintKey = Enum.KeyCode.LeftShift,

	SpeedTolerance = 2,

	-- Fall speed (studs/s) is sampled at its peak during the fall, not at the Landed
	-- event itself, since impact velocity can already be resolved by physics by then.
	LightLandingSpeedThreshold = 25,
	HeavyLandingSpeedThreshold = 90,
	LightLandingRecoveryTime = 0.25,
	HeavyLandingRecoveryTime = 0.6,

	DashKey = Enum.KeyCode.Q,
	DashPower = 150,
	DashDuration = 0.63,
	DashBrakeForce = 0.85, -- fraction of residual horizontal velocity shed the instant Dashing ends
	DashCooldown = 1.5,
	DashSteerDeadzone = 0.1, -- MoveDirection magnitude below this doesn't redirect an in-flight dash
	MaxPhysicsForce = 100000,

	-- Dodge cancel (right-click mid-dash): cuts a Dash's remaining momentum short in exchange for
	-- control back immediately, at the cost of a charge. Charges regenerate on their own timer,
	-- independent of DashCooldown itself.
	RollCancelMaxCharges = 2,
	RollCancelChargeCooldown = 3.5, -- seconds to regenerate one charge

	SlideKey = Enum.KeyCode.C,
	SlideAltKey = Enum.KeyCode.LeftControl,
	SlideBoostMultiplier = 2.8, -- initial slide speed = current ground speed (or WalkSpeed if standing still) times this
	SlideFrictionDuration = 1.2, -- once the slope flattens, how long friction takes to decay speed to SlideFrictionFloorSpeed (and how long a flat stretch is tolerated before the slide ends)
	SlideGroundRayDistance = 5, -- downward ray from the root part used to read the slope's normal/angle underneath
	SlideSteepSlopeAngle = 20, -- degrees from vertical-up; at or above this, the slide keeps going (and speeding up) instead of decaying
	SlideSlopeAcceleration = 20, -- studs/sec^2 gained while continuously on a steep slope
	SlideMaxSpeed = 140,
	SlideUphillMomentumRetention = 0.25, -- fraction of speed kept the instant you turn to face back uphill
	SlideUphillDeceleration = 9, -- studs/sec^2 bleed while still facing uphill, on top of the instant retention cut
	SlideStopSpeedThreshold = 2, -- studs/sec; below this we've fully stopped (e.g. killed by the uphill decel) and exit immediately instead of waiting on the flat-ground timer
	SlideFrictionFloorSpeed = 6, -- speed the friction decay settles at before handing back to normal ground movement

	-- States a dedicated controller (Airborne/Dash/Slide) owns -- MovementController's ground auto-transition
	-- logic must not run while in one of these, until control is handed back via RefreshMovementState.
	LockedMovementStates = table.freeze({
		[MovementState.Jumping] = true,
		[MovementState.Falling] = true,
		[MovementState.LightLanding] = true,
		[MovementState.HeavyLanding] = true,
		[MovementState.Dashing] = true,
		[MovementState.Sliding] = true,
	}),
})

return MovementConstants
