--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage.Shared
local MovementState = require(Shared.Enums.MovementState)
local MovementConstants = require(Shared.Constants.MovementConstants)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local sampleSurfaceColor = require(Shared.Utils.SampleSurfaceColor)
local movementFSM = require(script.Parent.Parent.State.MovementFSM)
local MovementVFXTemplates = require(script.Parent.Parent.VFX.MovementVFXTemplates)
local QinggongVFXTemplates = require(script.Parent.Parent.VFX.QinggongVFXTemplates)

local player = Players.LocalPlayer

local LIMBS = { "Right Arm", "Left Arm", "Right Leg", "Left Leg" }
local FOOT_DUST_OFFSET = CFrame.new(0, -2, 0)
local DOUBLE_JUMP_VFX_OFFSET = CFrame.new(0, -2.5, 0)
-- R6 limbs are ~2 studs tall, origin at the vertical center -- this reaches down toward the
-- hand/foot end rather than the shoulder/hip end.
local WALL_CLING_DUST_LIMB_OFFSET = CFrame.new(0, -1, 0)
local SPRINT_VFX_OFFSET = CFrame.new(0, 0, -4)
local GROUND_CHECK_DISTANCE = 5
local DOWN = Vector3.new(0, -1, 0)
local BURST_VFX_EMIT_COUNT = 15
local BURST_VFX_CLEANUP_TIME = 2

local MovementVFXController = {}
MovementVFXController.__index = MovementVFXController

export type MovementVFXController = typeof(setmetatable(
	{} :: {
		_connections: { RBXScriptConnection },
		_activeDashTrailParts: { Instance },
		_activeDashDust: BasePart?,
		_activeSlideDust: BasePart?,
		_activeDoubleJumpTrailParts: { Instance },
		_activeWallClingDustParts: { Instance },
		_activeSprintVFX: BasePart?,
		_rayParams: RaycastParams?,
	},
	MovementVFXController
))

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function destroyAll(instances: { Instance })
	for _, instance in ipairs(instances) do
		instance:Destroy()
	end
	table.clear(instances)
end

function MovementVFXController.new(): MovementVFXController
	local self = setmetatable({
		_connections = {},
		_activeDashTrailParts = {},
		_activeDashDust = nil,
		_activeSlideDust = nil,
		_activeDoubleJumpTrailParts = {},
		_activeWallClingDustParts = {},
		_activeSprintVFX = nil,
		_rayParams = nil,
	}, MovementVFXController)

	return self
end

-- Shared by the dash trail and the double jump trail: clones a Trail + two Attachments onto every
-- limb, returning the spawned instances so the caller can track and later destroy them.
local function startLimbTrail(character: Model, trailTemplate: Trail?, attachment0Template: Attachment?, attachment1Template: Attachment?): { Instance }
	local parts: { Instance } = {}
	if not (trailTemplate and attachment0Template and attachment1Template) then
		return parts
	end

	for _, limbName in ipairs(LIMBS) do
		local limb = character:FindFirstChild(limbName)
		if limb then
			local attachment0 = attachment0Template:Clone()
			local attachment1 = attachment1Template:Clone()
			attachment0.Parent = limb
			attachment1.Parent = limb

			local trail = trailTemplate:Clone()
			trail.Attachment0 = attachment0
			trail.Attachment1 = attachment1
			trail.Parent = limb

			table.insert(parts, attachment0)
			table.insert(parts, attachment1)
			table.insert(parts, trail)
		end
	end

	return parts
end

function MovementVFXController._startDashTrail(self: MovementVFXController, character: Model)
	self._activeDashTrailParts = startLimbTrail(
		character,
		MovementVFXTemplates.DashTrailTrail,
		MovementVFXTemplates.DashTrailAttachment0,
		MovementVFXTemplates.DashTrailAttachment1
	)
end

function MovementVFXController._stopDashTrail(self: MovementVFXController)
	destroyAll(self._activeDashTrailParts)
end

function MovementVFXController._startDoubleJumpTrail(self: MovementVFXController, character: Model)
	self._activeDoubleJumpTrailParts = startLimbTrail(
		character,
		QinggongVFXTemplates.DoubleJumpTrailTrail,
		QinggongVFXTemplates.DoubleJumpTrailAttachment0,
		QinggongVFXTemplates.DoubleJumpTrailAttachment1
	)
end

function MovementVFXController._stopDoubleJumpTrail(self: MovementVFXController)
	destroyAll(self._activeDoubleJumpTrailParts)
end

-- Sampled off the wall actually being gripped (forward from the root part, same ray shape
-- WallClingController's own cling check uses) rather than the ground -- there isn't one underfoot
-- while hanging.
function MovementVFXController._sampleWallColor(self: MovementVFXController, rootPart: BasePart): Color3
	local rayResult = workspace:Raycast(
		rootPart.Position,
		rootPart.CFrame.LookVector * MovementConstants.WallClingDetectionRange,
		self._rayParams
	)
	return sampleSurfaceColor(rayResult)
end

-- Welds MovementDust to all four limbs for as long as WallHanging lasts -- the same asset the foot
-- dust above uses, just continuous instead of a one-shot burst, and tinted off the gripped wall
-- (sampled once for the whole cling) instead of the ground.
function MovementVFXController._startWallClingDust(self: MovementVFXController, character: Model, rootPart: BasePart)
	if #self._activeWallClingDustParts > 0 then
		return
	end

	local template = QinggongVFXTemplates.MovementDust
	local dustColor = ColorSequence.new(self:_sampleWallColor(rootPart))

	for _, limbName in ipairs(LIMBS) do
		local limb = character:FindFirstChild(limbName)
		if not limb then
			continue
		end

		local dustPart = template:Clone()
		dustPart.Anchored = false
		dustPart.CanCollide = false
		dustPart.CanQuery = false
		dustPart.Massless = true
		dustPart.CFrame = (limb :: BasePart).CFrame * WALL_CLING_DUST_LIMB_OFFSET
		dustPart.Parent = limb

		for _, descendant in ipairs(dustPart:GetDescendants()) do
			if descendant:IsA("ParticleEmitter") then
				descendant.Color = dustColor
			end
		end

		local weld = Instance.new("Weld")
		weld.Part0 = limb :: BasePart
		weld.Part1 = dustPart
		weld.C0 = WALL_CLING_DUST_LIMB_OFFSET
		weld.Parent = dustPart

		table.insert(self._activeWallClingDustParts, dustPart)
	end
end

function MovementVFXController._stopWallClingDust(self: MovementVFXController)
	destroyAll(self._activeWallClingDustParts)
end

-- Welded behind the HRP for as long as the Qinggong Sprinting technique is fully active (see
-- SprintController) -- a continuous wind trail, unlike the one-shot bursts above.
function MovementVFXController._startSprintVFX(self: MovementVFXController, rootPart: BasePart)
	if self._activeSprintVFX then
		return
	end

	local vfxPart = QinggongVFXTemplates.SprintVFX:Clone()
	vfxPart.Anchored = false
	vfxPart.CanCollide = false
	vfxPart.CanQuery = false
	vfxPart.Massless = true
	vfxPart.CFrame = rootPart.CFrame * SPRINT_VFX_OFFSET
	vfxPart.Parent = rootPart

	local weld = Instance.new("Weld")
	weld.Part0 = rootPart
	weld.Part1 = vfxPart
	weld.C0 = SPRINT_VFX_OFFSET
	weld.Parent = vfxPart

	self._activeSprintVFX = vfxPart
end

function MovementVFXController._stopSprintVFX(self: MovementVFXController)
	if self._activeSprintVFX then
		self._activeSprintVFX:Destroy()
		self._activeSprintVFX = nil
	end
end

-- One-shot burst left exactly where it's spawned (not welded to the character) -- used for the
-- Qinggong actions, which mark the spot they were activated from rather than following the
-- character as it moves away.
local function spawnBurstVFX(cframe: CFrame, template: BasePart?)
	if not template then
		return
	end

	local piece = template:Clone()
	piece.CFrame = cframe
	piece.Parent = workspace

	for _, descendant in ipairs(piece:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant:Emit(BURST_VFX_EMIT_COUNT)
		end
	end

	Debris:AddItem(piece, BURST_VFX_CLEANUP_TIME)
end

function MovementVFXController._sampleGroundColor(self: MovementVFXController, rootPart: BasePart): Color3
	local rayResult = workspace:Raycast(rootPart.Position, DOWN * GROUND_CHECK_DISTANCE, self._rayParams)
	return sampleSurfaceColor(rayResult)
end

function MovementVFXController._startFootDust(self: MovementVFXController, rootPart: BasePart, template: BasePart): BasePart
	local dustPart = template:Clone()
	dustPart.Anchored = false
	dustPart.CanCollide = false
	dustPart.CanQuery = false
	dustPart.Massless = true
	dustPart.CFrame = rootPart.CFrame * FOOT_DUST_OFFSET
	dustPart.Parent = rootPart

	local dustColor = ColorSequence.new(self:_sampleGroundColor(rootPart))
	for _, descendant in ipairs(dustPart:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Color = dustColor
		end
	end

	local weld = Instance.new("Weld")
	weld.Part0 = rootPart
	weld.Part1 = dustPart
	weld.C0 = FOOT_DUST_OFFSET
	weld.Parent = dustPart

	return dustPart
end

function MovementVFXController._stopAllVFX(self: MovementVFXController)
	self:_stopDashTrail()
	self:_stopDoubleJumpTrail()
	self:_stopWallClingDust()
	self:_stopSprintVFX()

	if self._activeDashDust then
		self._activeDashDust:Destroy()
		self._activeDashDust = nil
	end

	if self._activeSlideDust then
		self._activeSlideDust:Destroy()
		self._activeSlideDust = nil
	end
end

function MovementVFXController._onMovementStateChanged(self: MovementVFXController, character: Model, rootPart: BasePart, newState: string, oldState: string)
	local wasDashing = MovementConstants.DashingStates[oldState]
	local isDashing = MovementConstants.DashingStates[newState]

	if isDashing and not wasDashing then
		self:_startDashTrail(character)
		self._activeDashDust = self:_startFootDust(rootPart, MovementVFXTemplates.DashDust)
	elseif wasDashing and not isDashing then
		self:_stopDashTrail()
		if self._activeDashDust then
			self._activeDashDust:Destroy()
			self._activeDashDust = nil
		end
	end

	if newState == MovementState.Sliding then
		self._activeSlideDust = self:_startFootDust(rootPart, MovementVFXTemplates.SlideDust)
	elseif oldState == MovementState.Sliding and self._activeSlideDust then
		self._activeSlideDust:Destroy()
		self._activeSlideDust = nil
	end

	if newState == MovementState.DoubleJumping then
		self:_startDoubleJumpTrail(character)
		spawnBurstVFX(rootPart.CFrame * DOUBLE_JUMP_VFX_OFFSET, QinggongVFXTemplates.DoubleJumpVFX)
	elseif oldState == MovementState.DoubleJumping then
		self:_stopDoubleJumpTrail()
	end

	if newState == MovementState.AirDashing then
		spawnBurstVFX(rootPart.CFrame, QinggongVFXTemplates.AirDashVFX)
	elseif newState == MovementState.LedgeJumping then
		spawnBurstVFX(rootPart.CFrame, QinggongVFXTemplates.LedgeJumpVFX)
	elseif newState == MovementState.WallLeaping or newState == MovementState.WallClimbLeaping then
		-- Same burst prefab as WallRunning's own leap -- only the SFX differs between the two flavors.
		spawnBurstVFX(rootPart.CFrame, QinggongVFXTemplates.WallLeapVfx)
	end

	if newState == MovementState.WallHanging then
		self:_startWallClingDust(character, rootPart)
	elseif oldState == MovementState.WallHanging then
		self:_stopWallClingDust()
	end

	if newState == MovementState.Sprinting then
		self:_startSprintVFX(rootPart)
	elseif not MovementConstants.SprintCarryStates[newState] then
		self:_stopSprintVFX()
	end
end

function MovementVFXController._setupCharacter(self: MovementVFXController, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	disconnectAll(self._connections)
	self:_stopAllVFX()

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }
	self._rayParams = rayParams

	table.insert(
		self._connections,
		movementFSM.Changed:Connect(function(newState: string, oldState: string)
			self:_onMovementStateChanged(character, rootPart, newState, oldState)
		end)
	)

	table.insert(
		self._connections,
		humanoid.Died:Connect(function()
			disconnectAll(self._connections)
			self:_stopAllVFX()
		end)
	)
end

function MovementVFXController.Init(self: MovementVFXController)
	onCharacterAdded(player, function(character: Model)
		self:_setupCharacter(character)
	end)
end

return MovementVFXController.new()
