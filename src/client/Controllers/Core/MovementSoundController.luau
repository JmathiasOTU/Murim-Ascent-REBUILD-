--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MovementState = require(ReplicatedStorage.Shared.Enums.MovementState)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)
local onCharacterAdded = require(ReplicatedStorage.Shared.Utils.OnCharacterAdded)
local movementFSM = require(script.Parent.Parent.Parent.State.MovementFSM)
local MovementSounds = require(script.Parent.Parent.Parent.Audio.MovementSounds)
local QinggongSounds = require(script.Parent.Parent.Parent.Audio.QinggongSounds)
local SprintController = require(script.Parent.Parent.Movement.SprintController)

local player = Players.LocalPlayer

local MovementSoundController = {}
MovementSoundController.__index = MovementSoundController

export type MovementSoundController = typeof(setmetatable(
	{} :: {
		_connections: { RBXScriptConnection },
		_sounds: { [string]: Sound },
		_startPositions: { [string]: number },
		_sprintFullVolume: number,
		_sprintCurrentVolume: number,
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
		_sprintFullVolume = 1,
		_sprintCurrentVolume = 0,
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
			-- Defensive: WallRunning's clip runs for as long as the run lasts (a variable, potentially
			-- long duration), stopped explicitly on exit below rather than left to finish on its own.
			-- WallHanging's grip-loss slide is the same shape -- runs for as long as the hang lasts.
			if state == MovementState.WallRunning or state == MovementState.WallHanging or state == MovementState.Sprinting then
				clone.Looped = true
			end
			if state == MovementState.Sprinting then
				self._sprintFullVolume = template.Volume
			end
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
			-- Sliding's clip is long enough to outlast a slide that ends early, and WallRunning's and
			-- WallHanging's are true loops (Looped forced true above) -- these need cutting off on exit
			-- instead of letting them ring on (or loop forever) after the state's gone. Every other
			-- movement sound (jump, land, dash, the other Qinggong actions) is a short one-shot that
			-- should just finish naturally, even if its state has already moved on by then.
			if oldState == MovementState.Sliding or oldState == MovementState.WallRunning or oldState == MovementState.WallHanging then
				local oldSound = self._sounds[oldState]
				if oldSound then
					oldSound:Stop()
				end
			end

			-- Sprinting's is managed entirely by the dedicated volume-ramp loop below, which
			-- decides for itself when to start/stop playing.
			local newSound = self._sounds[newState]
			if newSound and newState ~= MovementState.Sprinting then
				newSound.TimePosition = self._startPositions[newState]
				newSound:Play()
			end
		end)
	)

	-- Continuously tracks the Qinggong Sprinting technique's ramp (see SprintController) so the
	-- wind sound fades in with the charge and fades back out when it ends, instead of just
	-- snapping on/off like every other movement sound above.
	table.insert(
		self._connections,
		RunService.Heartbeat:Connect(function(dt: number)
			local sprintSound = self._sounds[MovementState.Sprinting]
			if not sprintSound then
				return
			end

			local target = SprintController:GetSprintTarget()

			if target <= 0 then
				if not sprintSound.Playing then
					return
				end

				local fadeAlpha = 1 - math.exp(-MovementConstants.SprintSfxFadeOutSpeed * dt)
				self._sprintCurrentVolume += (0 - self._sprintCurrentVolume) * fadeAlpha
				sprintSound.Volume = self._sprintCurrentVolume

				-- Close enough to silent that a hard Stop() here is inaudible -- waiting for an
				-- exact 0 would let the exponential ease drag on forever without ever reaching it.
				if self._sprintCurrentVolume <= 0.01 then
					sprintSound:Stop()
					self._sprintCurrentVolume = 0
				end
				return
			end

			if not sprintSound.Playing then
				sprintSound.TimePosition = self._startPositions[MovementState.Sprinting]
				sprintSound:Play()
			end

			-- The ramp-up itself is already smoothed over SprintRampDuration by SprintController, so
			-- volume can track the target directly here -- only the fade-OUT above needs its own ease,
			-- since "target" drops to 0 in a single tick the instant the technique ends.
			local volumeAlpha = MovementConstants.SprintSfxStartVolumeFraction
				+ (1 - MovementConstants.SprintSfxStartVolumeFraction) * target
			self._sprintCurrentVolume = self._sprintFullVolume * volumeAlpha
			sprintSound.Volume = self._sprintCurrentVolume
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
