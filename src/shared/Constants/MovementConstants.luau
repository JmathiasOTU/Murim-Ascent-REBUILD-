--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementState = require(ReplicatedStorage.Shared.Enums.MovementState)
local DashCategory = require(ReplicatedStorage.Shared.Enums.DashCategory)

local MovementConstants = table.freeze({
	WalkSpeed = 16,

	RunSpeed = 24,
	SprintForwardKey = Enum.KeyCode.W,
	SprintDoubleTapWindow = 0.3, -- max seconds between two W presses for the second one to trigger sprint

	-- Qinggong: sprinting -- a technique layered on top of ordinary Running, not the double-tap-W
	-- run above (naming collision is unfortunate but pre-existing; that one just means "hold W").
	-- Holding Running (moving, not crouched) for SprintHoldDuration unlocks a ramp: WalkSpeed, camera
	-- FOV, and the wind SFX's volume all ease from Running's level up to full Sprint over
	-- SprintRampDuration, at which point the animation swaps and the wind VFX/full-volume SFX kick
	-- in. See SprintController.
	SprintHoldDuration = 3,
	SprintRampDuration = 3,
	SprintSpeed = 38,
	SprintSfxStartVolumeFraction = 0.2, -- fraction of the sound's authored volume it starts the ramp at
	SprintSfxFadeOutSpeed = 6, -- exponential ease-out rate once the technique ends, instead of cutting instantly

	-- Cross-ability empowerment while SprintController:IsSprintActive() -- applied once, at the
	-- moment each ability starts, on top of its own normal calculation.
	SprintSlideSpeedMultiplier = 1.25,
	-- Reduced from 1.25 -- still faster than a plain (non-Qinggong-Sprinting) wall run, just less of
	-- a jump than before.
	SprintWallRunSpeedMultiplier = 1.15,
	SprintWallJumpMultiplier = 1.2, -- WallBoost and WallClimbLeaping's launch power (WallLeaping has its own multiplier below)
	-- Split off from SprintWallJumpMultiplier and reduced (was 1.2) -- WallLeaping specifically got
	-- nerfed while sprinting, still above the un-sprinted 1x baseline.
	SprintWallLeapMultiplier = 1.1,
	SprintLedgeJumpMultiplier = 1.25,

	SpeedTolerance = 2.5,


	LightLandingSpeedThreshold = 25,
	
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
	MaxPhysicsTorque = 100000, -- AlignOrientation's torque cap (see WallRunController) -- same generous ceiling as MaxPhysicsForce, just the rotational counterpart
	DashCategorySwitchDelay = 0.3, -- min time into a dash before a different-category dash can cut it short

	-- Qinggong: air dash -- a single instantaneous impulse (not a held/steerable constraint like the
	-- ground dash), fired in the direction the character is facing and angled by camera pitch.
	-- Reduced 25% from 150: most players won't have the Qinggong stat to justify the old speed.
	AirDashSpeed = 112.5,
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
	-- Both reduced 25% from 95/120 as part of the general Qinggong movement nerf.
	LedgeJumpUpPower = 71.25,
	LedgeJumpForwardPower = 90,
	LedgeJumpServerEdgeCheckForward = 15, -- more forgiving than the client's own check; server position lags behind

	-- Qinggong: wall running -- latching onto a side wall while airborne holds the character against
	-- it (a full-lock LinearVelocity + AlignOrientation constraint, the same pooled-constraint shape
	-- Dash/Slide already use) and runs it along the wall's tangent instead of falling. Entry requires
	-- actually moving into a side wall (see WallRunController.checkWallRun); exit is polled every
	-- ParkourTickRate rather than waited on a single event, since losing the wall or reaching the
	-- floor can each happen mid-run without Humanoid ever firing its own Landed for it.
	WallSideRayDistance = 3.5,
	WallFlatnessThreshold = 0.2, -- |normal.Y| below this counts as a side wall, not a floor/ceiling
	WallRunFloorCheckDistance = 3.2, -- downward ray below the root part; a hit this close ends the run into a landing instead of running through the floor
	-- Reduced 25% from 80 as part of the general Qinggong movement nerf.
	WallRunSpeed = 60,
	-- Steady downward sink once the entry boost below decays out. Raised from 5 so a wall run drops
	-- off (and ends) noticeably faster instead of letting an un-upgraded Qinggong stat hang on a wall
	-- for a long, flat run.
	WallRunGravity = 14,
	WallRunPushInSpeed = 2, -- studs/sec held into the wall's normal, keeping contact against the throttled raycast's staleness between samples
	-- Entering WallRunning otherwise never actually lifts the character off the ground -- it just
	-- reorients them to the wall and starts the steady WallRunGravity sink, so latching on from a
	-- shallow sprint-induced hop (not a real jump) would leave them within the floor-check distance
	-- above and boot them straight back out on the very next tick. This decays linearly from
	-- WallRunEntryBoostPower down to -WallRunGravity over WallRunEntryBoostDuration, guaranteeing real
	-- clearance the instant the wall is latched onto instead of relying on whatever air was already there.
	-- Reduced 25% from 24 as part of the general Qinggong movement nerf.
	WallRunEntryBoostPower = 18,
	WallRunEntryBoostDuration = 0.4,
	WallRunTurnResponsiveness = 30,
	WallRunMaxDuration = 50, -- outer failsafe cap; the wall/floor polling above is what actually ends a run in practice
	ParkourTickRate = 0.033, -- ~30 scans/sec, FPS independent -- throttles the wall-run raycasts (both steering and exit-condition)

	-- Caps consecutive wall-run entries (run -> leap -> run -> ...) before a real ground landing is
	-- required to reset the count -- same shape as WallClingMaxChainCount below, stops an
	-- un-upgraded Qinggong stat from leap-chaining along walls indefinitely. See WallRunController.
	WallRunMaxChainCount = 3,

	-- Qinggong: wall leaping -- WallRunning's exit move. A brief, non-steerable outward+upward burst
	-- (not a held constraint like the run) angled off the wall's normal, blended toward the direction
	-- already facing. The character is nudged clear of the wall's surface first and the burst is held
	-- by a brief hard lock (WallLeapReleaseDelay) before releasing to free-fall physics, so grazing the
	-- same wall the frame after leaping can't immediately zero the impulse back out.
	-- Both reduced 25% from 140/80 as part of the general Qinggong movement nerf.
	WallLeapOutwardPower = 105,
	WallLeapUpwardPower = 60,
	WallLeapForwardOffset = 0.8,
	WallLeapNormalOffset = 1.5, -- studs the root part is nudged out along the wall normal before the impulse, clearing it
	WallLeapRayLength = 10, -- longer than WallSideRayDistance -- allows a little more drift from the wall between the run ending and the leap firing
	WallLeapReleaseDelay = 0.15, -- how long the hard velocity lock holds before releasing to free physics
	WallLeapDuration = 0.2, -- fallback: auto-resolves WallLeaping to Jumping/Falling if nothing else already has by then
	WallRunChainEntryRayDistance = 6, -- longer than WallSideRayDistance -- entry off a leap is only checked on the Space keypress, and WallLeapOutwardPower closes a 3.5-stud gap fast enough that physics can bounce off the next wall before that ray ever sees it; reaching further lets the latch win the race

	-- Qinggong: wall clinging/climbing -- latching onto a wall dead ahead (not to the side, like
	-- WallRunning) while airborne. A three-ray check (center + two side-offset rays, all forward)
	-- instead of WallRunning's single side ray, since a flat wall square in front of the camera needs
	-- wider forward coverage to avoid losing the grab to a gap/corner one ray happens to sample.
	WallSideCheckOffset = 1, -- lateral offset of the two side rays in the cling check
	WallClingDetectionRange = 5,
	WallClingSlideAcceleration = 8, -- studs/sec^2 the grip-loss downward slide ramps up at from a standstill
	WallClingMaxSlideSpeed = 25,
	WallClingDuration = 1.4, -- max hang time before auto-releasing into Falling

	-- Caps consecutive wall-cling grabs (WallHanging entries) before a real ground landing is
	-- required to reset the count -- stops an un-upgraded Qinggong stat from chaining cling->boost
	-- indefinitely up a wall. See WallClingController. Could scale up with a future Qinggong stat
	-- upgrade, but that system doesn't exist yet.
	WallClingMaxChainCount = 3,

	-- A single one-shot impulse straight off AssemblyLinearVelocity (not the held constraint above),
	-- fired away from the wall using whatever direction the cling already snapped the character to
	-- face -- same shape as DoubleJumpController's vertical-only pop, just angled outward too.
	WallBoostPower = 90,
	WallBoostBackPower = 35,
	WallBoostDuration = 0.8, -- hard timeout backstop if the apex (Y velocity <= 0) poll never fires

	-- A weak recovery hop, mechanically identical to an ordinary double jump but gated by this
	-- deadline instead of DoubleJumpController's own charge -- gives one more shot at reconnecting to
	-- a wall (or just softening a fall) right after a WallBoost whose apex lands over open air.
	WallClingDoubleJumpVelocity = 60,
	WallClingDoubleJumpDuration = 0.5,
	WallClingDoubleJumpWindow = 1.5, -- window after a WallBoost ends during which the hop is available

	
	WallClimbLeapOutwardPower = 100,
	WallClimbLeapUpwardPower = 50,
	WallClimbLeapNormalOffset = 1.5, -- studs the root part is nudged out along the release direction before the impulse
	WallClimbLeapReleaseDelay = 0.15,
	WallClimbLeapDuration = 0.3, -- fallback: auto-resolves WallClimbLeaping to Jumping/Falling if nothing else already has by then

	-- Flat Qinggong cost charged server-side (PlayerVitalsService:Spend, see
	-- MovementValidationService) the moment each of these actually starts -- mirrored client-side too
	-- (see Shared.Utils.HasEnoughQinggong) so a controller doesn't even attempt an ability it can't
	-- afford, the same way it already won't attempt one that's on cooldown or out of charges.
	QinggongCostAirDash = 5,
	QinggongCostDoubleJump = 4,
	QinggongCostLedgeJump = 3,
	QinggongCostWallRun = 4,
	QinggongCostWallLeap = 3,
	QinggongCostWallCling = 3,
	QinggongCostWallBoost = 4,
	QinggongCostWallClingDoubleJump = 4,
	QinggongCostWallClimbLeap = 4,

	-- Sprinting deliberately costs nothing from this pool -- see VitalsConstants.QinggongRegenDelay
	-- for how spam of the abilities above is kept in check instead (a delay before the pool starts
	-- regenerating again, rather than sprinting draining it).
	--
	-- Considered but NOT decided/implemented: escalating cost per Qinggong ability used within a
	-- short window (each use within ~3s of the last costs progressively more, resetting once you
	-- stop) as a "fatigue" alternative/addition to the regen delay. Revisit if the flat regen delay
	-- doesn't feel right in practice.

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
		[MovementState.WallRunning] = true,
		[MovementState.WallLeaping] = true,
		[MovementState.WallHanging] = true,
		[MovementState.WallBoost] = true,
		[MovementState.WallClingDoubleJump] = true,
		[MovementState.WallClimbLeaping] = true,
		[MovementState.SprintCharging] = true,
		[MovementState.Sprinting] = true,
	}),

	-- States the sprint boost (SprintController:IsSprintActive) survives passing through on the way
	-- to "coming to a stop" -- the whole jump/parkour/landing/slide envelope, same reasoning as the
	-- old game's separate FOV/SFX/VFX continuation lists, unified into one set here. Deliberately
	-- excludes SprintCharging itself: getting interrupted mid-ramp (e.g. jumping before it completes)
	-- should NOT count as having earned the boost.
	SprintCarryStates = table.freeze({
		[MovementState.Sprinting] = true,
		[MovementState.Jumping] = true,
		[MovementState.Falling] = true,
		[MovementState.DoubleJumping] = true,
		[MovementState.AirDashing] = true,
		[MovementState.LedgeJumping] = true,
		[MovementState.LightLanding] = true,
		[MovementState.HeavyLanding] = true,
		[MovementState.Sliding] = true,
		[MovementState.WallRunning] = true,
		[MovementState.WallLeaping] = true,
		[MovementState.WallHanging] = true,
		[MovementState.WallBoost] = true,
		[MovementState.WallClingDoubleJump] = true,
		[MovementState.WallClimbLeaping] = true,
	}),

	CrouchStates = table.freeze({
		[MovementState.Crouching] = true,
		[MovementState.CrouchWalking] = true,
	}),

	DashingStates = table.freeze({
		[MovementState.DashingForward] = true,
		[MovementState.DashingSide] = true,
	}),

	-- Player-triggered aerial actions that briefly (a fixed duration for AirDash/DoubleJump/WallLeap,
	-- a geometry-polled one for WallRun) own the FSM and resolve back to Jumping/Falling themselves
	-- once done (see AirDashController/DoubleJumpController/WallRunController) -- AirborneController
	-- must not let the underlying Humanoid's own Jumping<->Freefall flip (which an action's own
	-- velocity change can trigger) stomp over one mid-action. LedgeJumping is NOT one of these: it
	-- resolves through the ordinary Jumping->Freefall flow like a ground-truth jump, so that flip is
	-- exactly how it's supposed to end.
	QinggongActionStates = table.freeze({
		[MovementState.AirDashing] = true,
		[MovementState.DoubleJumping] = true,
		[MovementState.WallRunning] = true,
		[MovementState.WallLeaping] = true,
		[MovementState.WallHanging] = true,
		[MovementState.WallBoost] = true,
		[MovementState.WallClingDoubleJump] = true,
		[MovementState.WallClimbLeaping] = true,
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
