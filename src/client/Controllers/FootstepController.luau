--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage.Shared
local FootstepConstants = require(Shared.Constants.FootstepConstants)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local sampleSurfaceColor = require(Shared.Utils.SampleSurfaceColor)
local movementFSM = require(script.Parent.Parent.State.MovementFSM)
local FootstepSounds = require(script.Parent.Parent.Audio.FootstepSounds)
local MovementVFXTemplates = require(script.Parent.Parent.VFX.MovementVFXTemplates)
local SprintController = require(script.Parent.SprintController)

local notifyFootstep = ReplicatedStorage.Remotes.NotifyFootstep :: UnreliableRemoteEvent
local playFootstepSFX = ReplicatedStorage.Remotes.PlayFootstepSFX :: UnreliableRemoteEvent

local player = Players.LocalPlayer

local DOWN = Vector3.new(0, -1, 0)
local FOOTSTEP_VFX_SIDE_OFFSET = 0.5
local FOOTSTEP_VFX_DOWN_OFFSET = 3
local FOOTSTEP_VFX_EMIT_COUNT = 5
local FOOTSTEP_VFX_CLEANUP_TIME = 1

local FootstepController = {}
FootstepController.__index = FootstepController

export type FootstepController = typeof(setmetatable(
	{} :: {
		_connections: { RBXScriptConnection },
		_rayParams: RaycastParams?,
		_lastStepTime: number,
		_currentLeg: number,
		_remoteLegs: { [Player]: number },
	},
	FootstepController
))

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function silenceDefaultFootstepSound(rootPart: BasePart)
	task.spawn(function()
		local defaultSound = rootPart:WaitForChild("Running", 3)
		if defaultSound and defaultSound:IsA("Sound") then
			(defaultSound :: Sound).Volume = 0
		end
	end)
end

function FootstepController.new(): FootstepController
	local self = setmetatable({
		_connections = {},
		_rayParams = nil,
		_lastStepTime = 0,
		_currentLeg = 1,
		_remoteLegs = {},
	}, FootstepController)

	return self
end

-- volumeMultiplier defaults to full volume -- only the local player's own steps (see
-- _processFootstep) fade this with the Qinggong Sprinting technique's charge; a remote player's
-- footsteps have no visibility into that player's own sprint state, so they're left untouched.
function FootstepController._playFootstepSound(self: FootstepController, rootPart: BasePart, materialName: string, volumeMultiplier: number?)
	local sound = Instance.new("Sound")
	sound.SoundId = FootstepSounds.GetRandomSound(materialName)
	sound.PlaybackSpeed = 1 + ((math.random() * 2 - 1) * FootstepConstants.PitchVariance)
	sound.Volume = FootstepConstants.BaseVolume * (volumeMultiplier or 1)
	sound.Parent = rootPart
	sound:Play()

	Debris:AddItem(sound, FootstepConstants.SoundCleanupTime)
end

function FootstepController._spawnFootstepVFX(_self: FootstepController, rootPart: BasePart, leg: number, tintColor: Color3?)
	local template = MovementVFXTemplates.Footsteps
	if not template then
		return
	end

	local sideOffset = if leg == 1 then -FOOTSTEP_VFX_SIDE_OFFSET else FOOTSTEP_VFX_SIDE_OFFSET
	local piece = template:Clone()
	piece.CFrame = rootPart.CFrame * CFrame.new(sideOffset, -FOOTSTEP_VFX_DOWN_OFFSET, 0)
	piece.Parent = workspace

	for _, descendant in ipairs(piece:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			if tintColor then
				descendant.Color = ColorSequence.new(tintColor)
			end
			descendant:Emit(FOOTSTEP_VFX_EMIT_COUNT)
		end
	end

	Debris:AddItem(piece, FOOTSTEP_VFX_CLEANUP_TIME)
end

function FootstepController._processFootstep(self: FootstepController, humanoid: Humanoid, rootPart: BasePart)
	local interval = FootstepConstants.Intervals[movementFSM:GetState()]
	if not interval then
		return
	end

	if humanoid.MoveDirection.Magnitude <= FootstepConstants.MoveDirectionDeadzone then
		return
	end

	local now = os.clock()
	if now - self._lastStepTime < interval then
		return
	end
	self._lastStepTime = now

	local rayResult = workspace:Raycast(rootPart.Position, DOWN * FootstepConstants.GroundCheckDistance, self._rayParams)
	local materialName = if rayResult then rayResult.Material.Name else "Plastic"

	-- Crossfades with the Sprint wind SFX ramping in the opposite direction (see
	-- MovementSoundController) instead of playing at full volume until SprintCharging's interval
	-- above stops firing at all once Sprinting is reached.
	local volumeMultiplier = 1 - SprintController:GetSprintTarget()
	self:_playFootstepSound(rootPart, materialName, volumeMultiplier)
	self:_spawnFootstepVFX(rootPart, self._currentLeg, sampleSurfaceColor(rayResult))
	self._currentLeg = if self._currentLeg == 1 then 2 else 1

	notifyFootstep:FireServer(materialName)
end

function FootstepController._onRemoteFootstep(self: FootstepController, steppingPlayer: Player, materialName: unknown)
	if steppingPlayer == player or typeof(materialName) ~= "string" then
		return
	end

	local character = steppingPlayer.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then
		return
	end

	self:_playFootstepSound(rootPart, materialName)

	local leg = self._remoteLegs[steppingPlayer] or 1
	self:_spawnFootstepVFX(rootPart, leg, nil)
	self._remoteLegs[steppingPlayer] = if leg == 1 then 2 else 1
end

function FootstepController._setupCharacter(self: FootstepController, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	disconnectAll(self._connections)
	self._lastStepTime = os.clock()

	silenceDefaultFootstepSound(rootPart)

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }
	self._rayParams = rayParams

	table.insert(
		self._connections,
		RunService.Heartbeat:Connect(function()
			self:_processFootstep(humanoid, rootPart)
		end)
	)

	table.insert(
		self._connections,
		humanoid.Died:Connect(function()
			disconnectAll(self._connections)
		end)
	)
end

function FootstepController.Init(self: FootstepController)
	onCharacterAdded(player, function(character: Model)
		self:_setupCharacter(character)
	end)

	playFootstepSFX.OnClientEvent:Connect(function(steppingPlayer: Player, materialName: unknown)
		self:_onRemoteFootstep(steppingPlayer, materialName)
	end)

	Players.PlayerRemoving:Connect(function(steppingPlayer: Player)
		self._remoteLegs[steppingPlayer] = nil
	end)
end

return FootstepController.new()
