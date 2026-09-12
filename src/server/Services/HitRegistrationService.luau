--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local CombatState = require(Shared.Enums.CombatState)
local WeaponTypes = require(Shared.Constants.Weapons.WeaponTypes)

-- TEMP hitbox shape, not per-weapon geometry -- there's no weapon-equip system yet (design doc
-- Section 13), so there's no real weapon model/Attachment to query against. A forward-offset sphere
-- off the attacker's own root part stands in until equipping exists; swap this for the real
-- per-weapon hitbox Attachment once it does. Live positions only, no lag compensation yet (roadmap
-- step 2's explicit scope -- see Combat_Framework_Design_Doc Section 12).
local HIT_CHECK_FORWARD_OFFSET = 4
local HIT_CHECK_RADIUS = 4.5

local HitRegistrationService = {}
HitRegistrationService.__index = HitRegistrationService

export type HitRegistrationService = typeof(setmetatable(
	{} :: {
		_pendingHitThreads: { [Player]: thread },
		_combatStateQuery: ((Player) -> string?)?,
		_onParrySuccess: ((Player) -> ())?,
		_isDodgingQuery: ((Player) -> boolean)?,
	},
	HitRegistrationService
))

function HitRegistrationService.new(): HitRegistrationService
	local self = setmetatable({
		_pendingHitThreads = {},
		_combatStateQuery = nil,
		_onParrySuccess = nil,
		_isDodgingQuery = nil,
	}, HitRegistrationService)

	return self
end

-- Injected by CombatValidationService.Init rather than requiring it back (it already requires this
-- module to call :ResolveAttack) -- same cycle-avoidance pattern as MovementController.SetSprintQuery.
function HitRegistrationService.SetCombatStateQuery(self: HitRegistrationService, query: (Player) -> string?)
	self._combatStateQuery = query
end

function HitRegistrationService.SetOnParrySuccess(self: HitRegistrationService, callback: (Player) -> ())
	self._onParrySuccess = callback
end

-- "Dodging" isn't its own combat state or key -- the ground Dash already is that mechanic (design
-- doc calls it "load-bearing for combat itself," Section 9). Injected from ServiceBootstrap since
-- MovementValidationService and this module have no existing require relationship either way.
function HitRegistrationService.SetIsDodgingQuery(self: HitRegistrationService, query: (Player) -> boolean)
	self._isDodgingQuery = query
end

function HitRegistrationService._clearPendingThread(self: HitRegistrationService, player: Player)
	local thread = self._pendingHitThreads[player]
	if thread then
		task.cancel(thread)
		self._pendingHitThreads[player] = nil
	end
end

-- Proves the server-authoritative hit-detection pipeline in isolation (roadmap step 2/3) -- doesn't
-- apply damage/posture yet, since no HP/posture resource exists in the combat framework at this
-- stage (Section 11: deferred to a later content pass). Logs the resolved outcome instead --
-- checked against the DEFENDER's own live combat state, no lag compensation yet (roadmap step 3's
-- explicit scope: "using live timestamps initially, not full lag comp").
function HitRegistrationService._performHitCheck(
	self: HitRegistrationService,
	player: Player,
	character: Model,
	rootPart: BasePart,
	weaponId: string,
	comboStepId: string
)
	local origin = rootPart.Position + (rootPart.CFrame.LookVector * HIT_CHECK_FORWARD_OFFSET)

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { character }

	local nearbyParts = workspace:GetPartBoundsInRadius(origin, HIT_CHECK_RADIUS, overlapParams)

	local hitCharacters: { [Model]: boolean } = {}
	for _, part in ipairs(nearbyParts) do
		local hitCharacter = part:FindFirstAncestorOfClass("Model")
		if not hitCharacter or hitCharacters[hitCharacter] then
			continue
		end

		local hitPlayer = Players:GetPlayerFromCharacter(hitCharacter)
		if not hitPlayer or hitPlayer == player then
			continue
		end
		hitCharacters[hitCharacter] = true

		local isDodging = self._isDodgingQuery and self._isDodgingQuery(hitPlayer)
		local defenderState = self._combatStateQuery and self._combatStateQuery(hitPlayer)

		if isDodging then
			print(string.format("[Combat] %s's %s (%s) on %s was DODGED (dashing)", player.Name, weaponId, comboStepId, hitPlayer.Name))
		elseif defenderState == CombatState.Parrying then
			print(string.format("[Combat] %s's %s (%s) was PARRIED by %s", player.Name, weaponId, comboStepId, hitPlayer.Name))
			if self._onParrySuccess then
				self._onParrySuccess(hitPlayer)
			end
		elseif defenderState == CombatState.Blocking then
			print(string.format("[Combat] %s's %s (%s) on %s was BLOCKED", player.Name, weaponId, comboStepId, hitPlayer.Name))
		else
			print(string.format("[Combat] %s hit %s with %s (%s)", player.Name, hitPlayer.Name, weaponId, comboStepId))
		end
	end
end

function HitRegistrationService.ResolveAttack(
	self: HitRegistrationService,
	player: Player,
	weaponId: string,
	comboStepId: string,
	stepData: WeaponTypes.ComboStepData
)
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not character or not rootPart then
		return
	end

	self:_clearPendingThread(player)
	self._pendingHitThreads[player] = task.delay(stepData.Windup, function()
		self._pendingHitThreads[player] = nil
		self:_performHitCheck(player, character, rootPart, weaponId, comboStepId)
	end)
end

function HitRegistrationService.Init(self: HitRegistrationService)
	Players.PlayerRemoving:Connect(function(player: Player)
		self:_clearPendingThread(player)
	end)
end

return HitRegistrationService.new()
