--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementState = require(ReplicatedStorage.Shared.Enums.MovementState)
local qinggongSoundFolder = require(script.Parent.QinggongSoundFolder)

local QinggongSounds: { [string]: Sound } = table.freeze({
	[MovementState.AirDashing] = qinggongSoundFolder:WaitForChild("AirDash") :: Sound,
	[MovementState.DoubleJumping] = qinggongSoundFolder:WaitForChild("DoubleJump") :: Sound,
	[MovementState.LedgeJumping] = qinggongSoundFolder:WaitForChild("LedgeJump") :: Sound,
})

return QinggongSounds
