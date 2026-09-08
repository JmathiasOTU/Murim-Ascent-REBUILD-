--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local MovementState = require(Shared.Enums.MovementState)
local MovementConstants = require(Shared.Constants.MovementConstants)
local CameraConstants = require(Shared.Constants.CameraConstants)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local movementFSM = require(script.Parent.Parent.State.MovementFSM)
local SprintController = require(script.Parent.SprintController)
local WallRunController = require(script.Parent.WallRunController)

local player = Players.LocalPlayer

local BIND_NAME = "CameraLeanAndDip"
local MAX_LEAN_ANGLE = math.rad(CameraConstants.LeanMaxAngleDegrees)
local MAX_WALL_RUN_LEAN_ANGLE = math.rad(CameraConstants.WallRunLeanMaxAngleDegrees)

-- Sampled once at module load, same fallback pattern as below -- CurrentCamera may not exist yet
-- for a brand-new player at this exact moment.
local baseFOV = (Workspace.CurrentCamera and Workspace.CurrentCamera.FieldOfView) or CameraConstants.DefaultFOV

local CameraController = {}
CameraController.__index = CameraController

export type CameraController = typeof(setmetatable(
	{} :: {
		_connections: { RBXScriptConnection },
	},
	CameraController
))

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

-- Landing dip scales linearly with fall speed between the two thresholds -- below the min it's a
-- non-event (0 dip), at/above the max it's fully saturated.
local function landingDipForFallSpeed(fallSpeed: number): number
	if fallSpeed < CameraConstants.LandingDipMinFallSpeed then
		return 0
	end

	local span = CameraConstants.LandingDipMaxFallSpeed - CameraConstants.LandingDipMinFallSpeed
	local alpha = if span > 0
		then math.clamp((fallSpeed - CameraConstants.LandingDipMinFallSpeed) / span, 0, 1)
		else 1

	return CameraConstants.LandingDipMinDistance
		+ (CameraConstants.LandingDipMaxDistance - CameraConstants.LandingDipMinDistance) * alpha
end

function CameraController.new(): CameraController
	local self = setmetatable({
		_connections = {},
	}, CameraController)

	return self
end

function CameraController._setupCharacter(self: CameraController, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	RunService:UnbindFromRenderStep(BIND_NAME)
	disconnectAll(self._connections)

	local currentRoll = 0
	local currentDipOffset = 0
	local targetDipOffset = 0
	local currentCrouchOffset = 0
	local currentFovOffset = 0

	local peakFallVelocity = 0

	local dipHoldThread: thread? = nil
	local function triggerDip(distance: number)
		if distance <= 0 then
			return
		end

		targetDipOffset = distance
		if dipHoldThread then
			task.cancel(dipHoldThread)
		end
		dipHoldThread = task.delay(CameraConstants.LandingDipHoldTime, function()
			dipHoldThread = nil
			targetDipOffset = 0
		end)
	end

	table.insert(
		self._connections,
		movementFSM.Changed:Connect(function(newState: string, _oldState: string)
			if newState == MovementState.Jumping then
				triggerDip(CameraConstants.JumpDipDistance)
			elseif newState == MovementState.Falling then
				peakFallVelocity = 0
			end
		end)
	)

	table.insert(
		self._connections,
		humanoid.StateChanged:Connect(function(_oldState: Enum.HumanoidStateType, newState: Enum.HumanoidStateType)
			if newState == Enum.HumanoidStateType.Landed then
				triggerDip(landingDipForFallSpeed(-peakFallVelocity))
				peakFallVelocity = 0
			end
		end)
	)

	-- Runs one step after the engine's own camera update (Camera priority + 1) and multiplies onto
	-- whatever CFrame it already computed that frame, rather than overwriting it -- this stacks
	-- cleanly on top of the default/third-party camera script instead of fighting it.
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt: number)
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end

		if movementFSM:GetState() == MovementState.Falling then
			local verticalVelocity = rootPart.AssemblyLinearVelocity.Y
			if verticalVelocity < peakFallVelocity then
				peakFallVelocity = verticalVelocity
			end
		end

		-- Wall-run lean takes over from the strafe lean below whenever it's active (nonzero) --
		-- MoveDirection during a wall run just tracks residual forward input along the wall, not a
		-- real side-to-side strafe, so blending the two would fight rather than combine cleanly.
		local wallLeanAmount = WallRunController:GetWallLeanAmount()
		local targetRoll: number
		if wallLeanAmount ~= 0 then
			targetRoll = wallLeanAmount * MAX_WALL_RUN_LEAN_ANGLE
		else
			local moveDirection = humanoid.MoveDirection
			local strafeAmount = 0
			if moveDirection.Magnitude > CameraConstants.StrafeThreshold then
				strafeAmount = camera.CFrame.RightVector:Dot(moveDirection.Unit)
			end
			targetRoll = -strafeAmount * MAX_LEAN_ANGLE
		end

		local leanAlpha = 1 - math.exp(-CameraConstants.LeanSpeed * dt)
		currentRoll += (targetRoll - currentRoll) * leanAlpha

		local dipSpeed = if targetDipOffset ~= 0
			then CameraConstants.LandingDipAttackSpeed
			else CameraConstants.LandingDipRecoverySpeed
		local dipAlpha = 1 - math.exp(-dipSpeed * dt)
		currentDipOffset += (targetDipOffset - currentDipOffset) * dipAlpha

		local targetCrouchOffset = if MovementConstants.CrouchStates[movementFSM:GetState()]
			then CameraConstants.CrouchDistance
			else 0
		local crouchAlpha = 1 - math.exp(-CameraConstants.CrouchSpeed * dt)
		currentCrouchOffset += (targetCrouchOffset - currentCrouchOffset) * crouchAlpha

		camera.CFrame *= CFrame.Angles(0, 0, currentRoll) * CFrame.new(0, -(currentDipOffset + currentCrouchOffset), 0)

		local targetFovOffset = SprintController:GetSprintTarget() * CameraConstants.SprintFovBoost
		local fovAlpha = 1 - math.exp(-CameraConstants.SprintFovSpeed * dt)
		currentFovOffset += (targetFovOffset - currentFovOffset) * fovAlpha
		camera.FieldOfView = baseFOV + currentFovOffset
	end)

	table.insert(
		self._connections,
		humanoid.Died:Connect(function()
			RunService:UnbindFromRenderStep(BIND_NAME)
			disconnectAll(self._connections)
			if dipHoldThread then
				task.cancel(dipHoldThread)
				dipHoldThread = nil
			end
		end)
	)
end

function CameraController.Init(self: CameraController)
	onCharacterAdded(player, function(character: Model)
		self:_setupCharacter(character)
	end)
end

return CameraController.new()
