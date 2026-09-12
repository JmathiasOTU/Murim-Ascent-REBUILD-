--!strict

-- Thin aggregator, not the data itself -- the weapon roster is expected to grow well past a
-- handful of entries, so each weapon lives in its own file under Weapons/ and this just requires
-- and indexes them (Combat_Framework_Design_Doc Section 7). To add a weapon: new file under
-- Weapons/, then one line below.
local WeaponTypes = require(script.Parent.Weapons.WeaponTypes)

export type ComboStepData = WeaponTypes.ComboStepData
export type CriticalAttackData = WeaponTypes.CriticalAttackData
export type WeaponDefinition = WeaponTypes.WeaponDefinition

local Jian = require(script.Parent.Weapons.Jian)
local Fist = require(script.Parent.Weapons.Fist)

local WeaponDefinitions: { [string]: WeaponDefinition } = table.freeze({
	Jian = Jian,
	Fist = Fist,
})
	
return WeaponDefinitions
