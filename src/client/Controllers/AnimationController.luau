--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local MovementState = require(Shared.Enums.MovementState)
local MovementConstants = require(Shared.Constants.MovementConstants)
local AnimationConstants = require(Shared.Constants.AnimationConstants)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local getHumanoidAndRoot = require(Shared.Utils.GetHumanoidAndRoot)
local classifyDirection8 = require(Shared.Utils.ClassifyDirection8)
local classifyDashDirection = require(Shared.Utils.ClassifyDashDirection)
local movementFSM = require(script.Parent.Parent.State.MovementFSM)
local MovementAnimations = require(script.Parent.Parent.Animation.MovementAnimations)
local QinggongAnimations = require(script.Parent.Parent.Animation.QinggongAnimations)
local DirectionalWalkAnimations = require(script.Parent.Parent.Animation.DirectionalWalkAnimations)
local DashAnimations = require(script.Parent.Parent.Animation.DashAnimations)
local DodgeCancelAnimations = require(script.Parent.Parent.Animation.DodgeCancelAnimations)

local player = Players.LocalPlayer

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
	for state, animation in pairs(QinggongAnimations) do
		local track = animator:LoadAnimation(animation)
		track.Looped = false
		track.Priority = Enum.AnimationPriority.Action
		tracks[state] = track
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

function AnimationController._enterDodgeCancelling(self: AnimationController)
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

	track:Play(AnimationConstants.DashFadeInTime)
	self._activeDodgeCancelTrack = track
end

function AnimationController._exitDodgeCancelling(self: AnimationController)
	if self._activeDodgeCancelTrack then
		self._activeDodgeCancelTrack:Stop(AnimationConstants.DashFadeOutTime)
		self._activeDodgeCancelTrack = nil
	end
end

function AnimationController._onMovementStateChanged(self: AnimationController, newState: string, oldState: string)
	if oldState == MovementState.Walking then
		self:_exitWalking()
	elseif MovementConstants.DashingStates[oldState] then
		self:_exitDashing()
	elseif oldState == MovementState.DodgeCancelling then
		self:_exitDodgeCancelling()
	elseif MovementConstants.QinggongAnimationStates[oldState] then
		-- LedgeJumping isn't a QinggongActionState -- it hands off to Falling the instant the jump
		-- arc naturally does, same as an ordinary jump, and that's correct. But the one-shot launch
		-- clip shouldn't get cut off a fraction of a second in just because the FSM label changed
		-- underneath it -- let it keep playing (it'll stop itself, Looped = false) and rely on its
		-- higher Action priority to still read correctly over whatever Falling plays underneath.
		if not (oldState == MovementState.LedgeJumping and newState == MovementState.Falling) then
			local oldTrack = self._tracks[oldState]
			if oldTrack then
				oldTrack:Stop(AnimationConstants.DashFadeOutTime)
			end
		end
	else
		local oldTrack = self._tracks[oldState]
		if oldTrack then
			oldTrack:Stop(AnimationConstants.FadeTime)
		end
	end

	if newState == MovementState.Walking then
		self:_enterWalking()
	elseif MovementConstants.DashingStates[newState] then
		self:_enterDashing()
	elseif newState == MovementState.DodgeCancelling then
		self:_enterDodgeCancelling()
	elseif MovementConstants.QinggongAnimationStates[newState] then
		local newTrack = self._tracks[newState]
		if newTrack then
			newTrack:Play(AnimationConstants.DashFadeInTime)
		end
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
end

return AnimationController.new()
