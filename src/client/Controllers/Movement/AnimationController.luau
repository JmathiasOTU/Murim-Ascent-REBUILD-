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
local movementFSM = require(script.Parent.Parent.Parent.State.MovementFSM)
local MovementAnimations = require(script.Parent.Parent.Parent.Animation.Movement.MovementAnimations)
local QinggongAnimations = require(script.Parent.Parent.Parent.Animation.Qinggong.QinggongAnimations)
local DirectionalWalkAnimations = require(script.Parent.Parent.Parent.Animation.Movement.DirectionalWalkAnimations)
local DashAnimations = require(script.Parent.Parent.Parent.Animation.Movement.DashAnimations)
local DodgeCancelAnimations = require(script.Parent.Parent.Parent.Animation.Movement.DodgeCancelAnimations)
local WallRunAnimations = require(script.Parent.Parent.Parent.Animation.Qinggong.WallRunAnimations)
local WallClimbAnimations = require(script.Parent.Parent.Parent.Animation.Qinggong.WallClimbAnimations)
local SprintAnimation = require(script.Parent.Parent.Parent.Animation.Movement.SprintAnimation)

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
		_wallRunTracks: { [string]: AnimationTrack },
		_activeWallRunTrack: AnimationTrack?,
		_wallClimbTracks: { [string]: AnimationTrack },
		_activeWallClimbTrack: AnimationTrack?,
		_rayParams: RaycastParams?,
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
		_wallRunTracks = {},
		_activeWallRunTrack = nil,
		_wallClimbTracks = {},
		_activeWallClimbTrack = nil,
		_rayParams = nil,
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

	-- Loaded directly into the generic table (not QinggongAnimations, which forces one-shot/Action
	-- above) since this is a sustained loop, same treatment as WallHanging's own loop.
	local sprintTrack = animator:LoadAnimation(SprintAnimation)
	sprintTrack.Looped = true
	sprintTrack.Priority = Enum.AnimationPriority.Movement
	tracks[MovementState.Sprinting] = sprintTrack

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

	local wallRunTracks: { [string]: AnimationTrack } = {}
	for name, animation in pairs(WallRunAnimations) do
		local track = animator:LoadAnimation(animation)
		local isLeap = name == "WallLeapLeft" or name == "WallLeapRight"
		track.Looped = not isLeap
		track.Priority = if isLeap then Enum.AnimationPriority.Action else Enum.AnimationPriority.Movement
		wallRunTracks[name] = track
	end
	self._wallRunTracks = wallRunTracks
	self._activeWallRunTrack = nil

	local wallClimbTracks: { [string]: AnimationTrack } = {}
	for name, animation in pairs(WallClimbAnimations) do
		local track = animator:LoadAnimation(animation)
		-- WallHanging is the sustained cling pose -- everything else here (WallBoost,
		-- WallClingDoubleJump, and WallLatch layered on top of the hang) is a one-shot.
		track.Looped = name == MovementState.WallHanging
		track.Priority = Enum.AnimationPriority.Movement
		wallClimbTracks[name] = track
	end
	self._wallClimbTracks = wallClimbTracks
	self._activeWallClimbTrack = nil

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }
	self._rayParams = rayParams

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

-- Which side the wall is actually on -- same side-raycast shape WallRunController itself checks,
-- read independently here purely to pick the mirrored clip.
function AnimationController._sideRaycastHitsRight(self: AnimationController, rootPart: BasePart, rayLength: number): boolean
	local rightRay = workspace:Raycast(rootPart.Position, rootPart.CFrame.RightVector * rayLength, self._rayParams)
	return rightRay ~= nil
end

function AnimationController._enterWallRunning(self: AnimationController)
	local humanoid, rootPart = getHumanoidAndRoot(player.Character)
	if not humanoid or not rootPart then
		return
	end

	local isRight = self:_sideRaycastHitsRight(rootPart, MovementConstants.WallSideRayDistance)
	local track = self._wallRunTracks[if isRight then "WallRunRight" else "WallRunLeft"]
	if not track then
		return
	end

	track:Play(AnimationConstants.DashFadeInTime)
	self._activeWallRunTrack = track
end

function AnimationController._enterWallLeaping(self: AnimationController)
	local humanoid, rootPart = getHumanoidAndRoot(player.Character)
	if not humanoid or not rootPart then
		return
	end

	local isRight = self:_sideRaycastHitsRight(rootPart, MovementConstants.WallLeapRayLength)
	local track = self._wallRunTracks[if isRight then "WallLeapRight" else "WallLeapLeft"]
	if not track then
		return
	end

	track:Play(AnimationConstants.DashFadeInTime)
	self._activeWallRunTrack = track
end

function AnimationController._exitWallRunOrLeap(self: AnimationController)
	if self._activeWallRunTrack then
		self._activeWallRunTrack:Stop(AnimationConstants.DashFadeOutTime)
		self._activeWallRunTrack = nil
	end
end

-- WallLatch is a one-shot impact layered on top of the sustained WallHanging loop at the moment of
-- latching on, both playing simultaneously on the same Animator.
function AnimationController._enterWallHanging(self: AnimationController)
	local hangTrack = self._wallClimbTracks[MovementState.WallHanging]
	if hangTrack then
		hangTrack:Play(AnimationConstants.FadeTime)
	end

	local latchTrack = self._wallClimbTracks.WallLatch
	if latchTrack then
		latchTrack:Play(AnimationConstants.DashFadeInTime)
	end
end

function AnimationController._exitWallHanging(self: AnimationController)
	local hangTrack = self._wallClimbTracks[MovementState.WallHanging]
	if hangTrack then
		hangTrack:Stop(AnimationConstants.FadeTime)
	end

	-- Stopped defensively in case it's somehow still playing (safe no-op otherwise, since it's a
	-- short one-shot that normally finishes on its own).
	local latchTrack = self._wallClimbTracks.WallLatch
	if latchTrack then
		latchTrack:Stop(AnimationConstants.FadeTime)
	end
end

function AnimationController._enterWallBoost(self: AnimationController)
	local track = self._wallClimbTracks[MovementState.WallBoost]
	if not track then
		return
	end

	track:Play(AnimationConstants.DashFadeInTime)
	self._activeWallClimbTrack = track
end

function AnimationController._enterWallClingDoubleJump(self: AnimationController)
	local track = self._wallClimbTracks[MovementState.WallClingDoubleJump]
	if not track then
		return
	end

	track:Play(AnimationConstants.DashFadeInTime)
	self._activeWallClimbTrack = track
end

-- No dedicated leap-off clip exists for this -- reuses WallBoost's push-off-the-wall pose, the
-- closest visual match on hand.
function AnimationController._enterWallClimbLeaping(self: AnimationController)
	local track = self._wallClimbTracks[MovementState.WallBoost]
	if not track then
		return
	end

	track:Play(AnimationConstants.DashFadeInTime)
	self._activeWallClimbTrack = track
end

function AnimationController._exitWallClimbAction(self: AnimationController)
	if self._activeWallClimbTrack then
		self._activeWallClimbTrack:Stop(AnimationConstants.DashFadeOutTime)
		self._activeWallClimbTrack = nil
	end
end

function AnimationController._onMovementStateChanged(self: AnimationController, newState: string, oldState: string)
	-- The Qinggong Sprinting technique's hold-gate (see SprintController) starts the moment Running
	-- has already been playing for a while -- nothing should visibly change yet, so Running's track
	-- is deliberately left running through the whole charge instead of being stopped/restarted here.
	if oldState == MovementState.Running and newState == MovementState.SprintCharging then
		return
	end

	if oldState == MovementState.Walking then
		self:_exitWalking()
	elseif MovementConstants.DashingStates[oldState] then
		self:_exitDashing()
	elseif oldState == MovementState.DodgeCancelling then
		self:_exitDodgeCancelling()
	elseif oldState == MovementState.WallRunning or oldState == MovementState.WallLeaping then
		self:_exitWallRunOrLeap()
	elseif oldState == MovementState.WallHanging then
		self:_exitWallHanging()
	elseif oldState == MovementState.SprintCharging then
		-- Leaving the charge for any reason (completed into Sprinting, or interrupted early by a
		-- jump/slide/etc.) -- the Running track kept alive above finally gets stopped here, exactly
		-- once, regardless of which of those it was.
		local runningTrack = self._tracks[MovementState.Running]
		if runningTrack then
			runningTrack:Stop(AnimationConstants.FadeTime)
		end
	elseif oldState == MovementState.WallBoost
		or oldState == MovementState.WallClingDoubleJump
		or oldState == MovementState.WallClimbLeaping
	then
		self:_exitWallClimbAction()
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
	elseif newState == MovementState.WallRunning then
		self:_enterWallRunning()
	elseif newState == MovementState.WallLeaping then
		self:_enterWallLeaping()
	elseif newState == MovementState.WallHanging then
		self:_enterWallHanging()
	elseif newState == MovementState.WallBoost then
		self:_enterWallBoost()
	elseif newState == MovementState.WallClingDoubleJump then
		self:_enterWallClingDoubleJump()
	elseif newState == MovementState.WallClimbLeaping then
		self:_enterWallClimbLeaping()
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
