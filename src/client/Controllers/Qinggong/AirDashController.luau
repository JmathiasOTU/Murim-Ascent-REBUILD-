--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local MovementState = require(Shared.Enums.MovementState)
local MovementConstants = require(Shared.Constants.MovementConstants)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local hasEnoughQinggong = require(Shared.Utils.HasEnoughQinggong)
local movementFSM = require(script.Parent.Parent.Parent.State.MovementFSM)
local MovementController = require(script.Parent.Parent.Movement.MovementController)

local requestAirDash = ReplicatedStorage.Remotes.RequestAirDash :: RemoteEvent

local player = Players.LocalPlayer

local AirDashController = {}
AirDashController.__index = AirDashController

export type AirDashController = typeof(setmetatable(
	{} :: {
		_connections: { RBXScriptConnection },
		_rayParams: RaycastParams?,
		_lastAirDashTime: number,
		_dashEndThread: thread?,
	},
	AirDashController
))

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

function AirDashController.new(): AirDashController
	local self = setmetatable({
		_connections = {},
		_rayParams = nil,
		_lastAirDashTime = -math.huge,
		_dashEndThread = nil,
	}, AirDashController)

	return self
end

function AirDashController._cancelDashEndThread(self: AirDashController)
	if self._dashEndThread then
		task.cancel(self._dashEndThread)
		self._dashEndThread = nil
	end
end

-- One-shot impulse in the direction the character is facing (flattened), angled up/down by camera
-- pitch -- unlike the grounded dash there's no held velocity constraint or mid-flight steering;
-- gravity and normal falling physics simply take back over right after.
function AirDashController._applyImpulse(self: AirDashController, rootPart: BasePart)
	local camera = Workspace.CurrentCamera
	local cameraPitch = if camera then camera.CFrame.LookVector.Y else 0

	local lookVector = rootPart.CFrame.LookVector
	local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)
	local flatForward = if flatLook.Magnitude > 0.001 then flatLook.Unit else lookVector

	local forwardVelocity = flatForward * MovementConstants.AirDashSpeed
	local verticalVelocity = Vector3.new(0, cameraPitch * MovementConstants.AirDashSpeed * MovementConstants.AirDashVerticalMult, 0)
	local launchVelocity = forwardVelocity + verticalVelocity

	-- Cast along flatForward (the actual travel direction) rather than the raw LookVector -- any
	-- residual pitch on the root part (e.g. leftover from a slope/ramp) would otherwise aim this ray
	-- somewhere the dash isn't even going. Also only softens against an actual wall (steep surface),
	-- same threshold WallRun/WallCling use for "is this a wall" -- without it, a shallow floor/ramp
	-- lip within the short softening range reads as a wall and kills the whole dash for no reason.
	local wallHit = Workspace:Raycast(rootPart.Position, flatForward * MovementConstants.AirDashWallSoftenRange, self._rayParams)
	if wallHit and math.abs(wallHit.Normal.Y) < MovementConstants.WallFlatnessThreshold then
		-- Project out only the into-wall component instead of zeroing the whole impulse, so a
		-- glancing dash still carries you past the wall rather than stopping dead against it.
		local intoWall = launchVelocity:Dot(wallHit.Normal)
		if intoWall < 0 then
			launchVelocity -= wallHit.Normal * intoWall
		end
	end

	rootPart.AssemblyLinearVelocity = launchVelocity
end

function AirDashController._tryAirDash(self: AirDashController, humanoid: Humanoid, rootPart: BasePart)
	local currentState = movementFSM:GetState()
	if currentState ~= MovementState.Jumping and currentState ~= MovementState.Falling then
		return
	end

	local now = os.clock()
	if now - self._lastAirDashTime < MovementConstants.AirDashCooldown then
		return
	end

	if not hasEnoughQinggong(MovementConstants.QinggongCostAirDash) then
		return
	end
	self._lastAirDashTime = now

	movementFSM:TransitionTo(MovementState.AirDashing)
	requestAirDash:FireServer()
	self:_applyImpulse(rootPart)

	self:_cancelDashEndThread()
	self._dashEndThread = task.delay(MovementConstants.AirDashDuration, function()
		self._dashEndThread = nil
		if movementFSM:GetState() ~= MovementState.AirDashing then
			return
		end

		-- The underlying Humanoid state was never changed (only the FSM was, to play the dash
		-- animation over it), so it still reads Jumping/Freefall from the arc the dash interrupted --
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

function AirDashController._setupCharacter(self: AirDashController, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	disconnectAll(self._connections)
	self:_cancelDashEndThread()
	self._lastAirDashTime = -math.huge

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }
	self._rayParams = rayParams

	table.insert(
		self._connections,
		humanoid.Died:Connect(function()
			disconnectAll(self._connections)
			self:_cancelDashEndThread()
		end)
	)
end

function AirDashController.Init(self: AirDashController)
	onCharacterAdded(player, function(character: Model)
		self:_setupCharacter(character)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
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

		self:_tryAirDash(humanoid, rootPart)
	end)
end

return AirDashController.new()
