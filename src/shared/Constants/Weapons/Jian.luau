--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponTypes = require(script.Parent.WeaponTypes)
local buildComboData = require(ReplicatedStorage.Shared.Utils.BuildComboData)

-- Placeholders for playtesting, not final balance -- same status as the rest of the design doc.

-- M1_1-M1_3 all share this as-is; only the knockback finisher (M1_4) overrides.
local BaseM1Step: WeaponTypes.ComboStepData = table.freeze({
	Damage = 8,
	PostureDamage = 10,
	Knockback = 8,
	Hitstun = 0.3,
	Windup = 0.15,
	Active = 0.1,
	Recovery = 0.25,
	HitstopDuration = 0.06,
	Unparryable = false,
})

local Jian: WeaponTypes.WeaponDefinition = table.freeze({
	DisplayName = "Jian",
	Category = "Medium",
	AttackSpeedMultiplier = 1.0,

	ComboSteps = table.freeze({ "M1_1", "M1_2", "M1_3", "M1_4" }),

	ComboData = buildComboData({ "M1_1", "M1_2", "M1_3", "M1_4" }, BaseM1Step, {
		-- Knockback finisher.
		M1_4 = {
			Damage = 12,
			PostureDamage = 14,
			Knockback = 24,
			Hitstun = 0.4,
			Windup = 0.2,
			Active = 0.12,
			Recovery = 0.35,
			HitstopDuration = 0.1,
		},
	}),

	CriticalAttack = table.freeze({
		Windup = 0.25,
		Active = 0.12,
		Recovery = 0.4,
		DashDistance = 6,
		DashDuration = 0.2,
		Damage = 16,
		PostureDamage = 24,
		Knockback = 14,
		Cooldown = 6,
		HitstopDuration = 0.12,
		Unparryable = false,
	}),
})

return Jian
