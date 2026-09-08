--!strict

-- Populated as each combat mechanic (attack, parry, stagger, feint) is actually built -- see
-- MovementConstants.luau for the equivalent pattern movement already established. Every numeric
-- combat value (parry windows, stagger thresholds, hitstop durations, cooldowns) is routed here,
-- never hardcoded inline in a controller or service.
local CombatConstants = table.freeze({

	AttackCooldown = 0.6,

	-- The three phases of a single Attacking state (see AttackPhase/CombatValidationService.
	-- GetAttackPhase). Their sum is how long Attacking holds before auto-reverting to Idle.
	AttackWindupTime = 0.15, -- telegraph, no hitbox
	AttackActiveTime = 0.15, -- the hitbox window
	AttackRecoveryTime = 0.2, -- post-swing, no hitbox, can't act yet
})

return CombatConstants
