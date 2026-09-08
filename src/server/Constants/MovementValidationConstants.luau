--!strict

local MovementValidationConstants = table.freeze({
	SprintRequestCooldown = 0.1,
	SlideRequestCooldown = 0.1,
	CrouchRequestCooldown = 0.1,
	ValidationTickRate = 1 / 15,

	-- Floor on how often any single ability request is even considered per player, independent of
	-- that ability's own legality/charge rules -- DoubleJump/LedgeJump/WallRun/WallLeap/WallCling/
	-- WallBoost/WallClingDoubleJump/WallClimbLeap have no cooldown of their own (Dash/AirDash/Sprint/
	-- Slide/Crouch/RollCancel already do), so with many players on one server a client spamming one
	-- of those remotes would otherwise re-run its full check -- including a physics query
	-- (isNearWall) or raycast (ledge jump) -- as fast as it can fire the remote. This is a single
	-- cheap table lookup checked before any of that real work happens, not gameplay-facing (no
	-- legitimate input device fires the same ability faster than 20/sec).
	MinAbilityRequestInterval = 0.05,

	-- A roll cancel ends the dash's speed exemption early, while real speed is still well above
	-- WalkSpeed. That residual velocity doesn't simply stick -- Humanoid's own ground controller
	-- keeps independently driving velocity off WalkSpeed/MoveDirection every physics step, so the
	-- two transiently combine (confirmed via testing: observed speed briefly ran ~45 studs/s
	-- against a WalkSpeed-16 allowance of 32) before settling. This buys that settling time, flat
	-- rather than latency-scaled -- it's a local physics interaction, not a network one.
	DashCancelExemptionGrace = 0.3,

	SpeedViolationStreakThreshold = 3, -- absorbs the network-latency race before RequestDash's exemption lands
	CrouchSpeedSettleGrace = 0.2, -- lets residual pre-crouch velocity decay to CrouchSpeed before checks resume
	FullSprintSettleGrace = 0.2, -- same idea, for the Qinggong Sprinting technique's WalkSpeed jump

	-- How long the elevated SlideMaxSpeed allowance survives without a fresh RequestSlide(true)
	-- renewal (see MovementConstants.SlideRenewalInterval, which SlideController renews on) before
	-- _validatePlayer forces isSliding back off. Wide enough over the ~0.5s renewal cadence to absorb
	-- one dropped/late renewal plus network jitter without a visible speed snap for a legitimate
	-- slide, but still short enough that a single unverified claim can't grant SlideMaxSpeed forever.
	SlideRenewalGraceWindow = 1.2,

	-- Same idea as SlideRenewalGraceWindow, for the Qinggong Sprinting technique's SprintSpeed
	-- allowance (see MovementConstants.FullSprintRenewalInterval) -- RequestSprintTechnique(true) had
	-- no expiry at all before this, so a single unverified claim held SprintSpeed permanently.
	FullSprintRenewalGraceWindow = 1.2,

	-- Small buffer added on top of MovementConstants.SlideFrictionDuration before _validatePlayer
	-- force-ends a slide that's been on non-steep ground too long (see getSlopeAngle below) -- covers
	-- the gap between the client's own SlideController decay-to-end timer firing and its
	-- RequestSlide(false) actually arriving over the network. Not a gameplay-facing allowance -- a
	-- legitimate slide always ends client-side at SlideFrictionDuration regardless of this.
	SlideFlatGroundNetworkGrace = 0.3,

	-- Threshold below which vertical velocity counts as "actually descending" for the flat-ground
	-- slide timeout's steep-slope check (see getSlopeAngle's caller in _validatePlayer) -- slope ANGLE
	-- alone can't tell downhill from uphill, so a modified client holding a slide facing up a >=20deg
	-- incline would otherwise read as "steep" forever and never trip the timeout. -5 studs/s is a
	-- cheap, safe proxy rather than full slope-projected velocity math: a legitimate slide entering
	-- even the shallowest qualifying incline (SlideSteepSlopeAngle, 20deg) produces Y velocity well
	-- past -5 while genuinely descending, so this only excludes someone stationary-ish or moving
	-- upward on the slope, exactly the case that needs to fall through to the timeout.
	SlideDownhillVelocityThreshold = -5,

	-- Radius for the wall-run/wall-leap proximity sanity check (isNearWall below) -- generous on
	-- purpose (this is a coarse backstop against claiming either with no wall at all, not precision
	-- anti-cheat) since the server's own snapshot of the character can already be a few studs behind
	-- the client's by the time this validates, on top of the latency-projection term below.
	WallProximityCheckDistance = 16,
	WallProximityLatencyCap = 2,

	-- An air dash or ledge jump is a one-shot impulse with no braking, unlike the ground dash --
	-- residual velocity keeps carrying the player until they actually land, at an unpredictable time
	-- well past either request's own short (or nonexistent) exemption window. Granted instead at the
	-- moment the server's own airborne poll detects landing (see _validatePlayer), same settle-time
	-- reasoning as the ground dash's exemptions, just anchored to a different event.
	AerialActionLandingSettleGrace = 0.3,

	-- Small buffer added on top of a character's own HipHeight + half its root part height when
	-- isAirborne (above) casts its downward ground-check ray -- covers minor terrain unevenness,
	-- stairs, and ramps without needing a precise per-surface tolerance, same coarse-check spirit as
	-- WallProximityCheckDistance/SlideGroundRayDistance elsewhere in this file.
	GroundCheckMargin = 2,

	-- Vertical speed above which isAirborne (above) treats the player as airborne EVEN IF the ground
	-- raycast still finds ground within range -- covers the very first tick or two of a legitimate
	-- jump, where Y position (and so the raycast) hasn't moved yet but Roblox already set the full
	-- jump velocity instantaneously. Sized well below Roblox's default JumpPower (50 studs/s, unused
	-- by this project but still the floor for how slow a real jump's launch velocity ever is) so a
	-- real jump is never missed, while comfortably above ordinary grounded jitter (stair-stepping,
	-- floor-snap corrections) so standing still doesn't false-flag as airborne.
	AirborneVerticalVelocityThreshold = 10,

	-- Minimum elapsed time isAirborne (above) requires before trusting its own position-delta vertical
	-- velocity estimate. That estimate reuses record.lastPosition/lastCheckTime -- refreshed every
	-- ValidationTickRate tick by _validatePlayer regardless of when isAirborne is actually called (one
	-- of the 8 ability-request handlers, at an arbitrary time, or _validatePlayer itself), so normally
	-- never more than about one tick stale. The one case that doesn't cover: a call landing so soon
	-- after that refresh that the elapsed denominator is near zero, which would amplify ordinary
	-- position jitter into a spurious velocity reading. Comfortably below a real validation tick
	-- (~0.067s) so it never narrows the check under normal operation, just guards the near-zero edge.
	MinVerticalCheckElapsed = 0.01,

	-- Dedicated speed-check exemption window for a wall leap's own outward burst (see
	-- _onRequestWallLeap), same pattern ground dash and roll cancel already use -- WallRunning ->
	-- WallLeaping is an airborne-to-airborne transition (both keep the Humanoid in Freefall), so it
	-- never passes through the wasAirborne-and-not-airborneNow landing transition that grants
	-- AerialActionLandingSettleGrace elsewhere in this file. Without its own grant, a leap fired while
	-- an unrelated, lower-ceiling exemption happens to still be open (e.g. the Qinggong Sprinting
	-- technique's own FullSprintSettleGrace, renewed every ~0.5s and active ~40% of the time while
	-- sprinting) gets validated against THAT far lower ceiling instead of the airborne one -- this is
	-- the confirmed cause of the intermittent, latency-independent wall-run-into-leap rubberband.
	-- Covers WallLeapReleaseDelay (0.15s) plus a little past it for the settle back into free physics.
	WallLeapSpeedExemptionGrace = 0.25,

	-- Same reasoning and same structural gap as WallLeapSpeedExemptionGrace above, for
	-- WallClimbLeap -- WallHanging -> WallClimbLeaping is the identical airborne-to-airborne shape
	-- (WallClingController._tryWallClimbLeap also forces Freefall via ChangeState). Named separately
	-- from the wall-leap grace rather than reusing it, even though currently the same value, so the
	-- two can be tuned independently later (WallClimbLeapReleaseDelay already has its own constant too).
	WallClimbLeapSpeedExemptionGrace = 0.25,
})

return MovementValidationConstants
