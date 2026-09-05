--!strict

local function getHumanoidAndRoot(character: Model?): (Humanoid?, BasePart?)
	if not character then
		return nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = humanoid and humanoid.RootPart
	return humanoid, rootPart
end

return getHumanoidAndRoot
