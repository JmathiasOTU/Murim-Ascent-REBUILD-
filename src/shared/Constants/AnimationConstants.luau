--!strict

local AnimationConstants = table.freeze({
	FadeTime = 0.15,

	-- Punchier than the generic FadeTime -- matches the old dash's snappy in/out feel.
	DashFadeInTime = 0.05,
	DashFadeOutTime = 0.2,
})

return AnimationConstants
