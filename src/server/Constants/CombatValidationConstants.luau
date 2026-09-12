--!strict

local CombatValidationConstants = table.freeze({
	-- Floor on how often RequestAttack is even considered per player, independent of combo legality
	-- -- same role as MovementValidationConstants.MinAbilityRequestInterval, required generally by
	-- the Roblox AI Guidelines' remote-rate-limiting rule, not just for Parry.
	MinAttackRequestInterval = 0.05,

	-- Network buffer added on top of a combo step's own Windup+Active+Recovery before the server
	-- forces the attacker back to Idle -- covers the gap between the client's own step-end timeout
	-- firing and the next RequestAttack actually arriving, same "settle time, not a bypass" spirit as
	-- MovementValidationConstants' various *Grace fields.
	ComboStepGrace = 0.15,

	-- Remote-level floor, same role as MovementValidationConstants.SprintRequestCooldown/
	-- SlideRequestCooldown/CrouchRequestCooldown for their own toggle remotes.
	GuardRequestCooldown = 0.1,
})

return CombatValidationConstants
