--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Requires Animation instances authored in Studio under this path, same content-pipeline
-- dependency every other Animation* module in this project already has (see JianAnimations).
local fistFolder = ReplicatedStorage
	:WaitForChild("Assets")
	:WaitForChild("Animations")
	:WaitForChild("Combat")
	:WaitForChild("Fist")

local FistAnimations: { [string]: Animation } = table.freeze({
	M1_1 = fistFolder:WaitForChild("M1_1") :: Animation,
	M1_2 = fistFolder:WaitForChild("M1_2") :: Animation,
	M1_3 = fistFolder:WaitForChild("M1_3") :: Animation,
	M1_4 = fistFolder:WaitForChild("M1_4") :: Animation,
})

return FistAnimations
