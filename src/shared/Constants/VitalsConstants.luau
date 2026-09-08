--!strict

local VitalsConstants = table.freeze({
	RegenTickRate = 0.1, -- seconds between passive-regen ticks

	-- Passive regen per second. 0 means "nothing drains this pool yet" -- Health/Posture/Qi have no
	-- combat system driving them down, so there's nothing to regenerate from yet either.
	HealthRegenPerSecond = 0,
	PostureRegenPerSecond = 0,
	QiRegenPerSecond = 0,
	QinggongRegenPerSecond = 6,

	-- Seconds since the pool was last spent/drained before regen resumes -- lets Qinggong Sprinting
	-- stay completely free (it no longer touches this pool at all) while still capping how long
	-- someone can keep chaining actual Qinggong abilities (wall run, air dash, etc.) back to back:
	-- doing so keeps resetting this timer, so the pool only climbs back once they actually stop.
	HealthRegenDelay = 0,
	PostureRegenDelay = 0,
	QiRegenDelay = 0,
	QinggongRegenDelay = 7,
})

return VitalsConstants
