--!strict

local wallRunFolder = require(script.Parent.QinggongWallRunAnimationFolder)

-- Directional, not state-keyed: WallRunning/WallLeaping each pick Left or Right at play-time off
-- which side the wall is actually on (see AnimationController), so these live in their own flat
-- side-keyed table instead of QinggongAnimations' state -> Animation map.
local WallRunAnimations: { [string]: Animation } = table.freeze({
	WallRunLeft = wallRunFolder:WaitForChild("WallRunLeft") :: Animation,
	WallRunRight = wallRunFolder:WaitForChild("WallRunRight") :: Animation,
	WallLeapLeft = wallRunFolder:WaitForChild("WallLeapLeft") :: Animation,
	WallLeapRight = wallRunFolder:WaitForChild("WallLeapRight") :: Animation,
})

return WallRunAnimations
