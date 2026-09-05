--!strict

local MovementValidationConstants = table.freeze({
	SprintRequestCooldown = 0.1,
	SlideRequestCooldown = 0.1,
	ValidationTickRate = 1 / 15,

	-- A roll cancel ends the dash's speed exemption early, while real speed is still well above
	-- WalkSpeed. That residual velocity doesn't simply stick -- Humanoid's own ground controller
	-- keeps independently driving velocity off WalkSpeed/MoveDirection every physics step, so the
	-- two transiently combine (confirmed via testing: observed speed briefly ran ~45 studs/s
	-- against a WalkSpeed-16 allowance of 32) before settling. This buys that settling time, flat
	-- rather than latency-scaled -- it's a local physics interaction, not a network one.
	DashCancelExemptionGrace = 0.3,
})

return MovementValidationConstants
