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

local requestSprintTechnique = ReplicatedStorage.Remotes.RequestSprintTechnique :: RemoteEvent

local player = Players.LocalPlayer

local SprintController = {}
SprintController.__index = SprintController

export type SprintController = typeof(setmetatable(
	{} :: {
		_connections: { RBXScriptConnection },
		_rampConnection: RBXScriptConnection?,
		_runHoldStartTime: number?,
		_chargeStartTime: number?,
		-- 0 = no sprint boost at all, 0..1 = ramping (SprintCharging), 1 = fully sprinting or
		-- carrying that boost through one of MovementConstants.SprintCarryStates.
		_sprintIntensity: number,
	},
	SprintController
))

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

function SprintController.new(): SprintController
	local self = setmetatable({
		_connections = {},
		_rampConnection = nil,
		_runHoldStartTime = nil,
		_chargeStartTime = nil,
		_sprintIntensity = 0,
	}, SprintController)

	return self
end

-- 0..1 ramp progress / carried-boost level -- read by CameraController (FOV) and
-- MovementSoundController (wind volume) every frame to track the charge continuously.
function SprintController.GetSprintTarget(self: SprintController): number
	return self._sprintIntensity
end

-- Hard on/off for the cross-ability empowerment (Slide/WallRun/WallBoost/WallClimbLeap/LedgeJump) --
-- true only once the ramp has fully completed (or that completion is being carried through a
-- jump/slide/wall-parkour chain), never mid-ramp.
function SprintController.IsSprintActive(self: SprintController): boolean
	return self._sprintIntensity >= 1
end

function SprintController._isRunQualified(_self: SprintController, humanoid: Humanoid): boolean
	return MovementController:IsSprintKeyHeld() and humanoid.MoveDirection.Magnitude > 0
end

function SprintController._beginCharging(self: SprintController)
	self._runHoldStartTime = nil
	self._chargeStartTime = os.clock()
	movementFSM:TransitionTo(MovementState.SprintCharging)
end

function SprintController._completeSprint(self: SprintController)
	self._sprintIntensity = 1
	movementFSM:TransitionTo(MovementState.Sprinting)
	requestSprintTechnique:FireServer(true)
end

-- Called the instant the player is no longer "run qualified" (stopped moving or let go of the run
-- key) while charging or fully sprinting -- hands control back to ordinary ground-state resolution,
-- which will land on Walking or Idle (never back on Running/Sprinting, since both require the exact
-- qualification that just failed) and, via the Changed listener below, zero the intensity.
function SprintController._endSprint(self: SprintController)
	local wasFullySprinting = movementFSM:GetState() == MovementState.Sprinting
	self._chargeStartTime = nil
	if wasFullySprinting then
		requestSprintTechnique:FireServer(false)
	end
	MovementController:RefreshMovementState()
end

function SprintController._setupCharacter(self: SprintController, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	disconnectAll(self._connections)
	if self._rampConnection then
		self._rampConnection:Disconnect()
		self._rampConnection = nil
	end
	self._runHoldStartTime = nil
	self._chargeStartTime = nil
	self._sprintIntensity = 0

	self._rampConnection = RunService.Heartbeat:Connect(function()
		local state = movementFSM:GetState()

		if state == MovementState.Running then
			if not self._runHoldStartTime then
				self._runHoldStartTime = os.clock()
			elseif os.clock() - (self._runHoldStartTime :: number) >= MovementConstants.SprintHoldDuration then
				self:_beginCharging()
			end
			return
		end
		self._runHoldStartTime = nil

		if state == MovementState.SprintCharging then
			if not self:_isRunQualified(humanoid) then
				self:_endSprint()
				return
			end

			local rampAlpha =
				math.clamp((os.clock() - (self._chargeStartTime :: number)) / MovementConstants.SprintRampDuration, 0, 1)
			self._sprintIntensity = rampAlpha
			humanoid.WalkSpeed = MovementConstants.RunSpeed + (MovementConstants.SprintSpeed - MovementConstants.RunSpeed) * rampAlpha

			if rampAlpha >= 1 then
				self:_completeSprint()
			end
		elseif state == MovementState.Sprinting then
			if not self:_isRunQualified(humanoid) then
				self:_endSprint()
				return
			end
			humanoid.WalkSpeed = MovementConstants.SprintSpeed
		end
	end)

	table.insert(
		self._connections,
		movementFSM.Changed:Connect(function(newState: string, _oldState: string)
			if newState == MovementState.Sprinting then
				self._sprintIntensity = 1
			elseif not MovementConstants.SprintCarryStates[newState] then
				self._sprintIntensity = 0
			end
		end)
	)

	table.insert(
		self._connections,
		humanoid.Died:Connect(function()
			disconnectAll(self._connections)
			if self._rampConnection then
				self._rampConnection:Disconnect()
				self._rampConnection = nil
			end
			self._runHoldStartTime = nil
			self._chargeStartTime = nil
			self._sprintIntensity = 0
		end)
	)
end

function SprintController.Init(self: SprintController)
	onCharacterAdded(player, function(character: Model)
		self:_setupCharacter(character)
	end)

	-- Lets MovementController's ground-state resolution (used everywhere it hands control back --
	-- landing, a slide/wall-run/wall-leap ending, releasing the run key) upgrade straight to
	-- Sprinting instead of Running when a carried boost is still active, instead of forcing a fresh
	-- charge every time some other ability briefly interrupts it. Injected as a callback (rather than
	-- MovementController requiring this module) to avoid a require cycle -- SprintController already
	-- needs to call back into MovementController for RefreshMovementState/IsSprintKeyHeld.
	MovementController:SetSprintQuery(function()
		return self:IsSprintActive()
	end)
end

return SprintController.new()
