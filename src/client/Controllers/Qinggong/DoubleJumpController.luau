--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.Shared
local MovementState = require(Shared.Enums.MovementState)
local MovementConstants = require(Shared.Constants.MovementConstants)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local hasEnoughQinggong = require(Shared.Utils.HasEnoughQinggong)
local movementFSM = require(script.Parent.Parent.Parent.State.MovementFSM)
local MovementController = require(script.Parent.Parent.Movement.MovementController)
local WallRunController = require(script.Parent.WallRunController)

local requestDoubleJump = ReplicatedStorage.Remotes.RequestDoubleJump :: RemoteEvent

local player = Players.LocalPlayer

local DoubleJumpController = {}
DoubleJumpController.__index = DoubleJumpController

export type DoubleJumpController = typeof(setmetatable(
	{} :: {
		_connections: { RBXScriptConnection },
		_hasDoubleJumped: boolean,
		_jumpEndThread: thread?,
	},
	DoubleJumpController
))

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

function DoubleJumpController.new(): DoubleJumpController
	local self = setmetatable({
		_connections = {},
		_hasDoubleJumped = false,
		_jumpEndThread = nil,
	}, DoubleJumpController)

	return self
end

function DoubleJumpController._cancelJumpEndThread(self: DoubleJumpController)
	if self._jumpEndThread then
		task.cancel(self._jumpEndThread)
		self._jumpEndThread = nil
	end
end

-- A fixed vertical pop, not a held boost -- only Y is overwritten, so horizontal momentum (from
-- walking/running/an air dash) carries over untouched.
function DoubleJumpController._applyImpulse(self: DoubleJumpController, rootPart: BasePart)
	local currentVelocity = rootPart.AssemblyLinearVelocity
	rootPart.AssemblyLinearVelocity = Vector3.new(currentVelocity.X, MovementConstants.DoubleJumpVelocity, currentVelocity.Z)
end

function DoubleJumpController._tryDoubleJump(self: DoubleJumpController, humanoid: Humanoid, rootPart: BasePart)
	local currentState = movementFSM:GetState()
	if currentState ~= MovementState.Jumping and currentState ~= MovementState.Falling then
		return
	end

	if self._hasDoubleJumped then
		return
	end

	if not hasEnoughQinggong(MovementConstants.QinggongCostDoubleJump) then
		return
	end

	-- Same Space press can also trigger a wall run (see WallRunController.Init) -- prefer that over
	-- spending the double jump charge whenever the geometry actually supports one, rather than
	-- relying solely on which controller's InputBegan connection happens to run first.
	if WallRunController:CanStartWallRun(humanoid, rootPart) then
		return
	end

	self._hasDoubleJumped = true

	movementFSM:TransitionTo(MovementState.DoubleJumping)
	requestDoubleJump:FireServer()
	self:_applyImpulse(rootPart)

	self:_cancelJumpEndThread()
	self._jumpEndThread = task.delay(MovementConstants.DoubleJumpDuration, function()
		self._jumpEndThread = nil
		if movementFSM:GetState() ~= MovementState.DoubleJumping then
			return
		end

		-- The underlying Humanoid state was never changed (only the FSM was, to play the pop
		-- animation over it), so it still reads Jumping/Freefall from the arc this interrupted --
		-- hand back to whichever one it actually is instead of resolving through ground movement,
		-- which would otherwise incorrectly snap the FSM to Walking/Idle mid-air.
		local humanoidState = humanoid:GetState()
		if humanoidState == Enum.HumanoidStateType.Jumping then
			movementFSM:TransitionTo(MovementState.Jumping)
		elseif humanoidState == Enum.HumanoidStateType.Freefall then
			movementFSM:TransitionTo(MovementState.Falling)
		else
			MovementController:RefreshMovementState()
		end
	end)
end

function DoubleJumpController._setupCharacter(self: DoubleJumpController, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	disconnectAll(self._connections)
	self:_cancelJumpEndThread()
	self._hasDoubleJumped = false

	table.insert(
		self._connections,
		humanoid.StateChanged:Connect(function(_oldState: Enum.HumanoidStateType, newState: Enum.HumanoidStateType)
			if newState == Enum.HumanoidStateType.Landed then
				self._hasDoubleJumped = false
			end
		end)
	)

	table.insert(
		self._connections,
		humanoid.Died:Connect(function()
			disconnectAll(self._connections)
			self:_cancelJumpEndThread()
			self._hasDoubleJumped = false
		end)
	)
end

function DoubleJumpController.Init(self: DoubleJumpController)
	onCharacterAdded(player, function(character: Model)
		self:_setupCharacter(character)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end

		if input.KeyCode ~= Enum.KeyCode.Space then
			return
		end

		local character = player.Character
		if not character then
			return
		end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local rootPart = humanoid and (humanoid :: Humanoid).RootPart
		if not humanoid or not rootPart then
			return
		end

		self:_tryDoubleJump(humanoid, rootPart)
	end)
end

return DoubleJumpController.new()
