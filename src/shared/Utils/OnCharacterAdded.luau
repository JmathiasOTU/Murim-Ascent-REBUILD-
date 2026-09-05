--!strict

local function onCharacterAdded(player: Player, callback: (character: Model) -> ())
	if player.Character then
		callback(player.Character)
	end
	player.CharacterAdded:Connect(callback)
end

return onCharacterAdded
