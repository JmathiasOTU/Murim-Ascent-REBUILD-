--!strict

-- Thin aggregator, same pattern as WeaponDefinitions.luau -- one animation-table file per weapon
-- under this folder, indexed here by the same WeaponId keys WeaponDefinitions uses. To add a
-- weapon's animations: new file under Animation/Combat/, then one line below.
local JianAnimations = require(script.Parent.JianAnimations)
local FistAnimations = require(script.Parent.FistAnimations)

local CombatAnimations: { [string]: { [string]: Animation } } = table.freeze({
	Jian = JianAnimations,
	Fist = FistAnimations,
})

return CombatAnimations
