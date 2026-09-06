--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DashCategory = require(ReplicatedStorage.Shared.Enums.DashCategory)
local classifyDashDirection = require(ReplicatedStorage.Shared.Utils.ClassifyDashDirection)

local function classifyDashCategory(moveDirection: Vector3, lookVector: Vector3, rightVector: Vector3): string
	local direction = classifyDashDirection(moveDirection, lookVector, rightVector)
	return if direction == "Left" or direction == "Right" then DashCategory.Side else DashCategory.Forward
end

return classifyDashCategory
