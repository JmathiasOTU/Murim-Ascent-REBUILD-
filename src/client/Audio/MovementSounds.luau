--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementState = require(ReplicatedStorage.Shared.Enums.MovementState)
local basicMovementSoundFolder = require(script.Parent.BasicMovementSoundFolder)

local MovementSounds: { [string]: Sound } = table.freeze({
	[MovementState.Jumping] = basicMovementSoundFolder:WaitForChild("Jump") :: Sound,
	[MovementState.LightLanding] = basicMovementSoundFolder:WaitForChild("Light Landing") :: Sound,
	[MovementState.HeavyLanding] = basicMovementSoundFolder:WaitForChild("Heavy Landing") :: Sound,
	[MovementState.DashingForward] = basicMovementSoundFolder:WaitForChild("NormalDash") :: Sound,
	[MovementState.DashingSide] = basicMovementSoundFolder:WaitForChild("NormalDash") :: Sound,
	[MovementState.Sliding] = basicMovementSoundFolder:WaitForChild("Slide") :: Sound,
	[MovementState.DodgeCancelling] = basicMovementSoundFolder:WaitForChild("DodgeCancel") :: Sound,
})

return MovementSounds
