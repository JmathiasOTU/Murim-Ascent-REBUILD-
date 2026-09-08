--!strict

-- Sub-phases of CombatState.Attacking -- not their own FSM states (see CombatValidationService's
-- own comment on why), just what a caller gets back from GetAttackPhase to know where in the swing
-- the player currently is.
export type AttackPhase = string

local AttackPhase = table.freeze({
	Windup = "Windup" :: AttackPhase, -- telegraph, no hitbox yet
	Active = "Active" :: AttackPhase, -- the hitbox window
	Recovery = "Recovery" :: AttackPhase, -- post-swing, no hitbox, can't act yet
})

return AttackPhase
