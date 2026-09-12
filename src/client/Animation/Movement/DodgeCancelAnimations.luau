--!strict

local basicMovementFolder = require(script.Parent.BasicMovementAnimationFolder)

local dodgeCancelFolder = basicMovementFolder:WaitForChild("DodgeCancel")

local DodgeCancelAnimations: { [string]: Animation } = table.freeze({
	Left = dodgeCancelFolder:WaitForChild("DodgeCancelLeft") :: Animation,
	Right = dodgeCancelFolder:WaitForChild("DodgeCancelRight") :: Animation,
})

return DodgeCancelAnimations
