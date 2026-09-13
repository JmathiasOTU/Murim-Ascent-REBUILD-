--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local CombatState = require(Shared.Enums.CombatState)
local CombatConstants = require(Shared.Constants.CombatConstants)
local WeaponDefinitions = require(Shared.Constants.WeaponDefinitions)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local CombatValidationConstants = require(script.Parent.Parent.Constants.CombatValidationConstants)
local HitRegistrationService = require(script.Parent.HitRegistrationService)
-- Direct require, not an injected query -- Combat_Framework_Design_Doc Section 4 explicitly calls
-- this "a fine direct call, since the Pub/Sub rule targets client Controllers, not server Services."
local MovementValidationService = require(script.Parent.MovementValidationService)

local requestAttack = ReplicatedStorage.Remotes.RequestAttack :: RemoteEvent
local requestCriticalAttack = ReplicatedStorage.Remotes.RequestCriticalAttack :: RemoteEvent
local requestFeint = ReplicatedStorage.Remotes.RequestFeint :: RemoteEvent
local requestGuard = ReplicatedStorage.Remotes.RequestGuard :: RemoteEvent

-- Sent through RequestAttack's own comboStepId string alongside real combo step ids (Section 7:
-- "RequestAttack covers both the M1 chain and the running attack -- server distinguishes by
-- movement state") -- never a legal WeaponDefinitions.ComboSteps entry, so it can't collide.
local RUNNING_ATTACK_ID = "RunningAttack"
local CRITICAL_ATTACK_ID = "Critical"

type PlayerCombatRecord = {
	humanoid: Humanoid,
	rootPart: BasePart,
	state: string, -- Idle | Attacking | Feinting | Blocking | Parrying
	comboIndex: number, -- 0 while not Attacking on an M1 step, 1-#ComboSteps while mid-combo
	lastAttackRequestTime: number,
	lastRunningAttackTime: number,
	lastCriticalAttackTime: number,
	lastFeintRequestTime: number,
	lastGuardRequestTime: number,
	-- Set at the start of every attack (M1 step, Running Attack, Critical Attack) to now + that
	-- attack's own Windup -- _onRequestFeint's only legality check, since a feint must land during
	-- the windup it's cancelling, not after the attack has already gone active/recovered.
	attackWindupEndsAt: number,
	-- now + that attack's own full Windup+Active+Recovery, set alongside attackWindupEndsAt in
	-- _beginAttack -- the real chain gate (Combat Framework Bugfix Addendum Section 2.2/2.5, full-
	-- duration gate, no recovery-cancel): a modified client that skips AttackController's own
	-- client-side gate must still not be able to advance comboIndex before the current step has fully
	-- finished, which is what let mashing M1 stack overlapping Action-priority animation tracks
	-- (Section 1).
	earliestChainTime: number,
	-- Block and Parry share one hold key -- tracked independently of `state` since Parrying can end
	-- (successfully or by whiff) while the key is still physically held, at which point the player
	-- drops into Blocking instead of Idle. See _onParryWindowElapsed/_onParrySucceeded.
	isGuardKeyHeld: boolean,
	-- "Forced into Block-only until it expires" (Section 3) -- a whiffed Parry sets this; a fresh
	-- RequestGuard(true) skips straight to Blocking (no parry attempt) while now < this.
	parryWhiffCooldownUntil: number,
	-- Single shared timeout thread for whichever state currently owns a fixed-duration window
	-- (Attacking's combo-reset, Feinting's recovery, Parrying's window-end) -- never more than one is
	-- active at a time, since a player is in exactly one state.
	stateEndThread: thread?,
}

local CombatValidationService = {}
CombatValidationService.__index = CombatValidationService

export type CombatValidationService = typeof(setmetatable(
	{} :: {
		_records: { [Player]: PlayerCombatRecord },
	},
	CombatValidationService
))

function CombatValidationService.new(): CombatValidationService
	local self = setmetatable({
		_records = {},
	}, CombatValidationService)

	return self
end

function CombatValidationService._clearStateEndThread(_self: CombatValidationService, record: PlayerCombatRecord)
	if record.stateEndThread then
		task.cancel(record.stateEndThread)
		record.stateEndThread = nil
	end
end

function CombatValidationService._onCharacterAdded(self: CombatValidationService, player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	local existingRecord = self._records[player]
	if existingRecord then
		self:_clearStateEndThread(existingRecord)
	end

	self._records[player] = {
		humanoid = humanoid,
		rootPart = rootPart,
		state = CombatState.Idle,
		comboIndex = 0,
		lastAttackRequestTime = 0,
		lastRunningAttackTime = -math.huge,
		lastCriticalAttackTime = -math.huge,
		lastFeintRequestTime = 0,
		lastGuardRequestTime = 0,
		attackWindupEndsAt = 0,
		earliestChainTime = 0,
		isGuardKeyHeld = false,
		parryWhiffCooldownUntil = 0,
		stateEndThread = nil,
	}
end

function CombatValidationService.GetState(self: CombatValidationService, player: Player): string?
	local record = self._records[player]
	return record and record.state
end

-- HitRegistrationService calls this the instant it resolves a hit as parried -- ends Parrying
-- immediately without the whiff cooldown (only an actual whiff costs that, per Section 3). Drops
-- into Blocking instead of Idle if the shared guard key is still held.
function CombatValidationService._onParrySucceeded(self: CombatValidationService, player: Player)
	local record = self._records[player]
	if not record then
		return
	end

	self:_clearStateEndThread(record)
	record.state = if record.isGuardKeyHeld then CombatState.Blocking else CombatState.Idle
end

function CombatValidationService._onParryWindowElapsed(_self: CombatValidationService, record: PlayerCombatRecord)
	record.stateEndThread = nil
	-- Only reachable on a genuine whiff -- a successful parry ends Parrying early via
	-- _onParrySucceeded, which clears this thread before it ever fires.
	record.parryWhiffCooldownUntil = os.clock() + CombatConstants.ParryWhiffCooldown
	record.state = if record.isGuardKeyHeld then CombatState.Blocking else CombatState.Idle
end

-- Shared by every attack path below (an M1 step, Running Attack, Critical Attack) -- enters
-- Attacking, starts the shared step-end timeout, records the windup deadline Feint checks against,
-- and hands the hit off to HitRegistrationService. comboIndex is the caller's responsibility (an M1
-- step advances it; Running/Critical Attack reset it to 0, per Section 4's "standalone hit" default).
function CombatValidationService._beginAttack(
	self: CombatValidationService,
	player: Player,
	record: PlayerCombatRecord,
	now: number,
	comboIndex: number,
	weaponId: string,
	attackId: string,
	windup: number,
	active: number,
	recovery: number
)
	record.lastAttackRequestTime = now
	record.state = CombatState.Attacking
	record.comboIndex = comboIndex
	record.attackWindupEndsAt = now + windup
	record.earliestChainTime = now + windup + active + recovery

	local duration = windup + active + recovery
	self:_clearStateEndThread(record)
	record.stateEndThread = task.delay(duration + CombatValidationConstants.ComboStepGrace, function()
		record.stateEndThread = nil
		record.state = CombatState.Idle
		record.comboIndex = 0
	end)

	HitRegistrationService:ResolveAttack(player, weaponId, attackId, windup)
end

function CombatValidationService._onRequestAttack(self: CombatValidationService, player: Player, comboStepId: unknown)
	if typeof(comboStepId) ~= "string" then
		return
	end

	local record = self._records[player]
	if not record or not player.Character then
		return
	end

	if record.state ~= CombatState.Idle and record.state ~= CombatState.Attacking then
		return
	end

	local now = os.clock()
	if now - record.lastAttackRequestTime < CombatValidationConstants.MinAttackRequestInterval then
		return
	end

	-- Cannot throw an attack mid-dash (Combat_Framework_Design_Doc Section 4/7) -- the reverse of the
	-- cross-FSM lock DashController already checks against combatFSM. IsDashInvulnerable is scoped to
	-- exactly the dash's own physical duration (ends early on a roll cancel or interrupt, same as the
	-- client's own movementFSM Dashing state), so it doubles as "is this player mid-dash right now"
	-- without a second, separately-tracked flag.
	if MovementValidationService:IsDashInvulnerable(player) then
		warn(string.format("[Anti-Exploit] %s attempted to attack while dashing.", player.Name))
		return
	end

	if comboStepId == RUNNING_ATTACK_ID then
		self:_onRequestRunningAttack(player, record, now)
		return
	end

	-- Chain gate (Combat Framework Bugfix Addendum Section 1/2.2): only MinAttackRequestInterval gated
	-- this before, which is a RemoteEvent-level anti-macro floor, not a gameplay pacing rule -- mashing
	-- faster than a combo step's own full duration legally cycled the whole combo almost instantly.
	-- Full-duration gate, no recovery-cancel, per Section 2.5.
	if record.state == CombatState.Attacking and now < record.earliestChainTime then
		warn(string.format("[Anti-Exploit] %s tried to chain a combo step before the current one finished.", player.Name))
		return
	end

	local weaponDef = WeaponDefinitions[CombatConstants.PlaceholderEquippedWeaponId]
	if not weaponDef then
		return
	end

	local expectedIndex = if record.state == CombatState.Idle then 1 else record.comboIndex + 1
	if expectedIndex > #weaponDef.ComboSteps then
		warn(string.format("[Anti-Exploit] %s tried to continue a combo past its last step.", player.Name))
		return
	end

	local expectedStepId = weaponDef.ComboSteps[expectedIndex]
	if comboStepId ~= expectedStepId then
		warn(string.format(
			"[Anti-Exploit] %s requested an illegal combo step (expected %s, got %s).",
			player.Name,
			expectedStepId,
			comboStepId
		))
		return
	end

	local stepData = weaponDef.ComboData[comboStepId]
	if not stepData then
		return
	end

	self:_beginAttack(
		player,
		record,
		now,
		expectedIndex,
		CombatConstants.PlaceholderEquippedWeaponId,
		comboStepId,
		stepData.Windup,
		stepData.Active,
		stepData.Recovery
	)
end

-- Weapon-agnostic opener (Section 4): sprint + attack input, in place of the M1 chain, only from
-- Idle (a mid-combo player already committed to the M1 chain, not this). "Running movement state"
-- per the doc means both flags together -- IsSprinting alone only proves the double-tap-W toggle is
-- on, not that the player is actually moving right now (see MovementController._setSprintKeyHeld,
-- which fires that toggle to the server regardless of MoveDirection) -- MoveDirection closes that gap
-- the same server-observed-Humanoid-property way the rest of this codebase already trusts it (e.g.
-- MovementValidationService.isAirborne's own vertical-velocity fallback).
function CombatValidationService._onRequestRunningAttack(self: CombatValidationService, player: Player, record: PlayerCombatRecord, now: number)
	if record.state ~= CombatState.Idle then
		return
	end

	local data = CombatConstants.RunningAttack
	if now - record.lastRunningAttackTime < data.Cooldown then
		return
	end

	if not MovementValidationService:IsSprinting(player) or record.humanoid.MoveDirection.Magnitude <= 0 then
		warn(string.format("[Anti-Exploit] %s attempted a running attack while not running.", player.Name))
		return
	end

	record.lastRunningAttackTime = now
	self:_beginAttack(player, record, now, 0, CombatConstants.PlaceholderEquippedWeaponId, RUNNING_ATTACK_ID, data.Windup, data.Active, data.Recovery)
	MovementValidationService:GrantSpeedExemption(player, data.DashDuration, data.DashDistance / data.DashDuration)
end

-- Own dedicated remote/input (Section 4), separate from M1/Running Attack -- per-weapon data
-- (weaponDef.CriticalAttack), only from Idle (no mid-combo cancel into a crit).
function CombatValidationService._onRequestCriticalAttack(self: CombatValidationService, player: Player)
	local record = self._records[player]
	if not record or not player.Character then
		return
	end

	if record.state ~= CombatState.Idle then
		return
	end

	local now = os.clock()
	if now - record.lastAttackRequestTime < CombatValidationConstants.MinAttackRequestInterval then
		return
	end

	-- Cannot throw an attack mid-dash -- see the matching check in _onRequestAttack for why
	-- IsDashInvulnerable is the right signal for this.
	if MovementValidationService:IsDashInvulnerable(player) then
		warn(string.format("[Anti-Exploit] %s attempted a critical attack while dashing.", player.Name))
		return
	end

	local weaponDef = WeaponDefinitions[CombatConstants.PlaceholderEquippedWeaponId]
	if not weaponDef then
		return
	end

	local critData = weaponDef.CriticalAttack
	if now - record.lastCriticalAttackTime < critData.Cooldown then
		return
	end

	record.lastCriticalAttackTime = now
	self:_beginAttack(
		player,
		record,
		now,
		0,
		CombatConstants.PlaceholderEquippedWeaponId,
		CRITICAL_ATTACK_ID,
		critData.Windup,
		critData.Active,
		critData.Recovery
	)

	-- Guarded, not unconditional -- Section 4 explicitly allows a stationary crit (DashDistance/
	-- DashDuration both 0, e.g. Greatsword's planted overhead swing), which would divide by zero here.
	if critData.DashDuration > 0 then
		MovementValidationService:GrantSpeedExemption(player, critData.DashDuration, critData.DashDistance / critData.DashDuration)
	end
end

-- Cancels the windup of an in-flight attack to bait a parry (Section 4) -- legal only while that
-- windup is still genuinely open, checked against the same deadline _beginAttack recorded for it, not
-- just "state == Attacking" (which stays true through Active/Recovery too). Resets comboIndex, same
-- "feinting drops the combo" convention as any other early exit.
function CombatValidationService._onRequestFeint(self: CombatValidationService, player: Player)
	local record = self._records[player]
	if not record or not player.Character then
		return
	end

	local now = os.clock()
	if now - record.lastFeintRequestTime < CombatValidationConstants.MinFeintRequestInterval then
		return
	end
	record.lastFeintRequestTime = now

	if record.state ~= CombatState.Attacking then
		return
	end

	if now >= record.attackWindupEndsAt then
		warn(string.format("[Anti-Exploit] %s tried to feint after the windup already ended.", player.Name))
		return
	end

	self:_clearStateEndThread(record)
	record.state = CombatState.Feinting
	record.comboIndex = 0
	HitRegistrationService:CancelPendingHit(player)

	record.stateEndThread = task.delay(CombatConstants.FeintRecoveryTime, function()
		record.stateEndThread = nil
		record.state = CombatState.Idle
	end)
end

-- Block and Parry share this one remote/key. `wantsToGuard = true` opens a parry attempt (or, if
-- still on the whiff cooldown, skips straight to Blocking); `false` ends whichever of the two is
-- currently active. See PlayerCombatRecord.isGuardKeyHeld's own comment for why the two are tracked
-- separately from `state`.
function CombatValidationService._onRequestGuard(self: CombatValidationService, player: Player, wantsToGuard: unknown)
	if typeof(wantsToGuard) ~= "boolean" then
		return
	end

	local record = self._records[player]
	if not record or not player.Character then
		return
	end

	local now = os.clock()
	if now - record.lastGuardRequestTime < CombatValidationConstants.GuardRequestCooldown then
		return
	end
	record.lastGuardRequestTime = now

	if wantsToGuard then
		if record.state ~= CombatState.Idle then
			return
		end
		record.isGuardKeyHeld = true

		if now < record.parryWhiffCooldownUntil then
			record.state = CombatState.Blocking
			return
		end

		record.state = CombatState.Parrying
		self:_clearStateEndThread(record)
		record.stateEndThread = task.delay(CombatConstants.PARRY_WINDOW, function()
			self:_onParryWindowElapsed(record)
		end)
	else
		record.isGuardKeyHeld = false

		if record.state == CombatState.Parrying then
			-- Released mid-window with nothing parried -- still a whiff.
			self:_clearStateEndThread(record)
			record.state = CombatState.Idle
			record.parryWhiffCooldownUntil = now + CombatConstants.ParryWhiffCooldown
		elseif record.state == CombatState.Blocking then
			record.state = CombatState.Idle
		end
	end
end

function CombatValidationService.Init(self: CombatValidationService)
	local function onPlayerAdded(player: Player)
		onCharacterAdded(player, function(character: Model)
			self:_onCharacterAdded(player, character)
		end)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)

	Players.PlayerRemoving:Connect(function(player: Player)
		local record = self._records[player]
		if record then
			self:_clearStateEndThread(record)
		end
		self._records[player] = nil
	end)

	requestAttack.OnServerEvent:Connect(function(player: Player, comboStepId: unknown)
		self:_onRequestAttack(player, comboStepId)
	end)

	requestCriticalAttack.OnServerEvent:Connect(function(player: Player)
		self:_onRequestCriticalAttack(player)
	end)

	requestFeint.OnServerEvent:Connect(function(player: Player)
		self:_onRequestFeint(player)
	end)

	requestGuard.OnServerEvent:Connect(function(player: Player, wantsToGuard: unknown)
		self:_onRequestGuard(player, wantsToGuard)
	end)

	-- Injected rather than HitRegistrationService requiring this module back (which already requires
	-- HitRegistrationService to call :ResolveAttack) -- same require-cycle-avoidance pattern as
	-- MovementController.SetSprintQuery.
	HitRegistrationService:SetCombatStateQuery(function(player: Player): string?
		return self:GetState(player)
	end)
	HitRegistrationService:SetOnParrySuccess(function(player: Player)
		self:_onParrySucceeded(player)
	end)
end

return CombatValidationService.new()
