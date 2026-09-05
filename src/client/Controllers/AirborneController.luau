--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local MovementState = require(Shared.Enums.MovementState)
local MovementConstants = require(Shared.Constants.MovementConstants)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local movementFSM = require(script.Parent.Parent.State.MovementFSM)
local MovementController = require(script.Parent.MovementController)

local player = Players.LocalPlayer

local AirborneController = {}
AirborneController.__index = AirborneController

export type AirborneController = typeof(setmetatable(
	{} :: {
		_connections: { RBXScriptConnection },
		_fallTrackingConnection: RBXScriptConnection?,
		_peakFallVelocity: number,
		_recoveryThread: thread?,
	},
	AirborneController
))

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

function AirborneController.new(): AirborneController
	local self = setmetatable({
		_connections = {},
		_fallTrackingConnection = nil,
		_peakFallVelocity = 0,
		_recoveryThread = nil,
	}, AirborneController)

	return self
end

function AirborneController._cancelRecovery(self: AirborneController)
	if self._recoveryThread then
		task.cancel(self._recoveryThread)
		self._recoveryThread = nil
	end
end

function AirborneController._stopFallTracking(self: AirborneController)
	if self._fallTrackingConnection then
		self._fallTrackingConnection:Disconnect()
		self._fallTrackingConnection = nil
	end
end

-- Sampled every Heartbeat instead of read once on Landed, since the impact can already
-- resolve (and zero out) AssemblyLinearVelocity by the time the Landed state fires.
function AirborneController._startFallTracking(self: AirborneController, rootPart: BasePart)
	self:_stopFallTracking()
	self._peakFallVelocity = 0

	self._fallTrackingConnection = RunService.Heartbeat:Connect(function()
		local verticalVelocity = rootPart.AssemblyLinearVelocity.Y
		if verticalVelocity < self._peakFallVelocity then
			self._peakFallVelocity = verticalVelocity
		end
	end)
end

function AirborneController._onLanded(self: AirborneController)
	self:_stopFallTracking()
	self:_cancelRecovery()

	local fallSpeed = -self._peakFallVelocity
	self._peakFallVelocity = 0

	if fallSpeed < MovementConstants.LightLandingSpeedThreshold then
		MovementController:RefreshMovementState()
		return
	end

	local isHeavyLanding = fallSpeed >= MovementConstants.HeavyLandingSpeedThreshold
	movementFSM:TransitionTo(if isHeavyLanding then MovementState.HeavyLanding else MovementState.LightLanding)

	local recoveryTime = if isHeavyLanding
		then MovementConstants.HeavyLandingRecoveryTime
		else MovementConstants.LightLandingRecoveryTime

	self._recoveryThread = task.delay(recoveryTime, function()
		self._recoveryThread = nil
		MovementController:RefreshMovementState()
	end)
end

function AirborneController._setupCharacter(self: AirborneController, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	disconnectAll(self._connections)
	self:_stopFallTracking()
	self:_cancelRecovery()

	table.insert(
		self._connections,
		humanoid.StateChanged:Connect(function(_oldState: Enum.HumanoidStateType, newState: Enum.HumanoidStateType)
			if newState == Enum.HumanoidStateType.Jumping then
				self:_cancelRecovery()
				movementFSM:TransitionTo(MovementState.Jumping)
			elseif newState == Enum.HumanoidStateType.Freefall then
				self:_cancelRecovery()
				movementFSM:TransitionTo(MovementState.Falling)
				self:_startFallTracking(rootPart)
			elseif newState == Enum.HumanoidStateType.Landed then
				self:_onLanded()
			end
		end)
	)

	table.insert(
		self._connections,
		humanoid.Died:Connect(function()
			disconnectAll(self._connections)
			self:_stopFallTracking()
			self:_cancelRecovery()
		end)
	)
end

function AirborneController.Init(self: AirborneController)
	onCharacterAdded(player, function(character: Model)
		self:_setupCharacter(character)
	end)
end

return AirborneController.new()
