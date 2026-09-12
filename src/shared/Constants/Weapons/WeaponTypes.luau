--!strict

-- Types-only module, shared by WeaponDefinitions.luau (the aggregator) and every per-weapon file
-- under this folder -- keeps per-weapon files from requiring the aggregator just to annotate
-- against its own shape, which would be a require cycle.

export type ComboStepData = {
	Damage: number,
	PostureDamage: number,
	Knockback: number,
	Hitstun: number,
	Windup: number,
	Active: number,
	Recovery: number,
	HitstopDuration: number,
	Unparryable: boolean,
}

export type CriticalAttackData = {
	Windup: number,
	Active: number,
	Recovery: number,
	DashDistance: number,
	DashDuration: number,
	Damage: number,
	PostureDamage: number,
	Knockback: number,
	Cooldown: number,
	HitstopDuration: number,
	Unparryable: boolean,
}

export type WeaponDefinition = {
	DisplayName: string,
	Category: string, -- "Light" | "Medium" | "Heavy" | "Fist"
	AttackSpeedMultiplier: number,
	ComboSteps: { string },
	ComboData: { [string]: ComboStepData },
	CriticalAttack: CriticalAttackData,
}

return {}
