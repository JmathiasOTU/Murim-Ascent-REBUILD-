--!strict

export type CombatState = string

local CombatState = table.freeze({
	Idle = "Idle" :: CombatState,
	Attacking = "Attacking" :: CombatState,
	Parrying = "Parrying" :: CombatState,
	-- A legitimate cancelled attack, distinguished server-side from an exploited animation cancel --
	-- see CombatValidationService's own comment on why this can never share a code path with Idle.
	Feinting = "Feinting" :: CombatState,
	-- Entered on a posture break (failed parries/blocked hits draining Posture to 0) -- a guaranteed
	-- punish window, mirrored server-side identically to every other combat state.
	Staggered = "Staggered" :: CombatState,
})

return CombatState
