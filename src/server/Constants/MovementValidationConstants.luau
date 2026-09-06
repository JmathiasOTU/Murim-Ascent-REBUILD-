--!strict

local MovementValidationConstants = table.freeze({
	SprintRequestCooldown = 0.1,
	SlideRequestCooldown = 0.1,
	CrouchRequestCooldown = 0.1,
	ValidationTickRate = 1 / 15,

	-- A roll cancel ends the dash's speed exemption early, while real speed is still well above
	-- WalkSpeed. That residual velocity doesn't simply stick -- Humanoid's own ground controller
	-- keeps independently driving velocity off WalkSpeed/MoveDirection every physics step, so the
	-- two transiently combine (confirmed via testing: observed speed briefly ran ~45 studs/s
	-- against a WalkSpeed-16 allowance of 32) before settling. This buys that settling time, flat
	-- rather than latency-scaled -- it's a local physics interaction, not a network one.
	DashCancelExemptionGrace = 0.3,

	SpeedViolationStreakThreshold = 3, -- absorbs the network-latency race before RequestDash's exemption lands
	CrouchSpeedSettleGrace = 0.2, -- lets residual pre-crouch velocity decay to CrouchSpeed before checks resume

	-- An air dash or ledge jump is a one-shot impulse with no braking, unlike the ground dash --
	-- residual velocity keeps carrying the player until they actually land, at an unpredictable time
	-- well past either request's own short (or nonexistent) exemption window. Granted instead at the
	-- moment the server's own airborne poll detects landing (see _validatePlayer), same settle-time
	-- reasoning as the ground dash's exemptions, just anchored to a different event.
	AerialActionLandingSettleGrace = 0.3,
})

return MovementValidationConstants
