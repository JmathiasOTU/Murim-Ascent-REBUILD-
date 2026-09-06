--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementState = require(ReplicatedStorage.Shared.Enums.MovementState)
local qinggongFolder = require(script.Parent.QinggongAnimationFolder)

local QinggongAnimations: { [string]: Animation } = table.freeze({
	[MovementState.AirDashing] = qinggongFolder:WaitForChild("AirDashing") :: Animation,
	[MovementState.DoubleJumping] = qinggongFolder:WaitForChild("DoubleJump") :: Animation,
	[MovementState.LedgeJumping] = qinggongFolder:WaitForChild("LedgeJump") :: Animation,
})

return QinggongAnimations
