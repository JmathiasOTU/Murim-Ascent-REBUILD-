--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementState = require(ReplicatedStorage.Shared.Enums.MovementState)
local basicMovementFolder = require(script.Parent.BasicMovementAnimationFolder)

local MovementAnimations: { [string]: Animation } = table.freeze({
	[MovementState.Idle] = basicMovementFolder:WaitForChild("Idle") :: Animation,
	[MovementState.Running] = basicMovementFolder:WaitForChild("Running") :: Animation,
	[MovementState.Jumping] = basicMovementFolder:WaitForChild("Jumping") :: Animation,
	[MovementState.Falling] = basicMovementFolder:WaitForChild("Falling") :: Animation,
	[MovementState.LightLanding] = basicMovementFolder:WaitForChild("LightLanding") :: Animation,
	[MovementState.HeavyLanding] = basicMovementFolder:WaitForChild("HeavyLanding") :: Animation,
	[MovementState.Sliding] = basicMovementFolder:WaitForChild("Sliding") :: Animation,
	[MovementState.Crouching] = basicMovementFolder:WaitForChild("Crouching") :: Animation,
	[MovementState.CrouchWalking] = basicMovementFolder:WaitForChild("CrouchWalking") :: Animation,
})

return MovementAnimations
