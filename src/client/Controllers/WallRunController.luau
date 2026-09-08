--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local MovementState = require(Shared.Enums.MovementState)
local MovementConstants = require(Shared.Constants.MovementConstants)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local hasEnoughQinggong = require(Shared.Utils.HasEnoughQinggong)
local movementFSM = require(script.Parent.Parent.State.MovementFSM)
local MovementController = require(script.Parent.MovementController)
local SprintController = require(script.Parent.SprintController)

local requestWallRun = ReplicatedStorage.Remotes.RequestWallRun :: RemoteEvent
local requestWallLeap = ReplicatedStorage.Remotes.RequestWallLeap :: RemoteEvent

local player = Players.LocalPlayer

local UP = Vector3.new(0, 1, 0)
local FULL_LOCK_FORCE =
	Vector3.new(MovementConstants.MaxPhysicsForce, MovementConstants.MaxPhysicsForce, MovementConstants.MaxPhysicsForce)

-- States a wall run/leap may be entered from -- chaining a leap straight into another run is
-- allowed, same as chaining a run straight into another leap.
local WALL_RUN_ENTRY_STATES = {
	[MovementState.Jumping] = true,
	[MovementState.Falling] = true,
	[MovementState.WallLeaping] = true,
}

local WallRunController = {}
WallRunController.__index = WallRunController

export type WallRunController = typeof(setmetatable(
	{} :: {
		_connections: { RBXScriptConnection },
		_attachment: Attachment?,
		_velocity: LinearVelocity?,
		_alignOrientation: AlignOrientation?,
		_runConnection: RBXScriptConnection?,
		_maxDurationThread: thread?,
		_leapReleaseThread: thread?,
		_leapEndThread: thread?,
		_chainCount: number,
		_rayParams: RaycastParams?,
	},
	WallRunController
))

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

function WallRunController.new(): WallRunController
	local self = setmetatable({
		_connections = {},
		_attachment = nil,
		_velocity = nil,
		_alignOrientation = nil,
		_runConnection = nil,
		_maxDurationThread = nil,
		_leapReleaseThread = nil,
		_leapEndThread = nil,
		_chainCount = 0,
		_rayParams = nil,
	}, WallRunController)

	return self
end

-- Same side-raycast shape used everywhere below: a hit on either side that isn't too flat (a floor
-- or ceiling grazed at a shallow angle) counts as a wall.
function WallRunController._sampleWallHit(self: WallRunController, rootPart: BasePart, rayLength: number): RaycastResult?
	local rightRay = workspace:Raycast(rootPart.Position, rootPart.CFrame.RightVector * rayLength, self._rayParams)
	local leftRay = workspace:Raycast(rootPart.Position, -rootPart.CFrame.RightVector * rayLength, self._rayParams)
	local hit = rightRay or leftRay

	if hit and hit.Instance.CanCollide and math.abs(hit.Normal:Dot(UP)) < MovementConstants.WallFlatnessThreshold then
		return hit
	end
	return nil
end

-- Entry requires actually moving into a side wall -- an idle character standing next to one
-- shouldn't get yanked onto it. Chaining off a leap reaches further: WallLeapOutwardPower covers
-- the base entry range fast enough that physics would otherwise bounce the character off the next
-- wall before this ever got a chance to see it (only checked on the Space keypress, not every tick).
function WallRunController._checkWallRunEntry(self: WallRunController, humanoid: Humanoid, rootPart: BasePart): RaycastResult?
	if humanoid.MoveDirection.Magnitude == 0 then
		return nil
	end

	local rayLength = if movementFSM:GetState() == MovementState.WallLeaping
		then MovementConstants.WallRunChainEntryRayDistance
		else MovementConstants.WallSideRayDistance
	return self:_sampleWallHit(rootPart, rayLength)
end

function WallRunController._cancelMaxDurationThread(self: WallRunController)
	if self._maxDurationThread then
		task.cancel(self._maxDurationThread)
		self._maxDurationThread = nil
	end
end

function WallRunController._cancelLeapThreads(self: WallRunController)
	if self._leapReleaseThread then
		task.cancel(self._leapReleaseThread)
		self._leapReleaseThread = nil
	end
	if self._leapEndThread then
		task.cancel(self._leapEndThread)
		self._leapEndThread = nil
	end
end

-- Hands the FSM back to whichever airborne state the underlying Humanoid actually reports, same
-- resolution AirDash/DoubleJump use -- falls back to a full ground re-evaluation if Humanoid says
-- neither (e.g. it already landed while the run/leap was still resolving).
function WallRunController._resolveToAirborneState(self: WallRunController, humanoid: Humanoid)
	local humanoidState = humanoid:GetState()
	if humanoidState == Enum.HumanoidStateType.Jumping then
		movementFSM:TransitionTo(MovementState.Jumping)
	elseif humanoidState == Enum.HumanoidStateType.Freefall then
		movementFSM:TransitionTo(MovementState.Falling)
	else
		MovementController:RefreshMovementState()
	end
end

function WallRunController._stopRunPhysics(self: WallRunController)
	self:_cancelMaxDurationThread()

	if self._runConnection then
		self._runConnection:Disconnect()
		self._runConnection = nil
	end
	if self._alignOrientation then
		self._alignOrientation.Enabled = false
	end
end

function WallRunController._beginWallRun(self: WallRunController, humanoid: Humanoid, rootPart: BasePart)
	humanoid.AutoRotate = false

	local velocity = self._velocity :: LinearVelocity
	velocity.MaxAxesForce = FULL_LOCK_FORCE
	velocity.VectorVelocity = Vector3.zero
	velocity.Enabled = true

	local alignOrientation = self._alignOrientation :: AlignOrientation
	alignOrientation.Responsiveness = MovementConstants.WallRunTurnResponsiveness
	alignOrientation.Enabled = true

	-- Throttled to ParkourTickRate instead of raycasting every physics step; the same cached hit
	-- drives both the steering below and the wall-loss exit check.
	local rayAccumulator = 0
	local cachedHit = self:_sampleWallHit(rootPart, MovementConstants.WallSideRayDistance)
	local startTime = os.clock()

	-- Qinggong Sprinting empowers the run's speed -- locked in once at entry, same shape as every
	-- other sprint-boosted ability.
	local runSpeed = MovementConstants.WallRunSpeed
	if SprintController:IsSprintActive() then
		runSpeed *= MovementConstants.SprintWallRunSpeedMultiplier
	end

	self._runConnection = RunService.Heartbeat:Connect(function(dt: number)
		if not velocity.Enabled then
			return
		end

		rayAccumulator += dt
		local isFreshSample = rayAccumulator >= MovementConstants.ParkourTickRate
		if isFreshSample then
			rayAccumulator = 0
			cachedHit = self:_sampleWallHit(rootPart, MovementConstants.WallSideRayDistance)

			if not cachedHit then
				self:_endWallRun(humanoid)
				return
			end

			local floorRay = workspace:Raycast(
				rootPart.Position,
				Vector3.new(0, -MovementConstants.WallRunFloorCheckDistance, 0),
				self._rayParams
			)
			if floorRay then
				self:_endWallRun(humanoid)
				return
			end
		end

		if not cachedHit then
			return
		end

		local cross1 = cachedHit.Normal:Cross(UP)
		local cross2 = UP:Cross(cachedHit.Normal)
		local runDirection = if rootPart.CFrame.LookVector:Dot(cross1) > 0 then cross1 else cross2
		local pushIn = -cachedHit.Normal * MovementConstants.WallRunPushInSpeed

		-- Decays from an initial upward kick down to the steady sink -- see
		-- MovementConstants.WallRunEntryBoostPower's comment for why this exists.
		local boostProgress = math.clamp((os.clock() - startTime) / MovementConstants.WallRunEntryBoostDuration, 0, 1)
		local verticalSpeed = (MovementConstants.WallRunEntryBoostPower * (1 - boostProgress))
			- (MovementConstants.WallRunGravity * boostProgress)

		velocity.VectorVelocity = (runDirection.Unit * runSpeed) + pushIn + Vector3.new(0, verticalSpeed, 0)
		alignOrientation.CFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + runDirection)
	end)

	self._maxDurationThread = task.delay(MovementConstants.WallRunMaxDuration, function()
		self._maxDurationThread = nil
		if movementFSM:GetState() == MovementState.WallRunning then
			self:_endWallRun(humanoid)
		end
	end)
end

-- Ends WallRunning for any reason (wall/floor lost, max-duration failsafe, character died) --
-- mirrors AirborneController's own endAirborneStateToFalling: a real landing that happened to
-- resolve before this fired takes priority over forcing Falling.
function WallRunController._endWallRun(self: WallRunController, humanoid: Humanoid)
	self:_stopRunPhysics()
	if self._velocity then
		self._velocity.Enabled = false
	end
	humanoid.AutoRotate = true

	if movementFSM:GetState() ~= MovementState.WallRunning then
		return
	end

	local humanoidState = humanoid:GetState()
	if humanoidState == Enum.HumanoidStateType.Landed
		or humanoidState == Enum.HumanoidStateType.Running
		or humanoidState == Enum.HumanoidStateType.RunningNoPhysics
	then
		MovementController:RefreshMovementState()
		return
	end

	movementFSM:TransitionTo(MovementState.Falling)
end

-- Exposed so other Space-bound controllers (DoubleJumpController) can check, before consuming the
-- same keypress themselves, whether it would instead trigger a wall run -- rather than relying
-- purely on this controller's own InputBegan connection happening to fire first.
function WallRunController.CanStartWallRun(self: WallRunController, humanoid: Humanoid, rootPart: BasePart): boolean
	if not WALL_RUN_ENTRY_STATES[movementFSM:GetState()] then
		return false
	end

	-- Caps how many times a run can be chained (run -> leap -> run -> ...) before a real ground
	-- landing is required -- see MovementConstants.WallRunMaxChainCount.
	if self._chainCount >= MovementConstants.WallRunMaxChainCount then
		return false
	end

	if not hasEnoughQinggong(MovementConstants.QinggongCostWallRun) then
		return false
	end

	return self:_checkWallRunEntry(humanoid, rootPart) ~= nil
end

function WallRunController._tryStartWallRun(self: WallRunController, humanoid: Humanoid, rootPart: BasePart)
	if not self:CanStartWallRun(humanoid, rootPart) then
		return
	end

	self._chainCount += 1
	movementFSM:TransitionTo(MovementState.WallRunning)
	requestWallRun:FireServer()
	self:_beginWallRun(humanoid, rootPart)
end

function WallRunController._tryWallLeap(self: WallRunController, humanoid: Humanoid, rootPart: BasePart)
	if movementFSM:GetState() ~= MovementState.WallRunning then
		return
	end

	if not hasEnoughQinggong(MovementConstants.QinggongCostWallLeap) then
		return
	end

	self:_stopRunPhysics()

	local hit = self:_sampleWallHit(rootPart, MovementConstants.WallLeapRayLength)
	local wallNormal = if hit then hit.Normal else rootPart.CFrame.LookVector
	local forwardDirection = rootPart.CFrame.LookVector
	local leapDirection = (wallNormal + (forwardDirection * MovementConstants.WallLeapForwardOffset)).Unit

	-- Nudge clear of the wall's surface first so the leap doesn't immediately re-collide with the
	-- wall it just launched off of.
	rootPart.CFrame += wallNormal * MovementConstants.WallLeapNormalOffset
	humanoid.AutoRotate = true
	humanoid:ChangeState(Enum.HumanoidStateType.Freefall)

	movementFSM:TransitionTo(MovementState.WallLeaping)
	requestWallLeap:FireServer()

	-- Qinggong Sprinting empowers this leap-off too ("wall jump ... is also stronger"), though less
	-- than WallBoost/WallClimbLeaping -- see SprintWallLeapMultiplier's own comment.
	local leapMultiplier = if SprintController:IsSprintActive() then MovementConstants.SprintWallLeapMultiplier else 1

	local velocity = self._velocity :: LinearVelocity
	velocity.MaxAxesForce = FULL_LOCK_FORCE
	velocity.VectorVelocity = (leapDirection * MovementConstants.WallLeapOutwardPower * leapMultiplier)
		+ Vector3.new(0, MovementConstants.WallLeapUpwardPower * leapMultiplier, 0)
	velocity.Enabled = true

	self:_cancelLeapThreads()
	self._leapReleaseThread = task.delay(MovementConstants.WallLeapReleaseDelay, function()
		self._leapReleaseThread = nil
		velocity.Enabled = false
	end)

	self._leapEndThread = task.delay(MovementConstants.WallLeapDuration, function()
		self._leapEndThread = nil
		if movementFSM:GetState() == MovementState.WallLeaping then
			self:_resolveToAirborneState(humanoid)
		end
	end)
end

function WallRunController._resetForNewCharacter(self: WallRunController)
	self:_cancelMaxDurationThread()
	self:_cancelLeapThreads()
	self._chainCount = 0

	if self._runConnection then
		self._runConnection:Disconnect()
		self._runConnection = nil
	end
	if self._alignOrientation then
		self._alignOrientation:Destroy()
		self._alignOrientation = nil
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

function WallRunController._setupCharacter(self: WallRunController, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	disconnectAll(self._connections)
	self:_resetForNewCharacter()

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }
	self._rayParams = rayParams

	local attachment = Instance.new("Attachment")
	attachment.Name = "WallRunAttachment"
	attachment.Parent = rootPart

	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "WallRunVelocity"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	velocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	velocity.Enabled = false
	velocity.Parent = rootPart

	-- Torque-based orientation steering instead of writing rootPart.CFrame directly while
	-- LinearVelocity also drives the part.
	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "WallRunOrientation"
	alignOrientation.Attachment0 = attachment
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.RigidityEnabled = false
	alignOrientation.MaxTorque = MovementConstants.MaxPhysicsTorque
	alignOrientation.Enabled = false
	alignOrientation.Parent = rootPart

	self._attachment = attachment
	self._velocity = velocity
	self._alignOrientation = alignOrientation

	table.insert(
		self._connections,
		movementFSM.Changed:Connect(function(_newState: string, oldState: string)
			if oldState == MovementState.WallRunning then
				self:_stopRunPhysics()
				if self._velocity then
					self._velocity.Enabled = false
				end
			elseif oldState == MovementState.WallLeaping then
				self:_cancelLeapThreads()
				if self._velocity then
					self._velocity.Enabled = false
				end
			end
		end)
	)

	-- Ground truth for the chain-limit reset -- a real landing, not just entering a grounded
	-- MovementState, same reasoning as WallClingController's own reset.
	table.insert(
		self._connections,
		humanoid.StateChanged:Connect(function(_oldState: Enum.HumanoidStateType, newState: Enum.HumanoidStateType)
			if newState == Enum.HumanoidStateType.Landed then
				self._chainCount = 0
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

function WallRunController.Init(self: WallRunController)
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

		if movementFSM:GetState() == MovementState.WallRunning then
			self:_tryWallLeap(humanoid, rootPart)
		else
			self:_tryStartWallRun(humanoid, rootPart)
		end
	end)
end

return WallRunController.new()
