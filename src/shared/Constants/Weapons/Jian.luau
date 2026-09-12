--!strict

local WeaponTypes = require(script.Parent.WeaponTypes)

-- Placeholders for playtesting, not final balance -- same status as the rest of the design doc.
local Jian: WeaponTypes.WeaponDefinition = table.freeze({
	DisplayName = "Jian",
	Category = "Medium",
	AttackSpeedMultiplier = 1.0,

	ComboSteps = table.freeze({ "M1_1", "M1_2", "M1_3", "M1_4" }),

	ComboData = table.freeze({
		M1_1 = table.freeze({
			Damage = 8,
			PostureDamage = 10,
			Knockback = 8,
			Hitstun = 0.3,
			Windup = 0.15,
			Active = 0.1,
			Recovery = 0.25,
			HitstopDuration = 0.06,
			Unparryable = false,
		}),
		M1_2 = table.freeze({
			Damage = 8,
			PostureDamage = 10,
			Knockback = 8,
			Hitstun = 0.3,
			Windup = 0.15,
			Active = 0.1,
			Recovery = 0.25,
			HitstopDuration = 0.06,
			Unparryable = false,
		}),
		M1_3 = table.freeze({
			Damage = 9,
			PostureDamage = 11,
			Knockback = 10,
			Hitstun = 0.32,
			Windup = 0.16,
			Active = 0.1,
			Recovery = 0.27,
			HitstopDuration = 0.07,
			Unparryable = false,
		}),
		-- Knockback finisher.
		M1_4 = table.freeze({
			Damage = 12,
			PostureDamage = 14,
			Knockback = 24,
			Hitstun = 0.4,
			Windup = 0.2,
			Active = 0.12,
			Recovery = 0.35,
			HitstopDuration = 0.1,
			Unparryable = false,
		}),
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
