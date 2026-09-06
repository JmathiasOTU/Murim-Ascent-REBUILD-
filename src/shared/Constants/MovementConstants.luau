--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementState = require(ReplicatedStorage.Shared.Enums.MovementState)
local DashCategory = require(ReplicatedStorage.Shared.Enums.DashCategory)

local MovementConstants = table.freeze({
	WalkSpeed = 16,

	RunSpeed = 24,
	SprintKey = Enum.KeyCode.LeftShift,

	SpeedTolerance = 2.5,


	LightLandingSpeedThreshold = 25,
	-- A double jump's own DoubleJumpVelocity pop alone regains ~that much fall speed by the time
	-- you pass back through the point you used it (symmetric under gravity), so this needs enough
	-- headroom above DoubleJumpVelocity that a double-jump-only fall still reads as Light -- only a
	-- genuinely long fall (off a ledge/tower) should clear it.
	HeavyLandingSpeedThreshold = 110,
	LightLandingRecoveryTime = 0.25,
	HeavyLandingRecoveryTime = 0.6,
	MinLandingDropHeight = 2, -- studs of net descent from takeoff required before any landing recovery triggers

	DashKey = Enum.KeyCode.Q,
	DashPower = 150,
	DashDuration = 0.63,
	DashBrakeForce = 0.85, 

	DashCooldowns = table.freeze({
		[DashCategory.Forward] = 2.5,
		[DashCategory.Side] = 2.5,
	}),
	DashSteerDeadzone = 0.1,
	MaxPhysicsForce = 100000,
	DashCategorySwitchDelay = 0.3, -- min time into a dash before a different-category dash can cut it short

	-- Qinggong: air dash -- a single instantaneous impulse (not a held/steerable constraint like the
	-- ground dash), fired in the direction the character is facing and angled by camera pitch.
	AirDashSpeed = 150,
	AirDashVerticalMult = 1.2,
	AirDashWallSoftenRange = 3, -- studs; forward raycast range used to soften the impulse against a wall
	AirDashDuration = 0.35,
	AirDashCooldown = 2.5,

	-- Qinggong: double jump -- a fixed vertical pop (not a held boost), overwriting only Y velocity
	-- so horizontal momentum carries over untouched. Gated by a one-shot "used this jump" charge
	-- (see DoubleJumpController) rather than a cooldown timer -- it refills the instant you land.
	DoubleJumpVelocity = 100,
	DoubleJumpDuration = 0.35,

	-- Qinggong: ledge jump -- triggered by jumping while Sliding with no ground found ahead (a real
	-- edge, not just open ground). Overwrites velocity with a fixed forward+up launch, same one-shot
	-- impulse shape as the other Qinggong actions, but resolves through the ordinary
	-- Jumping->Freefall->Landed flow like a ground-truth jump instead of a controller-owned timer.
	LedgeJumpEdgeCheckForward = 3, -- studs ahead of the character the edge-detection raycast starts from
	LedgeJumpEdgeCheckDown = 5, -- studs that raycast looks down for ground
	LedgeJumpUpPower = 95,
	LedgeJumpForwardPower = 120,
	LedgeJumpServerEdgeCheckForward = 15, -- more forgiving than the client's own check; server position lags behind

	RollCancelMaxCharges = 2,
	RollCancelChargeCooldown = 3.5, 
	DodgeCancelRecoveryTime = 0.35, 

	SlideKey = Enum.KeyCode.C,
	SlideAltKey = Enum.KeyCode.LeftControl,
	SlideBoostMultiplier = 2.8,
	SlideFrictionDuration = 1.2, 
	SlideGroundRayDistance = 5, -- downward ray from the root part used to read the slope's normal/angle underneath
	SlideSteepSlopeAngle = 20, -- degrees from vertical-up; at or above this, the slide keeps going (and speeding up) instead of decaying
	SlideSlopeAcceleration = 20, -- studs/sec^2 gained while continuously on a steep slope
	SlideMaxSpeed = 140,
	SlideUphillMomentumRetention = 0.25, -- fraction of speed kept the instant you turn to face back uphill
	SlideUphillDeceleration = 9, -- studs/sec^2 bleed while still facing uphill, on top of the instant retention cut
	SlideStopSpeedThreshold = 2, -- studs/sec; below this we've fully stopped (e.g. killed by the uphill decel) and exit immediately instead of waiting on the flat-ground timer
	SlideFrictionFloorSpeed = 6, -- speed the friction decay settles at before handing back to normal ground movement

	CrouchSpeed = 6,

	-- States a dedicated controller (Airborne/Dash/Slide) owns -- MovementController's ground auto-transition
	-- logic must not run while in one of these, until control is handed back via RefreshMovementState.
	LockedMovementStates = table.freeze({
		[MovementState.Jumping] = true,
		[MovementState.Falling] = true,
		[MovementState.LightLanding] = true,
		[MovementState.HeavyLanding] = true,
		[MovementState.DashingForward] = true,
		[MovementState.DashingSide] = true,
		[MovementState.AirDashing] = true,
		[MovementState.DoubleJumping] = true,
		[MovementState.LedgeJumping] = true,
		[MovementState.DodgeCancelling] = true,
		[MovementState.Sliding] = true,
		[MovementState.Crouching] = true,
		[MovementState.CrouchWalking] = true,
	}),

	CrouchStates = table.freeze({
		[MovementState.Crouching] = true,
		[MovementState.CrouchWalking] = true,
	}),

	DashingStates = table.freeze({
		[MovementState.DashingForward] = true,
		[MovementState.DashingSide] = true,
	}),

	-- Player-triggered aerial actions that briefly own the FSM for a fixed duration and resolve
	-- back to Jumping/Falling themselves once done (see AirDashController/DoubleJumpController) --
	-- AirborneController must not let the underlying Humanoid's own Jumping<->Freefall flip (which
	-- an action's own velocity change can trigger) stomp over one mid-action. LedgeJumping is NOT
	-- one of these: it resolves through the ordinary Jumping->Freefall flow like a ground-truth
	-- jump, so that flip is exactly how it's supposed to end.
	QinggongActionStates = table.freeze({
		[MovementState.AirDashing] = true,
		[MovementState.DoubleJumping] = true,
	}),

	-- Every Qinggong one-shot: non-directional, Action-priority, quick dash-style fade in/out (see
	-- AnimationController). Broader than QinggongActionStates above -- this is purely about which
	-- animation treatment a state gets, independent of how its FSM lifecycle resolves.
	QinggongAnimationStates = table.freeze({
		[MovementState.AirDashing] = true,
		[MovementState.DoubleJumping] = true,
		[MovementState.LedgeJumping] = true,
	}),
})

return MovementConstants
