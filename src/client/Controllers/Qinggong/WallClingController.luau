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
local movementFSM = require(script.Parent.Parent.Parent.State.MovementFSM)
local MovementController = require(script.Parent.Parent.Movement.MovementController)
local SprintController = require(script.Parent.Parent.Movement.SprintController)

local requestWallCling = ReplicatedStorage.Remotes.RequestWallCling :: RemoteEvent
local requestWallBoost = ReplicatedStorage.Remotes.RequestWallBoost :: RemoteEvent
local requestWallClingDoubleJump = ReplicatedStorage.Remotes.RequestWallClingDoubleJump :: RemoteEvent
local requestWallClimbLeap = ReplicatedStorage.Remotes.RequestWallClimbLeap :: RemoteEvent

local player = Players.LocalPlayer

local UP = Vector3.new(0, 1, 0)
local FULL_LOCK_FORCE =
	Vector3.new(MovementConstants.MaxPhysicsForce, MovementConstants.MaxPhysicsForce, MovementConstants.MaxPhysicsForce)

-- States a wall cling (and its recovery hop) may be entered from -- chaining a wall-run leap
-- straight into a wall grab is allowed, same as WallHanging is one of WallRunning's own entry states.
local WALL_CLING_ENTRY_STATES = {
	[MovementState.Jumping] = true,
	[MovementState.Falling] = true,
	[MovementState.WallLeaping] = true,
}

local WallClingController = {}
WallClingController.__index = WallClingController

export type WallClingController = typeof(setmetatable(
	{} :: {
		_connections: { RBXScriptConnection },
		_attachment: Attachment?,
		_velocity: LinearVelocity?,
		_hangConnection: RBXScriptConnection?,
		_boostConnection: RBXScriptConnection?,
		_boostEndThread: thread?,
		_doubleJumpEndThread: thread?,
		_leapReleaseThread: thread?,
		_leapEndThread: thread?,
		_wallClingDoubleJumpDeadline: number,
		_wallClingChainCount: number,
		_rayParams: RaycastParams?,
	},
	WallClingController
))

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

function WallClingController.new(): WallClingController
	local self = setmetatable({
		_connections = {},
		_attachment = nil,
		_velocity = nil,
		_hangConnection = nil,
		_boostConnection = nil,
		_boostEndThread = nil,
		_doubleJumpEndThread = nil,
		_leapReleaseThread = nil,
		_leapEndThread = nil,
		_wallClingDoubleJumpDeadline = 0,
		_wallClingChainCount = 0,
		_rayParams = nil,
	}, WallClingController)

	return self
end

-- Three forward rays (center + a side offset each way) instead of WallRunController's single side
-- ray -- a flat wall square ahead needs wider coverage than one ray to avoid losing the grab to a
-- gap or corner. Snaps the character to face directly into the wall on success, same as the old
-- game's grab did, so WallBoost/WallClimbLeaping can later derive their launch direction from
-- -LookVector without needing their own raycast.
function WallClingController._checkWallCling(self: WallClingController, rootPart: BasePart): RaycastResult?
	local origin = rootPart.Position
	local look = rootPart.CFrame.LookVector
	local right = rootPart.CFrame.RightVector
	local offset = MovementConstants.WallSideCheckOffset
	local range = MovementConstants.WallClingDetectionRange

	local centerHit = workspace:Raycast(origin, look * range, self._rayParams)
	local rightHit = workspace:Raycast(origin + (right * offset), look * range, self._rayParams)
	local leftHit = workspace:Raycast(origin - (right * offset), look * range, self._rayParams)

	if not (centerHit and rightHit and leftHit) then
		return nil
	end
	if not (centerHit.Instance.CanCollide and rightHit.Instance.CanCollide and leftHit.Instance.CanCollide) then
		return nil
	end
	if math.abs(centerHit.Normal:Dot(UP)) >= MovementConstants.WallFlatnessThreshold then
		return nil
	end

	return centerHit
end

-- Non-mutating twin of the check above -- used every throttled tick while already hanging, skipping
-- the flatness re-check and never re-orienting, just "is the wall still there."
function WallClingController._checkStillClinging(self: WallClingController, rootPart: BasePart): boolean
	local origin = rootPart.Position
	local look = rootPart.CFrame.LookVector
	local right = rootPart.CFrame.RightVector
	local offset = MovementConstants.WallSideCheckOffset
	local range = MovementConstants.WallClingDetectionRange

	local centerHit = workspace:Raycast(origin, look * range, self._rayParams)
	local rightHit = workspace:Raycast(origin + (right * offset), look * range, self._rayParams)
	local leftHit = workspace:Raycast(origin - (right * offset), look * range, self._rayParams)

	if not (centerHit and rightHit and leftHit) then
		return false
	end
	return centerHit.Instance.CanCollide and rightHit.Instance.CanCollide and leftHit.Instance.CanCollide
end

function WallClingController._cancelBoostThread(self: WallClingController)
	if self._boostEndThread then
		task.cancel(self._boostEndThread)
		self._boostEndThread = nil
	end
end

function WallClingController._cancelDoubleJumpThread(self: WallClingController)
	if self._doubleJumpEndThread then
		task.cancel(self._doubleJumpEndThread)
		self._doubleJumpEndThread = nil
	end
end

function WallClingController._cancelLeapThreads(self: WallClingController)
	if self._leapReleaseThread then
		task.cancel(self._leapReleaseThread)
		self._leapReleaseThread = nil
	end
	if self._leapEndThread then
		task.cancel(self._leapEndThread)
		self._leapEndThread = nil
	end
end

-- Shared by WallHanging's own exit (wall/floor lost, duration timeout) and WallClingDoubleJump's
-- timeout -- both always resolve to Falling (or hand back to the ground if physics already reports
-- landed), never to Jumping. Returns whether it actually forced Falling, so WallBoost's exit can
-- decide whether to arm the recovery-hop window off that.
function WallClingController._resolveToFalling(self: WallClingController, humanoid: Humanoid): boolean
	local humanoidState = humanoid:GetState()
	if humanoidState == Enum.HumanoidStateType.Landed
		or humanoidState == Enum.HumanoidStateType.Running
		or humanoidState == Enum.HumanoidStateType.RunningNoPhysics
	then
		MovementController:RefreshMovementState()
		return false
	end

	movementFSM:TransitionTo(MovementState.Falling)
	return true
end

-- WallClimbLeaping's own timeout, unlike the above, can resolve back into an ascending Jumping arc --
-- same Jumping/Freefall distinction WallRunController's own WallLeaping timeout uses.
function WallClingController._resolveToAirborneState(self: WallClingController, humanoid: Humanoid)
	local humanoidState = humanoid:GetState()
	if humanoidState == Enum.HumanoidStateType.Jumping then
		movementFSM:TransitionTo(MovementState.Jumping)
	elseif humanoidState == Enum.HumanoidStateType.Freefall then
		movementFSM:TransitionTo(MovementState.Falling)
	else
		MovementController:RefreshMovementState()
	end
end

function WallClingController._stopHangPhysics(self: WallClingController)
	if self._hangConnection then
		self._hangConnection:Disconnect()
		self._hangConnection = nil
	end
	if self._velocity then
		self._velocity.Enabled = false
	end
end

function WallClingController._beginWallHang(self: WallClingController, humanoid: Humanoid, rootPart: BasePart)
	humanoid.AutoRotate = false

	local velocity = self._velocity :: LinearVelocity
	velocity.MaxAxesForce = FULL_LOCK_FORCE
	velocity.VectorVelocity = Vector3.zero
	velocity.Enabled = true

	-- The downward "grip is failing" slide is cheap (a smooth function of elapsed time) and runs
	-- every frame; the three-ray still-clinging/floor check is throttled to ParkourTickRate like
	-- WallRunController's own steering loop.
	local hangStartTime = os.clock()
	local rayAccumulator = 0

	self._hangConnection = RunService.Heartbeat:Connect(function(dt: number)
		if not velocity.Enabled then
			return
		end

		local elapsed = os.clock() - hangStartTime
		local slideSpeed = math.min(elapsed * MovementConstants.WallClingSlideAcceleration, MovementConstants.WallClingMaxSlideSpeed)
		velocity.VectorVelocity = Vector3.new(0, -slideSpeed, 0)

		rayAccumulator += dt
		if rayAccumulator < MovementConstants.ParkourTickRate then
			return
		end
		rayAccumulator = 0

		local stillClinging = self:_checkStillClinging(rootPart)
		local floorRay = workspace:Raycast(
			rootPart.Position,
			Vector3.new(0, -MovementConstants.WallRunFloorCheckDistance, 0),
			self._rayParams
		)

		if not stillClinging or floorRay or elapsed >= MovementConstants.WallClingDuration then
			self:_endWallHang(humanoid)
		end
	end)
end

function WallClingController._endWallHang(self: WallClingController, humanoid: Humanoid)
	self:_stopHangPhysics()
	humanoid.AutoRotate = true

	if movementFSM:GetState() ~= MovementState.WallHanging then
		return
	end

	self:_resolveToFalling(humanoid)
end

function WallClingController._tryStartWallCling(self: WallClingController, humanoid: Humanoid, rootPart: BasePart): boolean
	local currentState = movementFSM:GetState()
	if not WALL_CLING_ENTRY_STATES[currentState] then
		return false
	end

	-- Caps how many times a cling can be chained (cling -> boost/leap -> cling -> ...) before a real
	-- ground landing is required -- see MovementConstants.WallClingMaxChainCount.
	if self._wallClingChainCount >= MovementConstants.WallClingMaxChainCount then
		return false
	end

	if not hasEnoughQinggong(MovementConstants.QinggongCostWallCling) then
		return false
	end

	local hit = self:_checkWallCling(rootPart)
	if not hit then
		return false
	end

	rootPart.CFrame = CFrame.lookAt(rootPart.Position, rootPart.Position - hit.Normal)

	self._wallClingChainCount += 1
	movementFSM:TransitionTo(MovementState.WallHanging)
	requestWallCling:FireServer()
	self:_beginWallHang(humanoid, rootPart)
	return true
end

function WallClingController._tryWallBoost(self: WallClingController, humanoid: Humanoid, rootPart: BasePart)
	if movementFSM:GetState() ~= MovementState.WallHanging then
		return
	end

	if not hasEnoughQinggong(MovementConstants.QinggongCostWallBoost) then
		return
	end

	self:_stopHangPhysics()
	humanoid.AutoRotate = true

	-- WallHanging orients us INTO the wall, so "away" is the opposite of current LookVector -- no
	-- raycast needed here, same reasoning as the old game's boost.
	local awayFromWall = -rootPart.CFrame.LookVector
	-- Qinggong Sprinting empowers this too ("wall jump / climb is also stronger").
	local boostMultiplier = if SprintController:IsSprintActive() then MovementConstants.SprintWallJumpMultiplier else 1
	rootPart.AssemblyLinearVelocity = (awayFromWall * MovementConstants.WallBoostBackPower * boostMultiplier)
		+ Vector3.new(0, MovementConstants.WallBoostPower * boostMultiplier, 0)

	movementFSM:TransitionTo(MovementState.WallBoost)
	requestWallBoost:FireServer()

	if self._boostConnection then
		self._boostConnection:Disconnect()
	end
	self._boostConnection = RunService.Heartbeat:Connect(function()
		if rootPart.AssemblyLinearVelocity.Y <= 0 then
			self:_endWallBoost(humanoid)
		end
	end)

	self:_cancelBoostThread()
	self._boostEndThread = task.delay(MovementConstants.WallBoostDuration, function()
		self._boostEndThread = nil
		if movementFSM:GetState() == MovementState.WallBoost then
			self:_endWallBoost(humanoid)
		end
	end)
end

-- Ends WallBoost for any reason (apex reached, hard-timeout backstop) -- arms the recovery-hop
-- window only if it actually resolved to Falling, not if it landed straight back on the ground.
function WallClingController._endWallBoost(self: WallClingController, humanoid: Humanoid)
	self:_cancelBoostThread()
	if self._boostConnection then
		self._boostConnection:Disconnect()
		self._boostConnection = nil
	end

	if movementFSM:GetState() ~= MovementState.WallBoost then
		return
	end

	if self:_resolveToFalling(humanoid) then
		self._wallClingDoubleJumpDeadline = os.clock() + MovementConstants.WallClingDoubleJumpWindow
	end
end

function WallClingController._tryWallClingDoubleJump(self: WallClingController, humanoid: Humanoid, rootPart: BasePart)
	local currentState = movementFSM:GetState()
	if not WALL_CLING_ENTRY_STATES[currentState] then
		return
	end
	if os.clock() >= self._wallClingDoubleJumpDeadline then
		return
	end

	if not hasEnoughQinggong(MovementConstants.QinggongCostWallClingDoubleJump) then
		return
	end
	self._wallClingDoubleJumpDeadline = 0

	movementFSM:TransitionTo(MovementState.WallClingDoubleJump)
	requestWallClingDoubleJump:FireServer()

	local currentVelocity = rootPart.AssemblyLinearVelocity
	rootPart.AssemblyLinearVelocity = Vector3.new(currentVelocity.X, MovementConstants.WallClingDoubleJumpVelocity, currentVelocity.Z)

	self:_cancelDoubleJumpThread()
	self._doubleJumpEndThread = task.delay(MovementConstants.WallClingDoubleJumpDuration, function()
		self._doubleJumpEndThread = nil
		if movementFSM:GetState() == MovementState.WallClingDoubleJump then
			self:_resolveToFalling(humanoid)
		end
	end)
end

-- WallHanging's own release move (crouch key) -- a real leap off the wall instead of the old game's
-- plain backward kick, so it gets the same brief hard-lock-then-release treatment WallRunController
-- gives WallLeaping, keeping a leap fired at close range from re-colliding with the wall it just left.
function WallClingController._tryWallClimbLeap(self: WallClingController, humanoid: Humanoid, rootPart: BasePart)
	if movementFSM:GetState() ~= MovementState.WallHanging then
		return
	end

	if not hasEnoughQinggong(MovementConstants.QinggongCostWallClimbLeap) then
		return
	end

	self:_stopHangPhysics()

	local awayFromWall = -rootPart.CFrame.LookVector
	rootPart.CFrame += awayFromWall * MovementConstants.WallClimbLeapNormalOffset
	humanoid.AutoRotate = true
	humanoid:ChangeState(Enum.HumanoidStateType.Freefall)

	movementFSM:TransitionTo(MovementState.WallClimbLeaping)
	requestWallClimbLeap:FireServer()

	local leapMultiplier = if SprintController:IsSprintActive() then MovementConstants.SprintWallJumpMultiplier else 1

	local velocity = self._velocity :: LinearVelocity
	velocity.MaxAxesForce = FULL_LOCK_FORCE
	velocity.VectorVelocity = (awayFromWall * MovementConstants.WallClimbLeapOutwardPower * leapMultiplier)
		+ Vector3.new(0, MovementConstants.WallClimbLeapUpwardPower * leapMultiplier, 0)
	velocity.Enabled = true

	self:_cancelLeapThreads()
	self._leapReleaseThread = task.delay(MovementConstants.WallClimbLeapReleaseDelay, function()
		self._leapReleaseThread = nil
		velocity.Enabled = false
	end)

	self._leapEndThread = task.delay(MovementConstants.WallClimbLeapDuration, function()
		self._leapEndThread = nil
		if movementFSM:GetState() == MovementState.WallClimbLeaping then
			self:_resolveToAirborneState(humanoid)
		end
	end)
end

function WallClingController._resetForNewCharacter(self: WallClingController)
	self:_cancelBoostThread()
	self:_cancelDoubleJumpThread()
	self:_cancelLeapThreads()
	self._wallClingDoubleJumpDeadline = 0
	self._wallClingChainCount = 0

	if self._hangConnection then
		self._hangConnection:Disconnect()
		self._hangConnection = nil
	end
	if self._boostConnection then
		self._boostConnection:Disconnect()
		self._boostConnection = nil
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

function WallClingController._setupCharacter(self: WallClingController, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	disconnectAll(self._connections)
	self:_resetForNewCharacter()

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }
	self._rayParams = rayParams

	local attachment = Instance.new("Attachment")
	attachment.Name = "WallClingAttachment"
	attachment.Parent = rootPart

	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "WallClingVelocity"
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
			if oldState == MovementState.WallHanging then
				self:_stopHangPhysics()
			elseif oldState == MovementState.WallBoost then
				self:_cancelBoostThread()
				if self._boostConnection then
					self._boostConnection:Disconnect()
					self._boostConnection = nil
				end
			elseif oldState == MovementState.WallClingDoubleJump then
				self:_cancelDoubleJumpThread()
			elseif oldState == MovementState.WallClimbLeaping then
				self:_cancelLeapThreads()
				if self._velocity then
					self._velocity.Enabled = false
				end
			end
		end)
	)

	-- Ground truth for the chain-limit reset -- a real landing, not just entering a grounded
	-- MovementState, so it can't be gamed by a controller resolving straight to Idle/Walking without
	-- Humanoid ever reporting Landed.
	table.insert(
		self._connections,
		humanoid.StateChanged:Connect(function(_oldState: Enum.HumanoidStateType, newState: Enum.HumanoidStateType)
			if newState == Enum.HumanoidStateType.Landed then
				self._wallClingChainCount = 0
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

function WallClingController.Init(self: WallClingController)
	onCharacterAdded(player, function(character: Model)
		self:_setupCharacter(character)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
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

		if input.KeyCode == Enum.KeyCode.Space then
			local currentState = movementFSM:GetState()
			if currentState == MovementState.WallHanging then
				self:_tryWallBoost(humanoid, rootPart)
			elseif WALL_CLING_ENTRY_STATES[currentState] then
				if not self:_tryStartWallCling(humanoid, rootPart) then
					self:_tryWallClingDoubleJump(humanoid, rootPart)
				end
			end
		elseif input.KeyCode == MovementConstants.SlideKey or input.KeyCode == MovementConstants.SlideAltKey then
			self:_tryWallClimbLeap(humanoid, rootPart)
		end
	end)
end

return WallClingController.new()
