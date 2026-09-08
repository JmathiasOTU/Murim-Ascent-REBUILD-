--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local MovementState = require(Shared.Enums.MovementState)
local MovementConstants = require(Shared.Constants.MovementConstants)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local movementFSM = require(script.Parent.Parent.State.MovementFSM)
local MovementController = require(script.Parent.MovementController)
local SprintController = require(script.Parent.SprintController)

local requestSlide = ReplicatedStorage.Remotes.RequestSlide :: RemoteEvent

local player = Players.LocalPlayer

-- Y-force left at 0 so gravity still applies off a ledge; only X/Z are locked to the steered
-- slide velocity. Swapped for FULL_LOCK_FORCE (below) while a ground normal is actually known,
-- so the commanded velocity's vertical component can follow the slope instead of the character
-- outrunning gravity's ability to pull it back onto a steep ramp each physics step.
local GROUND_LOCK_FORCE = Vector3.new(MovementConstants.MaxPhysicsForce, 0, MovementConstants.MaxPhysicsForce)
local FULL_LOCK_FORCE =
	Vector3.new(MovementConstants.MaxPhysicsForce, MovementConstants.MaxPhysicsForce, MovementConstants.MaxPhysicsForce)

local DOWN = Vector3.new(0, -1, 0)
local UP = Vector3.new(0, 1, 0)

local SlideController = {}
SlideController.__index = SlideController

export type SlideController = typeof(setmetatable(
	{} :: {
		_connections: { RBXScriptConnection },
		_attachment: Attachment?,
		_velocity: LinearVelocity?,
		_steerConnection: RBXScriptConnection?,
		_rayParams: RaycastParams?,
	},
	SlideController
))

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

function SlideController.new(): SlideController
	local self = setmetatable({
		_connections = {},
		_attachment = nil,
		_velocity = nil,
		_steerConnection = nil,
		_rayParams = nil,
	}, SlideController)

	return self
end

-- Downward ray from the root part: returns the ground normal and its angle off vertical-up
-- (degrees), or nil, nil if nothing's within range (e.g. sliding off a ledge).
function SlideController._checkSlideSlope(self: SlideController, rootPart: BasePart): (Vector3?, number?)
	local result = workspace:Raycast(rootPart.Position, DOWN * MovementConstants.SlideGroundRayDistance, self._rayParams)
	if not result then
		return nil, nil
	end

	local slopeAngle = math.deg(math.acos(math.clamp(result.Normal:Dot(UP), -1, 1)))
	return result.Normal, slopeAngle
end

-- Reacts to Sliding ending for ANY reason -- naturally decaying to a stop, running off a ledge
-- into Falling, or a jump-cancel taking the FSM straight to Jumping -- so the velocity constraint
-- never keeps steering the character after some other controller has taken over.
function SlideController._stopPhysics(self: SlideController)
	if self._steerConnection then
		self._steerConnection:Disconnect()
		self._steerConnection = nil
	end
	if self._velocity then
		self._velocity.Enabled = false
	end

	requestSlide:FireServer(false)
end

function SlideController._beginSlide(self: SlideController, rootPart: BasePart)
	local velocity = self._velocity :: LinearVelocity
	velocity.MaxAxesForce = GROUND_LOCK_FORCE
	velocity.VectorVelocity = Vector3.zero
	velocity.Enabled = true

	requestSlide:FireServer(true)

	local currentMomentum = rootPart.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
	local speed = if currentMomentum.Magnitude > 0
		then currentMomentum.Magnitude * MovementConstants.SlideBoostMultiplier
		else MovementConstants.WalkSpeed * MovementConstants.SlideBoostMultiplier

	-- Qinggong Sprinting empowers this slide -- checked once here at entry, same "locked in at the
	-- moment of activation" shape as every other sprint-boosted ability.
	if SprintController:IsSprintActive() then
		speed *= MovementConstants.SprintSlideSpeedMultiplier
	end

	-- Primed true so the very first non-steep tick (e.g. starting a slide on flat ground) still
	-- computes a real decay rate below, instead of leaving decelPerSecond at its default of 0 and
	-- never decaying speed at all until a steep slope is encountered once.
	local wasSteep = true
	local wasFacingUphill = false
	local decelPerSecond = 0

	-- How long the ground has stayed non-steep -- once this reaches SlideFrictionDuration the
	-- slide ends. nil while currently steep (i.e. not counting).
	local flatSince: number? = nil

	-- Only honored once we've actually seen slide speed at least once: the constraint snaps
	-- VectorVelocity to zero the instant it's enabled, a frame before this loop sets the real
	-- boosted speed -- sampling that transient zero here would otherwise end the slide the moment
	-- it starts.
	local hasReachedSlideSpeed = false

	self._steerConnection = RunService.Heartbeat:Connect(function(dt: number)
		local groundNormal, slopeAngle = self:_checkSlideSlope(rootPart)
		local isSteep = slopeAngle ~= nil and slopeAngle >= MovementConstants.SlideSteepSlopeAngle

		-- Project our facing onto the ramp's surface so the forced velocity's vertical component
		-- matches the slope's actual grade instead of always being flat-horizontal -- a pure
		-- horizontal VectorVelocity would otherwise outrun gravity's ability to pull the character
		-- back onto a steep ramp each physics step, launching it a hair off the surface.
		local lookDir = rootPart.CFrame.LookVector
		local slideDir = lookDir
		local downhillDir: Vector3? = nil
		if groundNormal then
			local onSlope = lookDir - groundNormal * lookDir:Dot(groundNormal)
			if onSlope.Magnitude > 0.001 then
				slideDir = onSlope.Unit
			end
			local downOnSlope = DOWN - groundNormal * DOWN:Dot(groundNormal)
			if downOnSlope.Magnitude > 0.001 then
				downhillDir = downOnSlope.Unit
			end
			velocity.MaxAxesForce = FULL_LOCK_FORCE
		else
			velocity.MaxAxesForce = GROUND_LOCK_FORCE
		end

		-- Turning to face back uphill must not let the slide keep the downhill momentum it just
		-- built -- that's what would let a player ping-pong up and down a ramp, gaining more speed
		-- off SlideSlopeAcceleration each pass. Snap most of it away the instant the turn happens,
		-- then bleed the rest fast instead of the gentle flat-ground friction meant for slope exits.
		local facingUphill = downhillDir ~= nil and slideDir:Dot(downhillDir) < 0
		if facingUphill and not wasFacingUphill then
			speed *= MovementConstants.SlideUphillMomentumRetention
		end
		wasFacingUphill = facingUphill

		if facingUphill then
			speed = math.max(speed - MovementConstants.SlideUphillDeceleration * dt, 0)
			wasSteep = false
		elseif isSteep then
			speed = math.min(speed + MovementConstants.SlideSlopeAcceleration * dt, MovementConstants.SlideMaxSpeed)
			wasSteep = true
		else
			if wasSteep then
				decelPerSecond = (speed - MovementConstants.SlideFrictionFloorSpeed) / MovementConstants.SlideFrictionDuration
				wasSteep = false
			end
			speed = math.max(speed - decelPerSecond * dt, MovementConstants.SlideFrictionFloorSpeed)
		end

		velocity.VectorVelocity = slideDir * speed

		-- Exit conditions, checked off the same slope sample above instead of a second raycast.
		local horizontalSpeed = (rootPart.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude
		if horizontalSpeed >= MovementConstants.SlideStopSpeedThreshold then
			hasReachedSlideSpeed = true
		elseif hasReachedSlideSpeed then
			-- Fully stopped (e.g. killed by the uphill decel) -- exit immediately rather than
			-- waiting on the flat-ground timer below, which never fires while still on a steep slope.
			MovementController:RefreshMovementState()
			return
		end

		if isSteep then
			flatSince = nil
		else
			flatSince = flatSince or os.clock()
			if os.clock() - (flatSince :: number) >= MovementConstants.SlideFrictionDuration then
				MovementController:RefreshMovementState()
			end
		end
	end)
end

function SlideController._tryStartSlide(self: SlideController)
	local currentState = movementFSM:GetState()
	if currentState ~= MovementState.Running
		and currentState ~= MovementState.SprintCharging
		and currentState ~= MovementState.Sprinting
	then
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

	movementFSM:TransitionTo(MovementState.Sliding)
	self:_beginSlide(rootPart)
end

function SlideController._setupCharacter(self: SlideController, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	disconnectAll(self._connections)
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

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }
	self._rayParams = rayParams

	local attachment = Instance.new("Attachment")
	attachment.Name = "SlideAttachment"
	attachment.Parent = rootPart

	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "SlideVelocity"
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
			if oldState == MovementState.Sliding then
				self:_stopPhysics()
			end
		end)
	)

	table.insert(
		self._connections,
		humanoid.Died:Connect(function()
			disconnectAll(self._connections)
			if self._steerConnection then
				self._steerConnection:Disconnect()
				self._steerConnection = nil
			end
		end)
	)
end

function SlideController.Init(self: SlideController)
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

		self:_tryStartSlide()
	end)
end

return SlideController.new()
