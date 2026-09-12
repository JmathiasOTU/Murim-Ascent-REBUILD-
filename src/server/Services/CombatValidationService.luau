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

local requestAttack = ReplicatedStorage.Remotes.RequestAttack :: RemoteEvent
local requestGuard = ReplicatedStorage.Remotes.RequestGuard :: RemoteEvent

type PlayerCombatRecord = {
	humanoid: Humanoid,
	rootPart: BasePart,
	state: string, -- Idle | Attacking | Blocking | Parrying
	comboIndex: number, -- 0 while not Attacking, 1-#ComboSteps while Attacking
	lastAttackRequestTime: number,
	lastGuardRequestTime: number,
	-- Block and Parry share one hold key -- tracked independently of `state` since Parrying can end
	-- (successfully or by whiff) while the key is still physically held, at which point the player
	-- drops into Blocking instead of Idle. See _onParryWindowElapsed/_onParrySucceeded.
	isGuardKeyHeld: boolean,
	-- "Forced into Block-only until it expires" (Section 3) -- a whiffed Parry sets this; a fresh
	-- RequestGuard(true) skips straight to Blocking (no parry attempt) while now < this.
	parryWhiffCooldownUntil: number,
	-- Single shared timeout thread for whichever state currently owns a fixed-duration window
	-- (Attacking's combo-reset, Parrying's window-end) -- never more than one is active at a time,
	-- since a player is in exactly one state.
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
		lastGuardRequestTime = 0,
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

	record.lastAttackRequestTime = now
	record.state = CombatState.Attacking
	record.comboIndex = expectedIndex

	local stepDuration = stepData.Windup + stepData.Active + stepData.Recovery
	self:_clearStateEndThread(record)
	record.stateEndThread = task.delay(stepDuration + CombatValidationConstants.ComboStepGrace, function()
		record.stateEndThread = nil
		record.state = CombatState.Idle
		record.comboIndex = 0
	end)

	HitRegistrationService:ResolveAttack(player, CombatConstants.PlaceholderEquippedWeaponId, comboStepId, stepData)
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
