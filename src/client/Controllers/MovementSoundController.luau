--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementState = require(ReplicatedStorage.Shared.Enums.MovementState)
local onCharacterAdded = require(ReplicatedStorage.Shared.Utils.OnCharacterAdded)
local movementFSM = require(script.Parent.Parent.State.MovementFSM)
local MovementSounds = require(script.Parent.Parent.Audio.MovementSounds)
local QinggongSounds = require(script.Parent.Parent.Audio.QinggongSounds)

local player = Players.LocalPlayer

local MovementSoundController = {}
MovementSoundController.__index = MovementSoundController

export type MovementSoundController = typeof(setmetatable(
	{} :: {
		_connections: { RBXScriptConnection },
		_sounds: { [string]: Sound },
		_startPositions: { [string]: number },
	},
	MovementSoundController
))

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

function MovementSoundController.new(): MovementSoundController
	local self = setmetatable({
		_connections = {},
		_sounds = {},
		_startPositions = {},
	}, MovementSoundController)

	return self
end

function MovementSoundController._setupCharacter(self: MovementSoundController, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	disconnectAll(self._connections)

	for _, sound in pairs(self._sounds) do
		sound:Destroy()
	end

	local sounds: { [string]: Sound } = {}
	local startPositions: { [string]: number } = {}
	for _, soundGroup in ipairs({ MovementSounds, QinggongSounds }) do
		for state, template in pairs(soundGroup) do
			local clone = template:Clone()
			clone.Parent = rootPart
			sounds[state] = clone
			startPositions[state] = template.TimePosition
		end
	end
	self._sounds = sounds
	self._startPositions = startPositions

	table.insert(
		self._connections,
		movementFSM.Changed:Connect(function(newState: string, oldState: string)
			-- Sliding's clip is long enough to outlast a slide that ends early -- cut it off on exit
			-- instead of letting it ring on well after the state's gone. Every other movement sound
			-- (jump, land, dash, the Qinggong actions) is a short one-shot that should just finish
			-- naturally, even if its state has already moved on by then.
			if oldState == MovementState.Sliding then
				local oldSound = self._sounds[oldState]
				if oldSound then
					oldSound:Stop()
				end
			end

			local newSound = self._sounds[newState]
			if newSound then
				newSound.TimePosition = self._startPositions[newState]
				newSound:Play()
			end
		end)
	)

	table.insert(
		self._connections,
		humanoid.Died:Connect(function()
			disconnectAll(self._connections)
		end)
	)
end

function MovementSoundController.Init(self: MovementSoundController)
	onCharacterAdded(player, function(character: Model)
		self:_setupCharacter(character)
	end)
end

return MovementSoundController.new()
