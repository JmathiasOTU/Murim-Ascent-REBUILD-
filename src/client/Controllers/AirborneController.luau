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

local requestLedgeJump = ReplicatedStorage.Remotes.RequestLedgeJump :: RemoteEvent

local player = Players.LocalPlayer

local AirborneController = {}
AirborneController.__index = AirborneController

export type AirborneController = typeof(setmetatable(
	{} :: {
		_connections: { RBXScriptConnection },
		_fallTrackingConnection: RBXScriptConnection?,
		_peakFallVelocity: number,
		_recoveryThread: thread?,
		_isAirborne: boolean,
		_takeoffHeight: number,
		_usedAerialAction: boolean,
		_rayParams: RaycastParams?,
	},
	AirborneController
))

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

-- A fixed forward+up launch, fully overwriting whatever velocity the slide/jump already had --
-- same one-shot-impulse shape as the other Qinggong actions.
local function applyLedgeJumpImpulse(rootPart: BasePart)
	local flatLook = rootPart.CFrame.LookVector * Vector3.new(1, 0, 1)
	local flatForward = if flatLook.Magnitude > 0.001 then flatLook.Unit else rootPart.CFrame.LookVector

	rootPart.AssemblyLinearVelocity = (flatForward * MovementConstants.LedgeJumpForwardPower)
		+ Vector3.new(0, MovementConstants.LedgeJumpUpPower, 0)
end

function AirborneController.new(): AirborneController
	local self = setmetatable({
		_connections = {},
		_fallTrackingConnection = nil,
		_peakFallVelocity = 0,
		_recoveryThread = nil,
		_isAirborne = false,
		_takeoffHeight = 0,
		_usedAerialAction = false,
		_rayParams = nil,
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

-- True only for a real edge (a slide carrying you off a ledge/cliff) -- not just "airborne while
-- sliding" over ground that keeps going, which should resolve to an ordinary Jumping instead.
function AirborneController._isAtLedgeEdge(self: AirborneController, rootPart: BasePart): boolean
	local forwardProjection = rootPart.Position + (rootPart.CFrame.LookVector * MovementConstants.LedgeJumpEdgeCheckForward)
	local downRay = workspace:Raycast(
		forwardProjection,
		Vector3.new(0, -MovementConstants.LedgeJumpEdgeCheckDown, 0),
		self._rayParams
	)
	return downRay == nil
end

function AirborneController._onLanded(self: AirborneController, rootPart: BasePart)
	self:_stopFallTracking()
	self:_cancelRecovery()

	local fallSpeed = -self._peakFallVelocity
	self._peakFallVelocity = 0

	local dropHeight = self._takeoffHeight - rootPart.Position.Y
	self._isAirborne = false

	-- The drop-height gate below only exists to filter out ordinary ground-level hops (jump, land
	-- back at ~takeoff height) -- it compares against the ORIGINAL takeoff point, not the highest
	-- point actually reached. A Qinggong action (air dash's camera-pitch boost, double jump's
	-- vertical pop) can carry the character above their own jump apex and back down to
	-- at-or-above takeoff height, netting a ~zero or negative dropHeight despite a genuinely hard
	-- fall (high fallSpeed) from that action-gained peak. Using an active ability mid-air is never
	-- an incidental hop, so once one's been used this excursion, judge landing hardness on
	-- fallSpeed alone.
	local usedAerialAction = self._usedAerialAction
	self._usedAerialAction = false

	if (not usedAerialAction and dropHeight < MovementConstants.MinLandingDropHeight) or fallSpeed < MovementConstants.LightLandingSpeedThreshold then
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
	self._isAirborne = false
	self._usedAerialAction = false

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }
	self._rayParams = rayParams

	table.insert(
		self._connections,
		humanoid.StateChanged:Connect(function(_oldState: Enum.HumanoidStateType, newState: Enum.HumanoidStateType)
			if newState == Enum.HumanoidStateType.Jumping then
				self:_cancelRecovery()
				local wasSliding = movementFSM:GetState() == MovementState.Sliding
				if not self._isAirborne then
					self._isAirborne = true
					self._takeoffHeight = rootPart.Position.Y
					self._usedAerialAction = false
				end
				-- A Qinggong action (air dash, double jump) owns the FSM for its fixed duration and
				-- resolves this same Jumping/Freefall split itself once it ends -- overwriting it
				-- here on the arc's natural Jumping<->Freefall flip (which the action's own velocity
				-- change can itself trigger) would cut its animation short.
				if not MovementConstants.QinggongActionStates[movementFSM:GetState()] then
					-- A slide running off a real edge (vs. jumping mid-slide over ground that keeps
					-- going) launches instead of just hopping -- LedgeJumping resolves through the
					-- ordinary Jumping->Freefall flow afterward like any other jump.
					if wasSliding and self:_isAtLedgeEdge(rootPart) then
						movementFSM:TransitionTo(MovementState.LedgeJumping)
						applyLedgeJumpImpulse(rootPart)
						requestLedgeJump:FireServer()
					else
						movementFSM:TransitionTo(MovementState.Jumping)
					end
				end
			elseif newState == Enum.HumanoidStateType.Freefall then
				self:_cancelRecovery()
				if not self._isAirborne then
					self._isAirborne = true
					self._takeoffHeight = rootPart.Position.Y
					self._usedAerialAction = false
				end
				if not MovementConstants.QinggongActionStates[movementFSM:GetState()] then
					movementFSM:TransitionTo(MovementState.Falling)
				end
				-- Guarded the same way as the Qinggong-action-triggered start below: if an action
				-- during the ascending Jumping phase already started tracking (and picked up real
				-- downward speed from the action itself), this natural Jumping->Freefall flip must
				-- not reset it back to 0 -- that would throw away everything captured so far right
				-- before the (often short) remaining drop to the ground.
				if not self._fallTrackingConnection then
					self:_startFallTracking(rootPart)
				end
			elseif newState == Enum.HumanoidStateType.Landed then
				self:_onLanded(rootPart)
			end
		end)
	)

	-- A Qinggong action's own impulse (e.g. air dash's downward camera-pitch component) can bring
	-- the character back to the ground fast enough that Humanoid never reports Freefall at all --
	-- start capturing peak fall speed the instant the action begins instead of waiting on that
	-- event, or a hard landing right after would always read as a soft one (fallSpeed stuck at its
	-- 0 reset value).
	table.insert(
		self._connections,
		movementFSM.Changed:Connect(function(newState: string)
			if MovementConstants.QinggongActionStates[newState] then
				self._usedAerialAction = true
				if not self._fallTrackingConnection then
					self:_startFallTracking(rootPart)
				end
			end
		end)
	)

	table.insert(
		self._connections,
		humanoid.Died:Connect(function()
			disconnectAll(self._connections)
			self:_stopFallTracking()
			self:_cancelRecovery()
			self._isAirborne = false
			self._usedAerialAction = false
		end)
	)
end

function AirborneController.Init(self: AirborneController)
	onCharacterAdded(player, function(character: Model)
		self:_setupCharacter(character)
	end)
end

return AirborneController.new()
