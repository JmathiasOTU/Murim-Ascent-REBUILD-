--!strict

export type CombatState = string

local CombatState = table.freeze({
	Idle = "Idle" :: CombatState,
	Attacking = "Attacking" :: CombatState,
	Feinting = "Feinting" :: CombatState,
	CastingSkill = "CastingSkill" :: CombatState,
	Parrying = "Parrying" :: CombatState,
	Blocking = "Blocking" :: CombatState,
	-- No Dodging state -- that's the ground Dash (movement layer), not a combat FSM state. See
	-- Combat_Framework_Design_Doc Section 3.
	Hitstun = "Hitstun" :: CombatState,
	Staggered = "Staggered" :: CombatState,
	Defeated = "Defeated" :: CombatState,
})

return CombatState
