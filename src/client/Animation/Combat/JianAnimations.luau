--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Requires Animation instances authored in Studio under this path, same content-pipeline
-- dependency every other Animation* module in this project already has (see
-- BasicMovementAnimationFolder/QinggongAnimationFolder) -- these don't exist yet for Combat.
local jianFolder = ReplicatedStorage
	:WaitForChild("Assets")
	:WaitForChild("Animations")
	:WaitForChild("Combat")
	:WaitForChild("Jian")

local JianAnimations: { [string]: Animation } = table.freeze({
	M1_1 = jianFolder:WaitForChild("M1_1") :: Animation,
	M1_2 = jianFolder:WaitForChild("M1_2") :: Animation,
	M1_3 = jianFolder:WaitForChild("M1_3") :: Animation,
	M1_4 = jianFolder:WaitForChild("M1_4") :: Animation,
})

return JianAnimations
