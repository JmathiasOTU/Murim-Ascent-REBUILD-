--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DashCategory = require(ReplicatedStorage.Shared.Enums.DashCategory)

export type DashCooldownState = {
	lastDashTime: number,
	lastDashCooldownResetAt: number, -- -math.huge means eligible
}

local function newDashCooldownStates(): { [string]: DashCooldownState }
	local states = {}
	for _, category in pairs(DashCategory) do
		states[category] = {
			lastDashTime = -math.huge,
			lastDashCooldownResetAt = -math.huge,
		}
	end
	return states
end

return newDashCooldownStates
