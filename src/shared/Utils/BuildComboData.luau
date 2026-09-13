--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponTypes = require(ReplicatedStorage.Shared.Constants.Weapons.WeaponTypes)

-- Every field optional -- a step only needs to list what it diverges on, everything else falls
-- through to the weapon's shared base step.
export type ComboStepOverride = {
	Damage: number?,
	PostureDamage: number?,
	Knockback: number?,
	Hitstun: number?,
	Windup: number?,
	Active: number?,
	Recovery: number?,
	HitstopDuration: number?,
	Unparryable: boolean?,
}

-- Steps with no override share the exact same frozen baseStep reference (no clone needed, it's
-- already immutable); only a diverging step (e.g. the M1x4 knockback finisher) pays for a clone.
local function buildComboData(
	comboSteps: { string },
	baseStep: WeaponTypes.ComboStepData,
	overrides: { [string]: ComboStepOverride }?
): { [string]: WeaponTypes.ComboStepData }
	local comboData: { [string]: WeaponTypes.ComboStepData } = {}

	for _, stepId in ipairs(comboSteps) do
		local override = overrides and overrides[stepId]
		if not override then
			comboData[stepId] = baseStep
			continue
		end

		local merged = table.clone(baseStep) :: any
		for key, value in pairs(override) do
			merged[key] = value
		end
		comboData[stepId] = table.freeze(merged)
	end

	return table.freeze(comboData)
end

return buildComboData
