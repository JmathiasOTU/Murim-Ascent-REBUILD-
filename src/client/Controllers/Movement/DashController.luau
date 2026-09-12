--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local MovementState = require(Shared.Enums.MovementState)
local DashCategory = require(Shared.Enums.DashCategory)
local MovementConstants = require(Shared.Constants.MovementConstants)
local classifyDashCategory = require(Shared.Utils.ClassifyDashCategory)
local newDashCooldownStates = require(Shared.Utils.NewDashCooldownStates)
local DashCategoryMovementStates = require(Shared.Utils.DashCategoryMovementStates)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local regenCharges = require(Shared.Utils.RegenCharges)
local movementFSM = require(script.Parent.Parent.Parent.State.MovementFSM)
local MovementController = require(script.Parent.MovementController)

local requestDash = ReplicatedStorage.Remotes.RequestDash :: RemoteEvent
local requestRollCancel = ReplicatedStorage.Remotes.RequestRollCancel :: RemoteEvent

local player = Players.LocalPlayer

-- Y-force left at 0 so gravity (and a jump-cancel's impulse) still applies; only X/Z are locked
-- to the steered dash velocity.
local GROUND_LOCK_FORCE = Vector3.new(MovementConstants.MaxPhysicsForce, 0, MovementConstants.MaxPhysicsForce)

local DashController = {}
DashController.__index = DashController

export type DashController = typeof(setmetatable(
	{} :: {
		_connections: { RBXScriptConnection },
		_attachment: Attachment?,
		_velocity: LinearVelocity?,
		_steerConnection: RBXScriptConnection?,
		_dashEndThread: thread?,
		_dodgeCancelEndThread: thread?,
		_dashCooldowns: { [string]: newDashCooldownStates.DashCooldownState },
		_lastDashCategory: string,
		_dashStartTime: number,
		_rollCancelCharges: number,
		_rollCancelChargeRegenStart: number,
	},
	DashController
))

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

function DashController.new(): DashController
	local self = setmetatable({
		_connections = {},
		_attachment = nil,
		_velocity = nil,
		_steerConnection = nil,
		_dashEndThread = nil,
		_dodgeCancelEndThread = nil,
		_dashCooldowns = newDashCooldownStates(),
		_lastDashCategory = DashCategory.Forward,
		_dashStartTime = -math.huge,
		_rollCancelCharges = MovementConstants.RollCancelMaxCharges,
		_rollCancelChargeRegenStart = os.clock(),
	}, DashController)

	return self
end

function DashController._cancelDashEndThread(self: DashController)
	if self._dashEndThread then
		task.cancel(self._dashEndThread)
		self._dashEndThread = nil
	end
end

function DashController._cancelDodgeCancelEndThread(self: DashController)
	if self._dodgeCancelEndThread then
		task.cancel(self._dodgeCancelEndThread)
		self._dodgeCancelEndThread = nil
	end
end

-- Reacts to Dashing ending for ANY reason -- a natural timeout (via RefreshMovementState below) or
-- an early interruption like a jump-cancel taking the FSM straight to Jumping -- so the velocity
-- constraint never keeps steering the character after some other controller has taken over.
function DashController._stopPhysics(self: DashController, humanoid: Humanoid, rootPart: BasePart)
	self:_cancelDashEndThread()

	if self._steerConnection then
		self._steerConnection:Disconnect()
		self._steerConnection = nil
	end
	if self._velocity then
		self._velocity.Enabled = false
	end

	-- Skipped while still running -- residual speed should carry into that pace, not get cut. Note
	-- this is only ever a starting point, not a guarantee of the resultant speed: Humanoid's own
	-- ground controller keeps independently driving velocity off WalkSpeed/MoveDirection every
	-- physics step after this, so the two transiently combine for a moment rather than this value
	-- simply sticking -- the server's dashSpeedExemptUntil grace is what actually absorbs that,
	-- not precision here.
	if humanoid.WalkSpeed <= MovementConstants.WalkSpeed then
		local currentVelocity = rootPart.AssemblyLinearVelocity
		rootPart.AssemblyLinearVelocity = Vector3.new(
			currentVelocity.X * (1 - MovementConstants.DashBrakeForce),
			currentVelocity.Y,
			currentVelocity.Z * (1 - MovementConstants.DashBrakeForce)
		)
	end
end

function DashController._resetForNewCharacter(self: DashController)
	self:_cancelDashEndThread()
	self:_cancelDodgeCancelEndThread()

	if self._steerConnection then
		self._steerConnection:Disconnect()
		self._steerConnection = nil
	end
	if self._velocity then
		self._velocity:Destroy()
		self._velocity = nil
	end
	if self._attachment then
		self._attachment:Destroy()
		self._attachment = nil
	end
end

function DashController._beginDash(self: DashController, humanoid: Humanoid, rootPart: BasePart)
	local velocity = self._velocity :: LinearVelocity
	velocity.MaxAxesForce = GROUND_LOCK_FORCE
	velocity.VectorVelocity = Vector3.zero
	velocity.Enabled = true

	-- Decays to whatever ground speed we were carrying (walk/run), not always WalkSpeed.
	local startSpeed = MovementConstants.DashPower
	local endSpeed = humanoid.WalkSpeed
	local startTime = os.clock()
	self._dashStartTime = startTime

	-- Locked in from whatever's held the instant the dash starts (no input at all defaults to a
	-- backstep, -LookVector) -- the Heartbeat below only ever UPDATES this while input is still
	-- actively held, letting the dash curve mid-flight without snapping to reverse the moment a
	-- held key is released.
	local initialMoveVector = humanoid.MoveDirection
	local dashDirection = if initialMoveVector.Magnitude > MovementConstants.DashSteerDeadzone
		then initialMoveVector.Unit
		else -rootPart.CFrame.LookVector

	self._steerConnection = RunService.Heartbeat:Connect(function()
		local moveVector = humanoid.MoveDirection
		if moveVector.Magnitude > MovementConstants.DashSteerDeadzone then
			dashDirection = moveVector.Unit
		end

		-- Exponential ease-out (same curve TweenInfo(Exponential, Out) produces), computed inline
		-- instead of driving a throwaway NumberValue/Tween pair through every dash.
		local alpha = math.clamp((os.clock() - startTime) / MovementConstants.DashDuration, 0, 1)
		local eased = if alpha >= 1 then 1 else 1 - 2 ^ (-10 * alpha)
		local speed = startSpeed + (endSpeed - startSpeed) * eased

		velocity.VectorVelocity = dashDirection * speed
	end)

	self._dashEndThread = task.delay(MovementConstants.DashDuration, function()
		self._dashEndThread = nil
		if MovementConstants.DashingStates[movementFSM:GetState()] then
			MovementController:RefreshMovementState()
		end
	end)
end

function DashController._tryDash(self: DashController, humanoid: Humanoid, rootPart: BasePart)
	local now = os.clock()
	local category = classifyDashCategory(humanoid.MoveDirection, rootPart.CFrame.LookVector, rootPart.CFrame.RightVector)
	local cooldown = self._dashCooldowns[category]

	if now - cooldown.lastDashTime < MovementConstants.DashCooldowns[category] then
		return
	end

	local currentState = movementFSM:GetState()
	local isDashCategorySwitch = MovementConstants.DashingStates[currentState]
		and category ~= self._lastDashCategory
		and now - self._dashStartTime >= MovementConstants.DashCategorySwitchDelay

	if not isDashCategorySwitch and MovementConstants.LockedMovementStates[currentState] then
		return
	end

	cooldown.lastDashTime = now
	self._lastDashCategory = category
	movementFSM:TransitionTo(DashCategoryMovementStates[category])
	requestDash:FireServer(category)
	self:_beginDash(humanoid, rootPart)
end

function DashController._tryRollCancel(self: DashController)
	if not MovementConstants.DashingStates[movementFSM:GetState()] then
		return
	end

	local now = os.clock()
	self._rollCancelCharges, self._rollCancelChargeRegenStart = regenCharges(
		self._rollCancelCharges,
		self._rollCancelChargeRegenStart,
		now,
		MovementConstants.RollCancelMaxCharges,
		MovementConstants.RollCancelChargeCooldown
	)

	if self._rollCancelCharges <= 0 then
		return
	end
	self._rollCancelCharges -= 1

	local cooldown = self._dashCooldowns[self._lastDashCategory]
	if now - cooldown.lastDashCooldownResetAt >= MovementConstants.DashCooldowns[self._lastDashCategory] then
		cooldown.lastDashTime = -math.huge
		cooldown.lastDashCooldownResetAt = now
	end

	requestRollCancel:FireServer()
	movementFSM:TransitionTo(MovementState.DodgeCancelling)

	self._dodgeCancelEndThread = task.delay(MovementConstants.DodgeCancelRecoveryTime, function()
		self._dodgeCancelEndThread = nil
		if movementFSM:GetState() == MovementState.DodgeCancelling then
			MovementController:RefreshMovementState()
		end
	end)
end

function DashController._setupCharacter(self: DashController, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	disconnectAll(self._connections)
	self:_resetForNewCharacter()

	self._dashCooldowns = newDashCooldownStates()
	self._lastDashCategory = DashCategory.Forward
	self._dashStartTime = -math.huge
	self._rollCancelCharges = MovementConstants.RollCancelMaxCharges
	self._rollCancelChargeRegenStart = os.clock()

	local attachment = Instance.new("Attachment")
	attachment.Name = "DashAttachment"
	attachment.Parent = rootPart

	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "DashVelocity"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	velocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	velocity.Enabled = false
	velocity.Parent = rootPart

	self._attachment = attachment
	self._velocity = velocity

	table.insert(
		self._connections,
		movementFSM.Changed:Connect(function(_newState: string, oldState: string)
			if MovementConstants.DashingStates[oldState] then
				self:_stopPhysics(humanoid, rootPart)
			end
		end)
	)

	table.insert(
		self._connections,
		humanoid.Died:Connect(function()
			disconnectAll(self._connections)
			self:_resetForNewCharacter()
		end)
	)
end

function DashController.Init(self: DashController)
	onCharacterAdded(player, function(character: Model)
		self:_setupCharacter(character)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			self:_tryRollCancel()
			return
		end

		if input.KeyCode ~= MovementConstants.DashKey then
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

		self:_tryDash(humanoid, rootPart)
	end)
end

return DashController.new()
