--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DashCategory = require(ReplicatedStorage.Shared.Enums.DashCategory)
local MovementState = require(ReplicatedStorage.Shared.Enums.MovementState)

local DashCategoryMovementStates = table.freeze({
	[DashCategory.Forward] = MovementState.DashingForward,
	[DashCategory.Side] = MovementState.DashingSide,
})

return DashCategoryMovementStates
