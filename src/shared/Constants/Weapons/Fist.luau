--!strict

local WeaponTypes = require(script.Parent.WeaponTypes)

-- Placeholders for playtesting, not final balance -- same status as the rest of the design doc.
-- NOT dual-wield -- corrected from an earlier draft that mirrored Dagger's 5-step alternating
-- shape. Fist isn't a unique combo, it follows the exact same linear M1x4 pattern as Jian's
-- baseline (Combat_Framework_Design_Doc Section 4); only the numbers and AttackSpeedMultiplier
-- differ -- faster, lower per-hit damage, sustained pressure. Own category (not grouped under
-- Light) per Section 4/8 -- Male's "Heavy weapon + Fist synergy" and Female's "Light weapon
-- synergy" are meant to be distinct bonuses, which collapsing Fist into Light would have lost.
local Fist: WeaponTypes.WeaponDefinition = table.freeze({
	DisplayName = "Fist",
	Category = "Fist",
	AttackSpeedMultiplier = 1.2,

	ComboSteps = table.freeze({ "M1_1", "M1_2", "M1_3", "M1_4" }),

	ComboData = table.freeze({
		M1_1 = table.freeze({
			Damage = 5,
			PostureDamage = 6,
			Knockback = 3,
			Hitstun = 0.2,
			Windup = 0.1,
			Active = 0.08,
			Recovery = 0.18,
			HitstopDuration = 0.04,
			Unparryable = false,
		}),
		M1_2 = table.freeze({
			Damage = 5,
			PostureDamage = 6,
			Knockback = 3,
			Hitstun = 0.2,
			Windup = 0.1,
			Active = 0.08,
			Recovery = 0.18,
			HitstopDuration = 0.04,
			Unparryable = false,
		}),
		M1_3 = table.freeze({
			Damage = 6,
			PostureDamage = 7,
			Knockback = 4,
			Hitstun = 0.22,
			Windup = 0.11,
			Active = 0.08,
			Recovery = 0.19,
			HitstopDuration = 0.05,
			Unparryable = false,
		}),
		-- Knockback finisher, same pattern as Jian's M1_4.
		M1_4 = table.freeze({
			Damage = 9,
			PostureDamage = 10,
			Knockback = 16,
			Hitstun = 0.35,
			Windup = 0.16,
			Active = 0.1,
			Recovery = 0.3,
			HitstopDuration = 0.08,
			Unparryable = false,
		}),
	}),

	-- Spin into a forward kick -- short DashDistance, fast windup (Section 4's weapon-crit-concepts
	-- list; reassigned here from Dagger now that Fist is a real 4th weapon).
	CriticalAttack = table.freeze({
		Windup = 0.18,
		Active = 0.1,
		Recovery = 0.35,
		DashDistance = 4,
		DashDuration = 0.15,
		Damage = 14,
		PostureDamage = 20,
		Knockback = 20,
		Cooldown = 6,
		HitstopDuration = 0.1,
		Unparryable = false,
	}),
})

return Fist
