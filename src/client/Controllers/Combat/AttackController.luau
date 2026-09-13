--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.Shared
local CombatState = require(Shared.Enums.CombatState)
local MovementState = require(Shared.Enums.MovementState)
local CombatConstants = require(Shared.Constants.CombatConstants)
local MovementConstants = require(Shared.Constants.MovementConstants)
local WeaponDefinitions = require(Shared.Constants.WeaponDefinitions)
local WeaponTypes = require(Shared.Constants.Weapons.WeaponTypes)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local FiniteStateMachine = require(Shared.FSM.FiniteStateMachine)
local LemonSignal = require(ReplicatedStorage.Packages.LemonSignal)
local combatFSM = require(script.Parent.Parent.Parent.State.CombatFSM)
local movementFSM = require(script.Parent.Parent.Parent.State.MovementFSM)

local requestAttack = ReplicatedStorage.Remotes.RequestAttack :: RemoteEvent
local requestCriticalAttack = ReplicatedStorage.Remotes.RequestCriticalAttack :: RemoteEvent
local requestFeint = ReplicatedStorage.Remotes.RequestFeint :: RemoteEvent

-- Sent through RequestAttack's own comboStepId string alongside real combo step ids -- see
-- CombatValidationService's matching constant for why (Section 7: "server distinguishes by movement
-- state").
local RUNNING_ATTACK_ID = "RunningAttack"
local CRITICAL_ATTACK_ID = "Critical"

local player = Players.LocalPlayer

local AttackController = {}
AttackController.__index = AttackController

export type AttackController = typeof(setmetatable(
	{} :: {
		_comboIndex: number,
		-- Single shared timeout slot for whichever attack currently owns the Attacking window (an M1
		-- step, Running Attack, or Critical Attack) -- same "never more than one at a time" shape as
		-- CombatValidationService's own stateEndThread, renamed from _comboEndThread now that it
		-- covers more than just combo steps.
		_stateEndThread: thread?,
		-- Client-side-only clock for Feint's own legality gate -- os.clock() this attack's Windup
		-- ends at, set alongside _stateEndThread by every attack path. The server independently
		-- enforces the real deadline (CombatValidationService.attackWindupEndsAt); this is purely so
		-- _tryFeint doesn't even attempt a remote call once the windup has visibly ended locally.
		_currentWindupEndsAt: number,
		-- os.clock() the current attack's full Windup+Active+Recovery elapses at, set alongside
		-- _currentWindupEndsAt by _scheduleStateEnd (the shared tail for every attack path).
		-- _tryAttack's chain gate: mashing M1 faster than this legally cycled the whole combo instantly
		-- and stacked overlapping Action-priority tracks mid-fade (Combat Framework Bugfix Addendum
		-- Section 1/2.1). Full-duration gate per Section 2.5 (no recovery-cancel) -- this is purely a
		-- feel/prediction improvement, since CombatValidationService.earliestChainTime is the actual
		-- authority.
		_earliestChainTime: number,
		_lastRunningAttackTime: number,
		_lastCriticalAttackTime: number,
		-- combatFSM's own Changed signal only fires on a COARSE state change (Idle<->Attacking) --
		-- successive combo steps never leave the Attacking state, so CombatAnimationController needs
		-- this separate per-step signal to know when a new step actually starts (Section 5: "combo
		-- index tracked as data not sub-states"). Also fired for RunningAttack/Critical, since both
		-- are attack identifiers within Attacking too, not new states.
		ComboStepStarted: FiniteStateMachine.Signal<string>,
	},
	AttackController
))

function AttackController.new(): AttackController
	local self = setmetatable({
		_comboIndex = 0,
		_stateEndThread = nil,
		_currentWindupEndsAt = 0,
		_earliestChainTime = 0,
		_lastRunningAttackTime = -math.huge,
		_lastCriticalAttackTime = -math.huge,
		ComboStepStarted = (LemonSignal.new() :: any) :: FiniteStateMachine.Signal<string>,
	}, AttackController)

	return self
end

function AttackController._cancelStateEndThread(self: AttackController)
	if self._stateEndThread then
		task.cancel(self._stateEndThread)
		self._stateEndThread = nil
	end
end

-- Shared tail for every attack path (an M1 step, Running Attack, Critical Attack) -- starts the
-- step-end timeout and records the windup deadline _tryFeint checks against. Entering Attacking,
-- firing the attack's own remote, and firing ComboStepStarted all stay at each call site, since each
-- fires a different remote/identifier.
function AttackController._scheduleStateEnd(self: AttackController, windup: number, active: number, recovery: number)
	local now = os.clock()
	self._currentWindupEndsAt = now + windup
	self._earliestChainTime = now + windup + active + recovery
	self:_cancelStateEndThread()
	local duration = windup + active + recovery
	self._stateEndThread = task.delay(duration, function()
		self._stateEndThread = nil
		self._comboIndex = 0
		if combatFSM:GetState() == CombatState.Attacking then
			combatFSM:TransitionTo(CombatState.Idle)
		end
	end)
end

-- Same Attachment+LinearVelocity technique DashController's own dash uses, but a plain constant-speed
-- pulse along current facing -- Running Attack/Critical Attack aren't steerable like a real Dash, so
-- there's no need for its Heartbeat steer connection or ease curve. Self-contained and disposable
-- (not tracked on self): a short, cooldown-bounded burst has nothing later to cancel it early for.
function AttackController._applyForwardBurst(_self: AttackController, rootPart: BasePart, distance: number, duration: number)
	local attachment = Instance.new("Attachment")
	attachment.Parent = rootPart

	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	velocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	velocity.MaxAxesForce = Vector3.new(MovementConstants.MaxPhysicsForce, 0, MovementConstants.MaxPhysicsForce)
	velocity.VectorVelocity = rootPart.CFrame.LookVector * (distance / duration)
	velocity.Parent = rootPart

	task.delay(duration, function()
		attachment:Destroy()
		velocity:Destroy()
	end)
end

function AttackController._beginStep(self: AttackController, stepIndex: number, stepId: string, stepData: WeaponTypes.ComboStepData)
	self._comboIndex = stepIndex
	combatFSM:TransitionTo(CombatState.Attacking)
	requestAttack:FireServer(stepId)
	self.ComboStepStarted:Fire(stepId)
	self:_scheduleStateEnd(stepData.Windup, stepData.Active, stepData.Recovery)
end

-- Weapon-agnostic opener (Section 4): fires instead of an M1 step while movementFSM reads Running.
-- See CombatValidationService._onRequestRunningAttack for why the server also re-derives "actually
-- moving," not just the sprint toggle -- this client-side gate only needs to match closely enough for
-- a good local prediction, since the server is what actually decides legality.
function AttackController._tryRunningAttack(self: AttackController, rootPart: BasePart)
	local now = os.clock()
	local data = CombatConstants.RunningAttack
	if now - self._lastRunningAttackTime < data.Cooldown then
		return
	end
	self._lastRunningAttackTime = now

	self._comboIndex = 0
	combatFSM:TransitionTo(CombatState.Attacking)
	requestAttack:FireServer(RUNNING_ATTACK_ID)
	self.ComboStepStarted:Fire(RUNNING_ATTACK_ID)
	self:_scheduleStateEnd(data.Windup, data.Active, data.Recovery)
	self:_applyForwardBurst(rootPart, data.DashDistance, data.DashDuration)
end

-- Own dedicated input (CriticalAttackKey), separate from M1/Running Attack (Section 4) -- per-weapon
-- data, only usable from Idle.
function AttackController._tryCriticalAttack(self: AttackController)
	if combatFSM:GetState() ~= CombatState.Idle then
		return
	end

	-- Mirrors the reverse of the cross-FSM lock DashController already checks (Section 4/7): cannot
	-- throw an attack mid-dash, same as cannot break into a Dash mid-attack.
	if MovementConstants.DashingStates[movementFSM:GetState()] then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = humanoid and (humanoid :: Humanoid).RootPart
	if not humanoid or not rootPart then
		return
	end

	local weaponDef = WeaponDefinitions[CombatConstants.PlaceholderEquippedWeaponId]
	if not weaponDef then
		return
	end
	local critData = weaponDef.CriticalAttack

	local now = os.clock()
	if now - self._lastCriticalAttackTime < critData.Cooldown then
		return
	end
	self._lastCriticalAttackTime = now

	self._comboIndex = 0
	combatFSM:TransitionTo(CombatState.Attacking)
	requestCriticalAttack:FireServer()
	self.ComboStepStarted:Fire(CRITICAL_ATTACK_ID)
	self:_scheduleStateEnd(critData.Windup, critData.Active, critData.Recovery)

	if critData.DashDuration > 0 then
		self:_applyForwardBurst(rootPart, critData.DashDistance, critData.DashDuration)
	end
end

-- Cancels the current attack's windup to bait a parry (Section 4) -- only legal while that windup is
-- still genuinely open, mirroring the server's own attackWindupEndsAt check.
function AttackController._tryFeint(self: AttackController)
	if combatFSM:GetState() ~= CombatState.Attacking then
		return
	end
	if os.clock() >= self._currentWindupEndsAt then
		return
	end

	self:_cancelStateEndThread()
	self._comboIndex = 0
	combatFSM:TransitionTo(CombatState.Feinting)
	requestFeint:FireServer()

	self._stateEndThread = task.delay(CombatConstants.FeintRecoveryTime, function()
		self._stateEndThread = nil
		if combatFSM:GetState() == CombatState.Feinting then
			combatFSM:TransitionTo(CombatState.Idle)
		end
	end)
end

function AttackController._tryAttack(self: AttackController)
	-- Cannot throw an attack mid-dash (Combat_Framework_Design_Doc Section 4/7) -- the reverse of the
	-- cross-FSM lock DashController already checks against combatFSM.
	if MovementConstants.DashingStates[movementFSM:GetState()] then
		return
	end

	local currentState = combatFSM:GetState()

	-- Chain gate (Combat Framework Bugfix Addendum Section 2.1/2.5): full Windup+Active+Recovery must
	-- elapse before the next step is legal -- no recovery-cancel. Stops the client from firing a
	-- request the server will just drop, rather than being the actual authority (2.2).
	if currentState == CombatState.Attacking and os.clock() < self._earliestChainTime then
		return
	end

	if currentState == CombatState.Idle and movementFSM:GetState() == MovementState.Running then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local rootPart = humanoid and (humanoid :: Humanoid).RootPart
		if humanoid and rootPart then
			self:_tryRunningAttack(rootPart)
			return
		end
	end

	if currentState ~= CombatState.Idle and currentState ~= CombatState.Attacking then
		return
	end

	local weaponDef = WeaponDefinitions[CombatConstants.PlaceholderEquippedWeaponId]
	if not weaponDef then
		return
	end

	local nextIndex = if currentState == CombatState.Idle then 1 else self._comboIndex + 1
	if nextIndex > #weaponDef.ComboSteps then
		-- Finisher already thrown -- must return to Idle before a new combo can start, same "no
		-- auto-chain" default the Running Attack uses (Section 4).
		return
	end

	local stepId = weaponDef.ComboSteps[nextIndex]
	local stepData = weaponDef.ComboData[stepId]
	if not stepData then
		return
	end

	self:_beginStep(nextIndex, stepId, stepData)
end

function AttackController._resetForNewCharacter(self: AttackController)
	self:_cancelStateEndThread()
	self._comboIndex = 0
	self._currentWindupEndsAt = 0
	self._earliestChainTime = 0
	self._lastRunningAttackTime = -math.huge
	self._lastCriticalAttackTime = -math.huge
end

function AttackController.Init(self: AttackController)
	onCharacterAdded(player, function(character: Model)
		self:_resetForNewCharacter()

		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		humanoid.Died:Connect(function()
			self:_resetForNewCharacter()
			combatFSM:TransitionTo(CombatState.Idle)
		end)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self:_tryAttack()
			return
		end

		if input.KeyCode == CombatConstants.CriticalAttackKey then
			self:_tryCriticalAttack()
			return
		end

		-- Shares MouseButton2 with DashController's RollCancel -- safe because Dashing (movementFSM)
		-- and Attacking (combatFSM) are now mutually exclusive in both directions: the cross-FSM lock
		-- blocks a real Dash from starting mid-attack, and the DashingStates check above (and in
		-- _tryCriticalAttack) blocks an attack from starting mid-dash. A single right-click can
		-- therefore only ever be a legal RollCancel or a legal Feint, never both at once.
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			self:_tryFeint()
		end
	end)
end

return AttackController.new()
