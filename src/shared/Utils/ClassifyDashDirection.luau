--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)

-- no input defaults to Back
local function classifyDashDirection(moveDirection: Vector3, lookVector: Vector3, rightVector: Vector3): string
	if moveDirection.Magnitude <= MovementConstants.DashSteerDeadzone then
		return "Back"
	end

	local forwardDot = moveDirection:Dot(lookVector)
	local rightDot = moveDirection:Dot(rightVector)

	if math.abs(forwardDot) > math.abs(rightDot) then
		return if forwardDot > 0 then "Front" else "Back"
	end
	return if rightDot > 0 then "Right" else "Left"
end

return classifyDashDirection
