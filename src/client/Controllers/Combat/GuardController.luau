--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.Shared
local CombatState = require(Shared.Enums.CombatState)
local CombatConstants = require(Shared.Constants.CombatConstants)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local combatFSM = require(script.Parent.Parent.Parent.State.CombatFSM)

local requestGuard = ReplicatedStorage.Remotes.RequestGuard :: RemoteEvent

local player = Players.LocalPlayer

local GuardController = {}
GuardController.__index = GuardController

export type GuardController = typeof(setmetatable(
	{} :: {
		_isGuardKeyHeld: boolean,
		_parryWindowThread: thread?,
		-- Client-side prediction only -- the server independently enforces its own whiff cooldown
		-- regardless of this. There's no server->client "you actually landed it" notification yet,
		-- so this is applied on every whiff prediction (window timeout or early release), same
		-- known-simplification status as the rest of this pass.
		_whiffCooldownUntil: number,
	},
	GuardController
))

function GuardController.new(): GuardController
	local self = setmetatable({
		_isGuardKeyHeld = false,
		_parryWindowThread = nil,
		_whiffCooldownUntil = 0,
	}, GuardController)

	return self
end

function GuardController._cancelParryWindowThread(self: GuardController)
	if self._parryWindowThread then
		task.cancel(self._parryWindowThread)
		self._parryWindowThread = nil
	end
end

-- Reachable only on a genuine whiff -- a successful parry ends Parrying immediately elsewhere
-- (there's no server notification for that locally yet, but the server-side equivalent,
-- CombatValidationService._onParrySucceeded, does exactly this same branch server-side).
function GuardController._onParryWindowElapsed(self: GuardController)
	self._parryWindowThread = nil
	self._whiffCooldownUntil = os.clock() + CombatConstants.ParryWhiffCooldown

	if combatFSM:GetState() ~= CombatState.Parrying then
		return
	end

	combatFSM:TransitionTo(if self._isGuardKeyHeld then CombatState.Blocking else CombatState.Idle)
end

function GuardController._trySetGuarding(self: GuardController, isHeld: boolean)
	if self._isGuardKeyHeld == isHeld then
		return
	end

	if isHeld then
		if combatFSM:GetState() ~= CombatState.Idle then
			return
		end
		self._isGuardKeyHeld = true

		if os.clock() < self._whiffCooldownUntil then
			-- Forced into Block-only (Section 3) -- skip the parry attempt entirely.
			combatFSM:TransitionTo(CombatState.Blocking)
		else
			combatFSM:TransitionTo(CombatState.Parrying)
			self:_cancelParryWindowThread()
			self._parryWindowThread = task.delay(CombatConstants.PARRY_WINDOW, function()
				self:_onParryWindowElapsed()
			end)
		end
	else
		self._isGuardKeyHeld = false

		if combatFSM:GetState() == CombatState.Parrying then
			-- Released mid-window with nothing parried -- still a whiff.
			self:_cancelParryWindowThread()
			self._whiffCooldownUntil = os.clock() + CombatConstants.ParryWhiffCooldown
			combatFSM:TransitionTo(CombatState.Idle)
		elseif combatFSM:GetState() == CombatState.Blocking then
			combatFSM:TransitionTo(CombatState.Idle)
		end
	end

	requestGuard:FireServer(isHeld)
end

function GuardController._resetForNewCharacter(self: GuardController)
	self._isGuardKeyHeld = false
	self:_cancelParryWindowThread()
	self._whiffCooldownUntil = 0
end

function GuardController.Init(self: GuardController)
	onCharacterAdded(player, function(character: Model)
		self:_resetForNewCharacter()

		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		humanoid.Died:Connect(function()
			self:_resetForNewCharacter()
		end)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end

		if input.KeyCode == CombatConstants.GuardKey then
			self:_trySetGuarding(true)
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.KeyCode == CombatConstants.GuardKey then
			self:_trySetGuarding(false)
		end
	end)
end

return GuardController.new()
