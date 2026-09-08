--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local FiniteStateMachine = require(Shared.FSM.FiniteStateMachine)
local CombatState = require(Shared.Enums.CombatState)
local AttackPhase = require(Shared.Enums.AttackPhase)
local CombatConstants = require(Shared.Constants.CombatConstants)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)

local requestAttack = ReplicatedStorage.Remotes.RequestAttack :: RemoteEvent

-- Windup+Active+Recovery combined -- how long Attacking holds before auto-reverting to Idle. Summed
-- here rather than stored as its own constant so the three phase lengths stay the single source of
-- truth (see CombatConstants).
local TOTAL_ATTACK_DURATION = CombatConstants.AttackWindupTime + CombatConstants.AttackActiveTime + CombatConstants.AttackRecoveryTime

-- The server-side mirror of the client's CombatFSM (see Section 3's "Server-Side FSM Mirroring") --
-- every attack/parry/feint/stagger request is validated against THIS state, never the client's own
-- claim, before being allowed to fire.
type PlayerCombatRecord = {
	fsm: FiniteStateMachine.FiniteStateMachine<CombatState.CombatState>,
	-- os.clock() timestamp of the last ACCEPTED attack request -- never trusts the client's own
	-- cooldown claim (see Section 3's "Server-Side Cooldowns").
	lastAttackRequestTime: number,
	-- Tracked and explicitly task.cancel()'d rather than left to fire stale -- see Section 6's GC
	-- Defense: a respawn or an early interruption (a future stagger/parry landing mid-attack) must
	-- never let this thread revert a LATER attack back to Idle out from under it.
	attackEndThread: thread?,
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

function CombatValidationService.GetState(self: CombatValidationService, player: Player): CombatState.CombatState?
	local record = self._records[player]
	return if record then record.fsm:GetState() else nil
end

-- nil whenever the player isn't currently Attacking -- the eventual hit-detection bit only ever
-- needs to ask "is this player's hitbox live right now," which is exactly AttackPhase.Active here.
function CombatValidationService.GetAttackPhase(self: CombatValidationService, player: Player): AttackPhase.AttackPhase?
	local record = self._records[player]
	if not record or record.fsm:GetState() ~= CombatState.Attacking then
		return nil
	end

	local elapsed = os.clock() - record.lastAttackRequestTime
	if elapsed < CombatConstants.AttackWindupTime then
		return AttackPhase.Windup
	elseif elapsed < CombatConstants.AttackWindupTime + CombatConstants.AttackActiveTime then
		return AttackPhase.Active
	else
		return AttackPhase.Recovery
	end
end

function CombatValidationService._cancelAttackEndThread(_self: CombatValidationService, record: PlayerCombatRecord)
	if record.attackEndThread then
		task.cancel(record.attackEndThread)
		record.attackEndThread = nil
	end
end

function CombatValidationService._onCharacterAdded(self: CombatValidationService, player: Player, _character: Model)
	-- A fresh FSM per spawn, not a reused one reset back to Idle -- destroys the old Signal and
	-- cancels any thread still pending from the previous character, instead of leaking either.
	local existing = self._records[player]
	if existing then
		self:_cancelAttackEndThread(existing)
		existing.fsm:Destroy()
	end

	self._records[player] = {
		fsm = FiniteStateMachine.new(CombatState.Idle),
		lastAttackRequestTime = -math.huge,
		attackEndThread = nil,
	}
end

-- No hit detection yet -- this bit only proves the request/cooldown/state-transition plumbing
-- itself. Hit validation (Section 3's sanity raycasts) and parry lag-compensation (Section 4/5) are
-- their own later bits.
function CombatValidationService._onRequestAttack(self: CombatValidationService, player: Player)
	local record = self._records[player]
	if not record or not player.Character then
		return
	end

	if record.fsm:GetState() ~= CombatState.Idle then
		return
	end

	local now = os.clock()
	if now - record.lastAttackRequestTime < CombatConstants.AttackCooldown then
		return
	end
	record.lastAttackRequestTime = now

	record.fsm:TransitionTo(CombatState.Attacking)

	self:_cancelAttackEndThread(record)
	record.attackEndThread = task.delay(TOTAL_ATTACK_DURATION, function()
		record.attackEndThread = nil
		-- Guarded, not unconditional: something else (a future stagger/parry interrupt) may already
		-- have moved the FSM on by the time this fires, and that later transition must win.
		if record.fsm:GetState() == CombatState.Attacking then
			record.fsm:TransitionTo(CombatState.Idle)
		end
	end)
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
			self:_cancelAttackEndThread(record)
			record.fsm:Destroy()
		end
		self._records[player] = nil
	end)

	requestAttack.OnServerEvent:Connect(function(player: Player)
		self:_onRequestAttack(player)
	end)
end

return CombatValidationService.new()
