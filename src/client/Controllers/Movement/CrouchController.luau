--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.Shared
local MovementState = require(Shared.Enums.MovementState)
local MovementConstants = require(Shared.Constants.MovementConstants)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local movementFSM = require(script.Parent.Parent.Parent.State.MovementFSM)
local MovementController = require(script.Parent.MovementController)

local requestCrouch = ReplicatedStorage.Remotes.RequestCrouch :: RemoteEvent

local player = Players.LocalPlayer

local CrouchController = {}
CrouchController.__index = CrouchController

export type CrouchController = typeof(setmetatable(
	{} :: {
		_connections: { RBXScriptConnection },
		_isCrouching: boolean,
	},
	CrouchController
))

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

function CrouchController.new(): CrouchController
	local self = setmetatable({
		_connections = {},
		_isCrouching = false,
	}, CrouchController)

	return self
end

function CrouchController._updateCrouchState(_self: CrouchController, humanoid: Humanoid)
	local isMoving = humanoid.MoveDirection.Magnitude > 0
	movementFSM:TransitionTo(if isMoving then MovementState.CrouchWalking else MovementState.Crouching)
end

function CrouchController._stopCrouch(self: CrouchController, humanoid: Humanoid)
	if not self._isCrouching then
		return
	end

	self._isCrouching = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
	requestCrouch:FireServer(false)
end

function CrouchController._tryToggleCrouch(self: CrouchController, humanoid: Humanoid)
	if self._isCrouching then
		self:_stopCrouch(humanoid)
		MovementController:RefreshMovementState()
		return
	end

	local currentState = movementFSM:GetState()
	if currentState == MovementState.Running or MovementConstants.LockedMovementStates[currentState] then
		return
	end

	self._isCrouching = true
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	humanoid.WalkSpeed = MovementConstants.CrouchSpeed
	requestCrouch:FireServer(true)
	self:_updateCrouchState(humanoid)
end

function CrouchController._setupCharacter(self: CrouchController, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	disconnectAll(self._connections)
	self._isCrouching = false

	table.insert(
		self._connections,
		humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(function()
			if self._isCrouching then
				self:_updateCrouchState(humanoid)
			end
		end)
	)

	table.insert(
		self._connections,
		movementFSM.Changed:Connect(function(newState: string, oldState: string)
			if MovementConstants.CrouchStates[oldState] and not MovementConstants.CrouchStates[newState] then
				self:_stopCrouch(humanoid)
			end
		end)
	)

	table.insert(
		self._connections,
		humanoid.Died:Connect(function()
			disconnectAll(self._connections)
			self._isCrouching = false
		end)
	)
end

function CrouchController.Init(self: CrouchController)
	onCharacterAdded(player, function(character: Model)
		self:_setupCharacter(character)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end

		if input.KeyCode ~= MovementConstants.SlideKey and input.KeyCode ~= MovementConstants.SlideAltKey then
			return
		end

		local character = player.Character
		if not character then
			return
		end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return
		end

		self:_tryToggleCrouch(humanoid)
	end)
end

return CrouchController.new()
