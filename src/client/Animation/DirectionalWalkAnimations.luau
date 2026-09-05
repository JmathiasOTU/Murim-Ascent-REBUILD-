--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Direction8 = require(ReplicatedStorage.Shared.Enums.Direction8)
local basicMovementFolder = require(script.Parent.BasicMovementAnimationFolder)

local walkingFolder = basicMovementFolder:WaitForChild("Walking")

local DirectionalWalkAnimations: { [string]: Animation } = table.freeze({
	[Direction8.Forward] = walkingFolder:WaitForChild("WalkForward") :: Animation,
	[Direction8.FrontRight] = walkingFolder:WaitForChild("WalkFrontRight") :: Animation,
	[Direction8.Right] = walkingFolder:WaitForChild("WalkRight") :: Animation,
	[Direction8.BackRight] = walkingFolder:WaitForChild("WalkBackRight") :: Animation,
	[Direction8.Back] = walkingFolder:WaitForChild("WalkBack") :: Animation,
	[Direction8.BackLeft] = walkingFolder:WaitForChild("WalkBackLeft") :: Animation,
	[Direction8.Left] = walkingFolder:WaitForChild("WalkLeft") :: Animation,
	[Direction8.FrontLeft] = walkingFolder:WaitForChild("WalkFrontLeft") :: Animation,
})

return DirectionalWalkAnimations
