--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local MovementState = require(Shared.Enums.MovementState)
local AnimationConstants = require(Shared.Constants.AnimationConstants)
local MovementConstants = require(Shared.Constants.MovementConstants)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local getHumanoidAndRoot = require(Shared.Utils.GetHumanoidAndRoot)
local classifyDirection8 = require(Shared.Utils.ClassifyDirection8)
local movementFSM = require(script.Parent.Parent.State.MovementFSM)
local MovementAnimations = require(script.Parent.Parent.Animation.MovementAnimations)
local DirectionalWalkAnimations = require(script.Parent.Parent.Animation.DirectionalWalkAnimations)
local DashAnimations = require(script.Parent.Parent.Animation.DashAnimations)
local DodgeCancelAnimations = require(script.Parent.Parent.Animation.DodgeCancelAnimations)
local DashSignals = require(script.Parent.Parent.State.DashSignals)

local player = Players.LocalPlayer

-- Dominant-axis 4-way split (not the 8-sector ClassifyDirection8 used for walking) -- matches how
-- the old dash picked between its four directional clips. Defaults to "Back" with no input, which
-- lines up with DashController's own no-input fallback of dashing backward (-LookVector).
local function classifyDashDirection(moveDirection: Vector3, lookVector: Vector3, rightVector: Vector3): string
	if moveDirection.Magnitude <= MovementConstants.DashSteerDeadzone then
		return "Back"
	end

	local forwardDot = moveDirection:Dot(lookVector)
	local rightDot = moveDirection:Dot(rightVector)

	if math.abs(forwardDot) > math.abs(rightDot) then
		return if forwardDot > 0 then "Front" else "Back"
	end
	return if rightDot > 0 then "Right" else "Left"
end

local AnimationController = {}
AnimationController.__index = AnimationController

export type AnimationController = typeof(setmetatable(
	{} :: {
		_tracks: { [string]: AnimationTrack },
		_walkTracks: { [string]: AnimationTrack },
		_activeWalkTrack: AnimationTrack?,
		_walkDirectionConnection: RBXScriptConnection?,
		_dashTracks: { [string]: AnimationTrack },
		_activeDashTrack: AnimationTrack?,
		_dodgeCancelTracks: { [string]: AnimationTrack },
		_activeDodgeCancelTrack: AnimationTrack?,
	},
	AnimationController
))

function AnimationController.new(): AnimationController
	local self = setmetatable({
		_tracks = {},
		_walkTracks = {},
		_activeWalkTrack = nil,
		_walkDirectionConnection = nil,
		_dashTracks = {},
		_activeDashTrack = nil,
		_dodgeCancelTracks = {},
		_activeDodgeCancelTrack = nil,
	}, AnimationController)

	return self
end

function AnimationController._setupCharacter(self: AnimationController, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local animator = humanoid:WaitForChild("Animator") :: Animator

	local animateScript = character:FindFirstChild("Animate")
	if animateScript then
		animateScript.Enabled = false
	end

	if self._walkDirectionConnection then
		self._walkDirectionConnection:Disconnect()
		self._walkDirectionConnection = nil
	end

	local tracks: { [string]: AnimationTrack } = {}
	for state, animation in pairs(MovementAnimations) do
		tracks[state] = animator:LoadAnimation(animation)
	end
	self._tracks = tracks

	local walkTracks: { [string]: AnimationTrack } = {}
	for direction, animation in pairs(DirectionalWalkAnimations) do
		walkTracks[direction] = animator:LoadAnimation(animation)
	end
	self._walkTracks = walkTracks
	self._activeWalkTrack = nil

	local dashTracks: { [string]: AnimationTrack } = {}
	for direction, animation in pairs(DashAnimations) do
		local track = animator:LoadAnimation(animation)
		track.Looped = false
		track.Priority = Enum.AnimationPriority.Action
		dashTracks[direction] = track
	end
	self._dashTracks = dashTracks
	self._activeDashTrack = nil

	local dodgeCancelTracks: { [string]: AnimationTrack } = {}
	for side, animation in pairs(DodgeCancelAnimations) do
		local track = animator:LoadAnimation(animation)
		track.Looped = false
		track.Priority = Enum.AnimationPriority.Action
		dodgeCancelTracks[side] = track
	end
	self._dodgeCancelTracks = dodgeCancelTracks
	self._activeDodgeCancelTrack = nil

	local currentTrack = tracks[movementFSM:GetState()]
	if currentTrack then
		currentTrack:Play(AnimationConstants.FadeTime)
	end
end

function AnimationController._updateWalkDirection(self: AnimationController)
	local humanoid, rootPart = getHumanoidAndRoot(player.Character)
	if not humanoid or not rootPart then
		return
	end

	local moveDirection = humanoid.MoveDirection
	if moveDirection.Magnitude <= 0 then
		return
	end

	local direction = classifyDirection8(moveDirection, rootPart.CFrame.LookVector, rootPart.CFrame.RightVector)
	local nextTrack = self._walkTracks[direction]
	if not nextTrack or nextTrack == self._activeWalkTrack then
		return
	end

	if self._activeWalkTrack then
		self._activeWalkTrack:Stop(AnimationConstants.FadeTime)
	end
	nextTrack:Play(AnimationConstants.FadeTime)
	self._activeWalkTrack = nextTrack
end

function AnimationController._enterWalking(self: AnimationController)
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	self:_updateWalkDirection()
	self._walkDirectionConnection = humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(function()
		self:_updateWalkDirection()
	end)
end

function AnimationController._exitWalking(self: AnimationController)
	if self._walkDirectionConnection then
		self._walkDirectionConnection:Disconnect()
		self._walkDirectionConnection = nil
	end

	if self._activeWalkTrack then
		self._activeWalkTrack:Stop(AnimationConstants.FadeTime)
		self._activeWalkTrack = nil
	end
end

function AnimationController._enterDashing(self: AnimationController)
	local humanoid, rootPart = getHumanoidAndRoot(player.Character)
	if not humanoid or not rootPart then
		return
	end

	local direction = classifyDashDirection(humanoid.MoveDirection, rootPart.CFrame.LookVector, rootPart.CFrame.RightVector)
	local track = self._dashTracks[direction]
	if not track then
		return
	end

	track:Play(AnimationConstants.DashFadeInTime)
	self._activeDashTrack = track
end

function AnimationController._exitDashing(self: AnimationController)
	if self._activeDashTrack then
		self._activeDashTrack:Stop(AnimationConstants.DashFadeOutTime)
		self._activeDashTrack = nil
	end
end

-- Left/Right picked directly when strafing; a forward/backward (or no-input) cancel has no
-- matching clip of its own, so it picks a side at random -- matches the old dash's fallback.
function AnimationController._playDodgeCancel(self: AnimationController)
	local humanoid, rootPart = getHumanoidAndRoot(player.Character)
	if not humanoid or not rootPart then
		return
	end

	local direction = classifyDashDirection(humanoid.MoveDirection, rootPart.CFrame.LookVector, rootPart.CFrame.RightVector)
	local side = if direction == "Left" then "Left"
		elseif direction == "Right" then "Right"
		elseif math.random(1, 2) == 1 then "Left"
		else "Right"

	local track = self._dodgeCancelTracks[side]
	if not track then
		return
	end

	if self._activeDodgeCancelTrack then
		self._activeDodgeCancelTrack:Stop(0)
	end

	track:Play(AnimationConstants.DashFadeInTime)
	self._activeDodgeCancelTrack = track

	track.Stopped:Once(function()
		if self._activeDodgeCancelTrack == track then
			self._activeDodgeCancelTrack = nil
		end
	end)
end

function AnimationController._onMovementStateChanged(self: AnimationController, newState: string, oldState: string)
	if oldState == MovementState.Walking then
		self:_exitWalking()
	elseif oldState == MovementState.Dashing then
		self:_exitDashing()
	else
		local oldTrack = self._tracks[oldState]
		if oldTrack then
			oldTrack:Stop(AnimationConstants.FadeTime)
		end
	end

	if newState == MovementState.Walking then
		self:_enterWalking()
	elseif newState == MovementState.Dashing then
		self:_enterDashing()
	else
		local newTrack = self._tracks[newState]
		if newTrack then
			newTrack:Play(AnimationConstants.FadeTime)
		end
	end
end

function AnimationController.Init(self: AnimationController)
	onCharacterAdded(player, function(character: Model)
		self:_setupCharacter(character)
	end)

	movementFSM.Changed:Connect(function(newState: string, oldState: string)
		self:_onMovementStateChanged(newState, oldState)
	end)

	DashSignals.Cancelled:Connect(function()
		self:_playDodgeCancel()
	end)
end

return AnimationController.new()
