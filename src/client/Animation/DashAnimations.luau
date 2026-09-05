--!strict

local basicMovementFolder = require(script.Parent.BasicMovementAnimationFolder)

local dashFolder = basicMovementFolder:WaitForChild("Dash")

local DashAnimations: { [string]: Animation } = table.freeze({
	Front = dashFolder:WaitForChild("DashFront") :: Animation,
	Back = dashFolder:WaitForChild("DashBack") :: Animation,
	Left = dashFolder:WaitForChild("DashLeft") :: Animation,
	Right = dashFolder:WaitForChild("DashRight") :: Animation,
})

return DashAnimations
