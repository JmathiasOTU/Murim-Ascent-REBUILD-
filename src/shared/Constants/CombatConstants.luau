--!strict

-- Skeleton only -- the full value table (weapon/skill hit data, cooldowns, hitstop, etc.) is a
-- content pass deferred until after the framework itself is built (see Combat_Framework_Design_Doc
-- Section 11). These four are the only values the design doc has actually confirmed so far.
local CombatConstants = table.freeze({
	PARRY_WINDOW = 0.2,

	PostureRegenRate = 0.035, -- fraction of max posture regenerated per second while not Blocking/Staggered/in Hitstun
	PostureRegenDelay = 1.35, -- seconds after taking posture damage before regen resumes
	ParryPostureRelief = 0.225, -- fraction of max posture restored on a successful parry

	-- Block and Parry share one hold key: pressing it opens a PARRY_WINDOW-long parry attempt;
	-- if nothing gets parried before the window ends (or the key is released first) it's a whiff,
	-- and if the key is still held at that point it drops straight into Blocking instead of Idle --
	-- stays Blocking for as long as the key is held. Not specified in the design doc, picked to
	-- avoid every key movement already owns (W/Q/C/LeftControl/Space, MouseButton1 for M1,
	-- MouseButton2 for RollCancel).
	GuardKey = Enum.KeyCode.F,

	-- Placeholder -- Section 3 names this mechanic ("Whiff -> parry goes on cooldown, forced into
	-- Block-only until it expires") but gives no number (unlike PARRY_WINDOW's confirmed 0.2).
	ParryWhiffCooldown = 1.5,

	-- TEMP: no weapon-equip system yet (design doc Section 13) -- every player is assumed to have
	-- this weapon equipped. Single source of truth for AttackController/CombatAnimationController/
	-- CombatValidationService so the three can't drift out of sync; delete once equipping exists.
	PlaceholderEquippedWeaponId = "Fist",
})

return CombatConstants
