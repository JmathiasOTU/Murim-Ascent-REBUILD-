--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementState = require(ReplicatedStorage.Shared.Enums.MovementState)
local wallClimbFolder = require(script.Parent.QinggongWallClimbAnimationFolder)

-- State-keyed, unlike WallRunAnimations -- WallHanging/WallBoost/WallClingDoubleJump each have one
-- fixed pose, with no left/right side variant to pick at play-time. WallLatch is an extra one-shot
-- layered on top of WallHanging's loop on entry, so it isn't itself a MovementState.
local WallClimbAnimations: { [string]: Animation } = table.freeze({
	[MovementState.WallHanging] = wallClimbFolder:WaitForChild("WallHanging") :: Animation,
	[MovementState.WallBoost] = wallClimbFolder:WaitForChild("WallBoost") :: Animation,
	[MovementState.WallClingDoubleJump] = wallClimbFolder:WaitForChild("WallClingDoubleJump") :: Animation,
	WallLatch = wallClimbFolder:WaitForChild("WallLatch") :: Animation,
})

return WallClimbAnimations
