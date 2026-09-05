--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Direction8 = require(ReplicatedStorage.Shared.Enums.Direction8)

local SECTOR_ANGLE = (2 * math.pi) / 8

local ORDER = {
	Direction8.Forward,
	Direction8.FrontRight,
	Direction8.Right,
	Direction8.BackRight,
	Direction8.Back,
	Direction8.BackLeft,
	Direction8.Left,
	Direction8.FrontLeft,
}

-- moveDirection is bucketed into one of 8 45-degree sectors relative to lookVector/rightVector,
-- so callers get a stable direction even as moveDirection drifts slightly frame to frame.
local function classifyDirection8(moveDirection: Vector3, lookVector: Vector3, rightVector: Vector3): Direction8.Direction8
	local forwardDot = moveDirection:Dot(lookVector)
	local rightDot = moveDirection:Dot(rightVector)

	local angle = math.atan2(rightDot, forwardDot)
	local index = math.floor(angle / SECTOR_ANGLE + 0.5) % 8

	return ORDER[index + 1]
end

return classifyDirection8
