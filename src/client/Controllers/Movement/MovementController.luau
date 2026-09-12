--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local MovementState = require(Shared.Enums.MovementState)
local MovementConstants = require(Shared.Constants.MovementConstants)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local movementFSM = require(script.Parent.Parent.Parent.State.MovementFSM)

local requestSprint = ReplicatedStorage.Remotes.RequestSprint :: RemoteEvent

local player = Players.LocalPlayer

local MovementController = {}
MovementController.__index = MovementController

export type MovementController = typeof(setmetatable(
	{} :: {
		_connections: { RBXScriptConnection },
		_isSprintKeyHeld: boolean,
		_lastForwardKeyDownTime: number,
		_updateMovementState: (() -> ())?,
		_tryUpdateMovementState: (() -> ())?,
		_sprintQuery: (() -> boolean)?,
	},
	MovementController
))

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

function MovementController.new(): MovementController
	local self = setmetatable({
		_connections = {},
		_isSprintKeyHeld = false,
		_lastForwardKeyDownTime = -math.huge,
		_updateMovementState = nil,
		_tryUpdateMovementState = nil,
		_sprintQuery = nil,
	}, MovementController)

	return self
end

function MovementController._setupCharacter(self: MovementController, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	disconnectAll(self._connections)

	local function updateMovementState()
		local isMoving = humanoid.MoveDirection.Magnitude > 0
		local isSprinting = isMoving and self._isSprintKeyHeld
		local isQinggongSprintActive = isSprinting and self._sprintQuery ~= nil and (self._sprintQuery :: () -> boolean)()

		local newState = if isQinggongSprintActive
			then MovementState.Sprinting
			elseif isSprinting then MovementState.Running
			elseif isMoving then MovementState.Walking
			else MovementState.Idle

		movementFSM:TransitionTo(newState)
		humanoid.WalkSpeed = if isQinggongSprintActive
			then MovementConstants.SprintSpeed
			elseif isSprinting then MovementConstants.RunSpeed
			else MovementConstants.WalkSpeed
	end
	self._updateMovementState = updateMovementState

	-- While one of these is active, a dedicated controller (Airborne/Dash) owns the FSM;
	-- ground-input handling below must not stomp it until control is explicitly handed back
	-- via RefreshMovementState.
	local function tryUpdateMovementState()
		if MovementConstants.LockedMovementStates[movementFSM:GetState()] then
			return
		end
		updateMovementState()
	end
	self._tryUpdateMovementState = tryUpdateMovementState

	table.insert(
		self._connections,
		humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(tryUpdateMovementState)
	)
	table.insert(
		self._connections,
		humanoid.Died:Connect(function()
			disconnectAll(self._connections)
			self._updateMovementState = nil
			self._tryUpdateMovementState = nil
			movementFSM:TransitionTo(MovementState.Idle)
		end)
	)

	local lastShouldFaceCamera: boolean? = nil

	table.insert(
		self._connections,
		RunService.Heartbeat:Connect(function()
			-- WallRunController's AlignOrientation constraint owns facing while wall-running (the
			-- run direction follows the wall's tangent, not the camera) -- writing rootPart.CFrame
			-- here at the same time would fight it every frame. WallClingController similarly locks
			-- rotation (AutoRotate off) while hanging, snapped to face into the gripped wall.
			local currentWallState = movementFSM:GetState()
			if currentWallState == MovementState.WallRunning or currentWallState == MovementState.WallHanging then
				return
			end

			local isShiftLocked = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
			local isMoving = humanoid.MoveDirection.Magnitude > 0
			local shouldFaceCamera = isShiftLocked or isMoving

			if shouldFaceCamera ~= lastShouldFaceCamera then
				humanoid.AutoRotate = not shouldFaceCamera
				lastShouldFaceCamera = shouldFaceCamera
			end

			if not shouldFaceCamera then
				return
			end

			local camera = Workspace.CurrentCamera
			if not camera then
				return
			end

			local lookVector = camera.CFrame.LookVector
			local flatLookVector = Vector3.new(lookVector.X, 0, lookVector.Z)
			if flatLookVector.Magnitude <= 0 then
				return
			end

			rootPart.CFrame = CFrame.new(rootPart.Position, rootPart.Position + flatLookVector.Unit)
		end)
	)

	tryUpdateMovementState()
end

function MovementController._setSprintKeyHeld(self: MovementController, isHeld: boolean)
	if self._isSprintKeyHeld == isHeld then
		return
	end

	self._isSprintKeyHeld = isHeld
	requestSprint:FireServer(isHeld)

	if self._tryUpdateMovementState then
		self._tryUpdateMovementState()
	end
end

-- Called by AirborneController once a jump/fall/landing sequence ends, to hand FSM
-- control back and immediately resolve the correct grounded state from current input.
function MovementController.RefreshMovementState(self: MovementController)
	if self._updateMovementState then
		self._updateMovementState()
	end
end

-- Read by SprintController to know whether Running's own hold key is still down -- despite the
-- name, this is the double-tap-W run toggle above, not the Qinggong Sprinting technique itself.
function MovementController.IsSprintKeyHeld(self: MovementController): boolean
	return self._isSprintKeyHeld
end

-- SprintController calls this once at Init to hook into updateMovementState's resolution above,
-- without this module requiring SprintController back (avoids a require cycle).
function MovementController.SetSprintQuery(self: MovementController, query: () -> boolean)
	self._sprintQuery = query
end

function MovementController.Init(self: MovementController)
	onCharacterAdded(player, function(character: Model)
		self:_setupCharacter(character)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end

		if input.KeyCode == MovementConstants.SprintForwardKey then
			local now = os.clock()
			-- Second W press landing within the window while sprint isn't already
			-- active is what triggers it; holding W down otherwise just walks.
			if not self._isSprintKeyHeld and now - self._lastForwardKeyDownTime <= MovementConstants.SprintDoubleTapWindow then
				self:_setSprintKeyHeld(true)
			end
			self._lastForwardKeyDownTime = now
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.KeyCode == MovementConstants.SprintForwardKey then
			self:_setSprintKeyHeld(false)
		end
	end)
end

return MovementController.new()
