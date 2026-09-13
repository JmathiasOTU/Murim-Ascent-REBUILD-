--!strict

local AnimationConstants = table.freeze({
	FadeTime = 0.15,

	-- Punchier than the generic FadeTime -- matches the old dash's snappy in/out feel.
	DashFadeInTime = 0.05,
	DashFadeOutTime = 0.2,

	-- Sized for a combo step's own pace (Combat Framework Bugfix Addendum Section 2.3), not Dash's --
	-- DashFadeOutTime (0.2s) was long enough relative to M1's ~0.36-0.56s total Windup+Active+Recovery
	-- that mashing stacked multiple Action-priority tracks mid-fade on the same joints. The chain gate
	-- (AttackController._earliestChainTime / CombatValidationService.earliestChainTime) now stops that
	-- at the source, but this keeps the transition itself tight regardless.
	ComboChainFadeInTime = 0.05,
	ComboChainFadeOutTime = 0.1,
})

return AnimationConstants
