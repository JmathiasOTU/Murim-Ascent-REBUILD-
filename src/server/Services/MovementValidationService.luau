--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local MovementConstants = require(Shared.Constants.MovementConstants)
local DashCategory = require(Shared.Enums.DashCategory)
local newDashCooldownStates = require(Shared.Utils.NewDashCooldownStates)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local regenCharges = require(Shared.Utils.RegenCharges)
local MovementValidationConstants = require(script.Parent.Parent.Constants.MovementValidationConstants)
local PlayerVitalsService = require(script.Parent.PlayerVitalsService)

local requestSprint = ReplicatedStorage.Remotes.RequestSprint :: RemoteEvent
local requestSprintTechnique = ReplicatedStorage.Remotes.RequestSprintTechnique :: RemoteEvent
local requestDash = ReplicatedStorage.Remotes.RequestDash :: RemoteEvent
local requestAirDash = ReplicatedStorage.Remotes.RequestAirDash :: RemoteEvent
local requestDoubleJump = ReplicatedStorage.Remotes.RequestDoubleJump :: RemoteEvent
local requestLedgeJump = ReplicatedStorage.Remotes.RequestLedgeJump :: RemoteEvent
local requestRollCancel = ReplicatedStorage.Remotes.RequestRollCancel :: RemoteEvent
local requestSlide = ReplicatedStorage.Remotes.RequestSlide :: RemoteEvent
local requestCrouch = ReplicatedStorage.Remotes.RequestCrouch :: RemoteEvent
local requestWallRun = ReplicatedStorage.Remotes.RequestWallRun :: RemoteEvent
local requestWallLeap = ReplicatedStorage.Remotes.RequestWallLeap :: RemoteEvent
local requestWallCling = ReplicatedStorage.Remotes.RequestWallCling :: RemoteEvent
local requestWallBoost = ReplicatedStorage.Remotes.RequestWallBoost :: RemoteEvent
local requestWallClingDoubleJump = ReplicatedStorage.Remotes.RequestWallClingDoubleJump :: RemoteEvent
local requestWallClimbLeap = ReplicatedStorage.Remotes.RequestWallClimbLeap :: RemoteEvent

type PlayerMovementRecord = {
	humanoid: Humanoid,
	rootPart: BasePart,
	lastSprintRequestTime: number,
	isSprinting: boolean,
	-- The Qinggong Sprinting technique's fully-ramped boundary (see SprintController) -- the ramp
	-- itself (SprintCharging) never leaves Running's WalkSpeed tolerance, so only this needs its own
	-- server-tracked flag. Like isSliding below, it's kept honest by a renewal timeout rather than
	-- trusted as a one-shot permanent flag -- see lastFullSprintRequestTime.
	isFullSprinting: boolean,
	-- Last accepted RequestSprintTechnique(true), renewed by SprintController on
	-- MovementConstants.FullSprintRenewalInterval for as long as IsSprintActive() stays true --
	-- _validatePlayer forces isFullSprinting back off if this goes stale (see
	-- MovementValidationConstants.FullSprintRenewalGraceWindow), the same pattern as the slide fix
	-- below (RequestSprintTechnique(true) previously had no expiry at all).
	lastFullSprintRequestTime: number,
	-- Also doubles as "last accepted RequestSlide(true)" for the renewal-expiry check in
	-- _validatePlayer, since SlideController keeps re-firing that same request on
	-- MovementConstants.SlideRenewalInterval for as long as the slide continues.
	lastSlideRequestTime: number,
	-- Sliding can run for a variable, physics-driven duration (decaying friction, re-accelerating
	-- down a steep slope), unlike Dash's fixed duration -- so instead of a timed exemption window,
	-- WalkSpeed itself is bumped to cover it for as long as the client keeps affirming the slide is
	-- still active (see MovementConstants.SlideRenewalInterval / MovementValidationConstants.
	-- SlideRenewalGraceWindow) -- a single unrenewed claim can't hold SlideMaxSpeed indefinitely.
	isSliding: boolean,
	-- nil while isSliding is false or the ground under a sliding player is currently steep; set to
	-- the moment non-steep ground was first seen otherwise. Lets _validatePlayer mirror the client's
	-- own SlideController flat-ground decay-to-end timer (SlideFrictionDuration) independently,
	-- instead of trusting RequestSlide(true) renewals alone -- those only prove the client is still
	-- claiming a slide, not that there's still a real slope justifying one (see getSlopeAngle).
	slideFlatSince: number?,
	lastCrouchRequestTime: number,
	isCrouching: boolean,
	dashCooldowns: { [string]: newDashCooldownStates.DashCooldownState },
	lastDashCategory: string,
	lastAirDashTime: number,
	-- While now < this, _validatePlayer skips its speed check entirely -- covers a dash's own
	-- velocity burst, and any other transient (e.g. residual walking momentum not yet decayed to a
	-- just-lowered WalkSpeed) too fast for WalkSpeed-based validation to tell from a speed hack.
	speedCheckExemptUntil: number,
	-- Set by _onRequestAirDash/_onRequestLedgeJump, consumed by _validatePlayer the moment its own
	-- airborne poll observes the resulting landing -- a residual-momentum settle grace can't be
	-- granted up front like the ground dash's, since when that landing actually happens isn't known
	-- at request time.
	wasAirborne: boolean,
	pendingLandingSettleGrace: boolean,
	-- No cooldown timer like the dashes -- gated purely by "already used this airborne excursion,"
	-- reset alongside pendingLandingSettleGrace the moment _validatePlayer's airborne poll detects
	-- landing. Never touches horizontal velocity, so unlike air dash it needs no speed-check grant.
	hasDoubleJumped: boolean,
	rollCancelCharges: number,
	rollCancelChargeRegenStart: number,
	lastPosition: Vector3,
	lastCheckTime: number,
	speedViolationStreak: number,
	-- Keyed by ability name (e.g. "WallRun") -- see MovementValidationConstants.MinAbilityRequestInterval.
	lastAbilityRequestTime: { [string]: number },
}

local function isAirborne(humanoid: Humanoid): boolean
	local state = humanoid:GetState()
	return state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall
end

-- Coarse geometry sanity check for wall running/leaping: is there actually any collidable part
-- near the player, mirroring the client's own wall raycast without trusting its claim. Projects
-- the check origin forward along measured velocity for half the player's ping so replication lag
-- doesn't cause false rejections.
local function isNearWall(character: Model, player: Player): boolean
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then
		return false
	end

	local latency = math.min(player:GetNetworkPing() / 2, MovementValidationConstants.WallProximityLatencyCap)
	local origin = rootPart.Position + (rootPart.AssemblyLinearVelocity * latency)

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { character }

	local nearbyParts = workspace:GetPartBoundsInRadius(origin, MovementValidationConstants.WallProximityCheckDistance, overlapParams)
	for _, part in ipairs(nearbyParts) do
		if part.CanCollide then
			return true
		end
	end
	return false
end

-- Coarse geometry sanity check for starting or renewing a slide: is there actually ground beneath
-- the player at all, mirroring the client's own downward slope raycast (see
-- SlideController._checkSlideSlope) without trusting its claim -- same "is there real geometry here
-- at all" bar as isNearWall above, not slope-accurate.
local function isOverGround(character: Model): boolean
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then
		return false
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }

	return workspace:Raycast(rootPart.Position, Vector3.new(0, -MovementConstants.SlideGroundRayDistance, 0), rayParams) ~= nil
end

-- Same downward-raycast shape as the client's own SlideController._checkSlideSlope, used by
-- _validatePlayer to independently track how long a slide has actually been on non-steep ground --
-- isOverGround above only proves ground exists at all, not that it's still steep enough to justify
-- holding SlideMaxSpeed via renewal spam (see PRIORITY 3 in _validatePlayer). Coarse, same "is there
-- real geometry" bar as isNearWall/isOverGround, not pixel-perfect slope matching. rayParams is built
-- fresh by the caller per player per call (not a shared self._rayParams like the client's own
-- version) since each call here checks a different player's own character.
local function getSlopeAngle(character: Model, rayParams: RaycastParams): number?
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then
		return nil
	end

	local result = workspace:Raycast(rootPart.Position, Vector3.new(0, -MovementConstants.SlideGroundRayDistance, 0), rayParams)
	if not result then
		return nil
	end

	return math.deg(math.acos(math.clamp(result.Normal:Dot(Vector3.new(0, 1, 0)), -1, 1)))
end

local function computeWalkSpeed(record: PlayerMovementRecord): number
	if record.isSliding then
		-- Mirrors SlideController._beginSlide's own clamp: a Qinggong-Sprint-boosted slide is allowed
		-- an entry speed up to SlideMaxSpeed * SprintSlideMaxSpeedMultiplier, not just SlideMaxSpeed --
		-- granting only the plain ceiling here would rubberband a legitimate sprint-boosted slide the
		-- instant it exceeds SlideMaxSpeed, as if it were the exploit this file is guarding against.
		if record.isFullSprinting then
			return MovementConstants.SlideMaxSpeed * MovementConstants.SprintSlideMaxSpeedMultiplier
		end
		return MovementConstants.SlideMaxSpeed
	end
	if record.isCrouching then
		return MovementConstants.CrouchSpeed
	end
	if record.isFullSprinting then
		return MovementConstants.SprintSpeed
	end
	return if record.isSprinting then MovementConstants.RunSpeed else MovementConstants.WalkSpeed
end

local MovementValidationService = {}
MovementValidationService.__index = MovementValidationService

export type MovementValidationService = typeof(setmetatable(
	{} :: {
		_records: { [Player]: PlayerMovementRecord },
	},
	MovementValidationService
))

function MovementValidationService.new(): MovementValidationService
	local self = setmetatable({
		_records = {},
	}, MovementValidationService)

	return self
end

function MovementValidationService._onCharacterAdded(self: MovementValidationService, player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
	humanoid.WalkSpeed = MovementConstants.WalkSpeed

	self._records[player] = {
		humanoid = humanoid,
		rootPart = rootPart,
		lastSprintRequestTime = 0,
		isSprinting = false,
		isFullSprinting = false,
		lastFullSprintRequestTime = 0,
		lastSlideRequestTime = 0,
		isSliding = false,
		slideFlatSince = nil,
		lastCrouchRequestTime = 0,
		isCrouching = false,
		dashCooldowns = newDashCooldownStates(),
		lastDashCategory = DashCategory.Forward,
		lastAirDashTime = -math.huge,
		speedCheckExemptUntil = 0,
		wasAirborne = false,
		pendingLandingSettleGrace = false,
		hasDoubleJumped = false,
		rollCancelCharges = MovementConstants.RollCancelMaxCharges,
		rollCancelChargeRegenStart = os.clock(),
		lastPosition = rootPart.Position,
		lastCheckTime = os.clock(),
		speedViolationStreak = 0,
		lastAbilityRequestTime = {},
	}
end

-- Shared floor for abilities with no cooldown/charge of their own -- see
-- MovementValidationConstants.MinAbilityRequestInterval. Checked first, before any real per-request
-- work (a physics query, a raycast), so spamming the remote can't multiply that cost.
function MovementValidationService._throttleAbilityRequest(_self: MovementValidationService, record: PlayerMovementRecord, key: string): boolean
	local now = os.clock()
	if now - (record.lastAbilityRequestTime[key] or 0) < MovementValidationConstants.MinAbilityRequestInterval then
		return false
	end
	record.lastAbilityRequestTime[key] = now
	return true
end

function MovementValidationService._onRequestDash(self: MovementValidationService, player: Player, category: unknown)
	if typeof(category) ~= "string" or not MovementConstants.DashCooldowns[category] then
		return
	end

	local record = self._records[player]
	if not record or not player.Character then
		return
	end

	local now = os.clock()
	local cooldown = record.dashCooldowns[category]

	if now - cooldown.lastDashTime < MovementConstants.DashCooldowns[category] then
		return
	end

	cooldown.lastDashTime = now
	record.lastDashCategory = category
	record.speedCheckExemptUntil = now + MovementConstants.DashDuration
end

-- Airborne movement is already fully exempt from the speed check (see isAirborne in
-- _validatePlayer), so this is only cooldown + legality (must actually be airborne) enforcement --
-- the speedCheckExemptUntil grant below just covers the brief settle time right after landing,
-- same reasoning as the ground dash's own grant.
function MovementValidationService._onRequestAirDash(self: MovementValidationService, player: Player)
	local record = self._records[player]
	if not record or not player.Character then
		return
	end

	local now = os.clock()
	if now - record.lastAirDashTime < MovementConstants.AirDashCooldown then
		return
	end

	if not isAirborne(record.humanoid) then
		warn(string.format("[Anti-Exploit] %s attempted an air dash while grounded.", player.Name))
		return
	end

	if not PlayerVitalsService:Spend(player, "Qinggong", MovementConstants.QinggongCostAirDash) then
		warn(string.format("[Anti-Exploit] %s attempted an air dash with insufficient Qinggong.", player.Name))
		return
	end

	record.lastAirDashTime = now
	record.speedCheckExemptUntil = now + MovementConstants.AirDashDuration
	record.pendingLandingSettleGrace = true
end

-- Only overwrites vertical velocity (see DoubleJumpController), so there's nothing here for the
-- horizontal speed check to be tricked by -- airborne exemption already covers the whole arc, and
-- legality is just "actually airborne" + "hasn't already used this excursion's charge."
function MovementValidationService._onRequestDoubleJump(self: MovementValidationService, player: Player)
	local record = self._records[player]
	if not record or not player.Character then
		return
	end

	if not self:_throttleAbilityRequest(record, "DoubleJump") then
		return
	end

	if not isAirborne(record.humanoid) then
		warn(string.format("[Anti-Exploit] %s attempted a double jump while grounded.", player.Name))
		return
	end

	if record.hasDoubleJumped then
		warn(string.format("[Anti-Exploit] %s attempted multiple double jumps in one airborne cycle.", player.Name))
		return
	end

	if not PlayerVitalsService:Spend(player, "Qinggong", MovementConstants.QinggongCostDoubleJump) then
		warn(string.format("[Anti-Exploit] %s attempted a double jump with insufficient Qinggong.", player.Name))
		return
	end

	record.hasDoubleJumped = true
end

-- Unlike the other Qinggong actions, legality here isn't cooldown/charge-gated at all -- it's
-- purely spatial ("was there actually a ledge to jump off"), independently re-checked with the
-- server's own raycast rather than trusting the client's claim. Forward direction comes off actual
-- velocity (not CFrame.LookVector) since a slide can carry the character in a direction it isn't
-- necessarily facing; the extra forward range accounts for how far the client's own position
-- estimate can have drifted from the server's by the time this arrives.
function MovementValidationService._onRequestLedgeJump(self: MovementValidationService, player: Player)
	local record = self._records[player]
	local character = player.Character
	if not record or not character then
		return
	end

	if not self:_throttleAbilityRequest(record, "LedgeJump") then
		return
	end

	local rootPart = record.rootPart
	local velocity = rootPart.AssemblyLinearVelocity
	local flatVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local forwardDirection = if flatVelocity.Magnitude > 0.001 then flatVelocity.Unit else rootPart.CFrame.LookVector
	local origin = rootPart.Position + (forwardDirection * MovementConstants.LedgeJumpServerEdgeCheckForward)

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }

	local downRay = workspace:Raycast(origin, Vector3.new(0, -MovementConstants.LedgeJumpEdgeCheckDown, 0), rayParams)
	if downRay then
		warn(string.format("[Anti-Exploit] %s claimed a ledge jump with ground still ahead.", player.Name))
		return
	end

	if not PlayerVitalsService:Spend(player, "Qinggong", MovementConstants.QinggongCostLedgeJump) then
		warn(string.format("[Anti-Exploit] %s attempted a ledge jump with insufficient Qinggong.", player.Name))
		return
	end

	record.pendingLandingSettleGrace = true
end

-- Wall running holds the character airborne (off the ground, against a wall) for its entire
-- variable duration, so the existing isAirborne bypass in _validatePlayer already fully exempts it
-- from the speed check -- no exemption window needs granting here, just legality: actually
-- airborne, and an actual wall nearby to run along instead of empty air.
function MovementValidationService._onRequestWallRun(self: MovementValidationService, player: Player)
	local record = self._records[player]
	local character = player.Character
	if not record or not character then
		return
	end

	if not self:_throttleAbilityRequest(record, "WallRun") then
		return
	end

	if not isAirborne(record.humanoid) then
		warn(string.format("[Anti-Exploit] %s attempted a wall run while grounded.", player.Name))
		return
	end

	if not isNearWall(character, player) then
		warn(string.format("[Anti-Exploit] %s attempted a wall run with no wall nearby.", player.Name))
		return
	end

	if not PlayerVitalsService:Spend(player, "Qinggong", MovementConstants.QinggongCostWallRun) then
		warn(string.format("[Anti-Exploit] %s attempted a wall run with insufficient Qinggong.", player.Name))
		return
	end

	-- The run's own WallRunSpeed carries into whatever happens right after it ends (a leap, or
	-- falling into a landing) faster than WalkSpeed-based validation would allow -- same settle-time
	-- reasoning as the other aerial actions, granted the moment landing is actually observed.
	record.pendingLandingSettleGrace = true
end

-- A one-shot outward burst off the wall run, same legality shape as the run itself -- checked
-- independently rather than trusting that a valid RequestWallRun necessarily preceded it.
function MovementValidationService._onRequestWallLeap(self: MovementValidationService, player: Player)
	local record = self._records[player]
	local character = player.Character
	if not record or not character then
		return
	end

	if not self:_throttleAbilityRequest(record, "WallLeap") then
		return
	end

	if not isAirborne(record.humanoid) then
		warn(string.format("[Anti-Exploit] %s attempted a wall leap while grounded.", player.Name))
		return
	end

	if not isNearWall(character, player) then
		warn(string.format("[Anti-Exploit] %s attempted a wall leap with no wall nearby.", player.Name))
		return
	end

	if not PlayerVitalsService:Spend(player, "Qinggong", MovementConstants.QinggongCostWallLeap) then
		warn(string.format("[Anti-Exploit] %s attempted a wall leap with insufficient Qinggong.", player.Name))
		return
	end

	record.pendingLandingSettleGrace = true
end

-- Grabbing a wall dead ahead holds the character airborne (off the ground, against a wall) for a
-- variable duration, same isAirborne-exemption reasoning as wall running -- legality here is just
-- "actually airborne" and "an actual wall nearby," not a speed-check exemption window.
function MovementValidationService._onRequestWallCling(self: MovementValidationService, player: Player)
	local record = self._records[player]
	local character = player.Character
	if not record or not character then
		return
	end

	if not self:_throttleAbilityRequest(record, "WallCling") then
		return
	end

	if not isAirborne(record.humanoid) then
		warn(string.format("[Anti-Exploit] %s attempted a wall cling while grounded.", player.Name))
		return
	end

	if not isNearWall(character, player) then
		warn(string.format("[Anti-Exploit] %s attempted a wall cling with no wall nearby.", player.Name))
		return
	end

	if not PlayerVitalsService:Spend(player, "Qinggong", MovementConstants.QinggongCostWallCling) then
		warn(string.format("[Anti-Exploit] %s attempted a wall cling with insufficient Qinggong.", player.Name))
		return
	end

	record.pendingLandingSettleGrace = true
end

-- A one-shot outward+upward burst off a wall cling, same legality shape as the leaps above --
-- checked independently rather than trusting that a valid RequestWallCling necessarily preceded it.
function MovementValidationService._onRequestWallBoost(self: MovementValidationService, player: Player)
	local record = self._records[player]
	local character = player.Character
	if not record or not character then
		return
	end

	if not self:_throttleAbilityRequest(record, "WallBoost") then
		return
	end

	if not isAirborne(record.humanoid) then
		warn(string.format("[Anti-Exploit] %s attempted a wall boost while grounded.", player.Name))
		return
	end

	if not isNearWall(character, player) then
		warn(string.format("[Anti-Exploit] %s attempted a wall boost with no wall nearby.", player.Name))
		return
	end

	if not PlayerVitalsService:Spend(player, "Qinggong", MovementConstants.QinggongCostWallBoost) then
		warn(string.format("[Anti-Exploit] %s attempted a wall boost with insufficient Qinggong.", player.Name))
		return
	end

	record.pendingLandingSettleGrace = true
end

-- Only overwrites vertical velocity (see WallClingController), same shape as an ordinary double
-- jump -- nothing here for the horizontal speed check to be tricked by, and no wall/chain gate at
-- all since it's a generic mid-air recovery hop, not a wall-contact ability. Legality is entirely
-- the client's own deadline window, enforced by the transition table.
function MovementValidationService._onRequestWallClingDoubleJump(self: MovementValidationService, player: Player)
	local record = self._records[player]
	if not record or not player.Character then
		return
	end

	if not self:_throttleAbilityRequest(record, "WallClingDoubleJump") then
		return
	end

	if not isAirborne(record.humanoid) then
		warn(string.format("[Anti-Exploit] %s attempted a wall cling double jump while grounded.", player.Name))
		return
	end

	if not PlayerVitalsService:Spend(player, "Qinggong", MovementConstants.QinggongCostWallClingDoubleJump) then
		warn(string.format("[Anti-Exploit] %s attempted a wall cling double jump with insufficient Qinggong.", player.Name))
		return
	end
end

-- WallHanging's own release move (a leap off the wall) -- same legality shape as WallBoost above.
function MovementValidationService._onRequestWallClimbLeap(self: MovementValidationService, player: Player)
	local record = self._records[player]
	local character = player.Character
	if not record or not character then
		return
	end

	if not self:_throttleAbilityRequest(record, "WallClimbLeap") then
		return
	end

	if not isAirborne(record.humanoid) then
		warn(string.format("[Anti-Exploit] %s attempted a wall climb leap while grounded.", player.Name))
		return
	end

	if not isNearWall(character, player) then
		warn(string.format("[Anti-Exploit] %s attempted a wall climb leap with no wall nearby.", player.Name))
		return
	end

	if not PlayerVitalsService:Spend(player, "Qinggong", MovementConstants.QinggongCostWallClimbLeap) then
		warn(string.format("[Anti-Exploit] %s attempted a wall climb leap with insufficient Qinggong.", player.Name))
		return
	end

	record.pendingLandingSettleGrace = true
end

-- Dedicated action, not inferred from timing -- leaving Dashing early also happens for reasons
-- that have nothing to do with a roll cancel (a jump interrupting the dash) and those must stay
-- free of this charge gate. Legitimacy here is "the server's own dash window is still open," the
-- same window _validatePlayer uses to exempt the speed check.
function MovementValidationService._onRequestRollCancel(self: MovementValidationService, player: Player)
	local record = self._records[player]
	if not record or not player.Character then
		return
	end

	local now = os.clock()
	if now >= record.speedCheckExemptUntil then
		return
	end

	record.rollCancelCharges, record.rollCancelChargeRegenStart = regenCharges(
		record.rollCancelCharges,
		record.rollCancelChargeRegenStart,
		now,
		MovementConstants.RollCancelMaxCharges,
		MovementConstants.RollCancelChargeCooldown
	)

	if record.rollCancelCharges <= 0 then
		warn(string.format("[Anti-Exploit] %s attempted a roll cancel with no charges remaining.", player.Name))
		return
	end
	record.rollCancelCharges -= 1

	-- The exemption doesn't end at this exact instant: the residual velocity left over from the
	-- dash doesn't simply stick once set -- Humanoid's own ground controller keeps independently
	-- driving velocity off WalkSpeed/MoveDirection every physics step, so the two transiently
	-- combine before settling. This buys that settling time before strict speed validation
	-- resumes, instead of rubberbanding the player mid-transient.
	record.speedCheckExemptUntil = now + MovementValidationConstants.DashCancelExemptionGrace
	record.lastPosition = record.rootPart.Position
	record.lastCheckTime = now

	-- once per window; blocks cancel->redash->cancel abuse
	local cooldown = record.dashCooldowns[record.lastDashCategory]
	if now - cooldown.lastDashCooldownResetAt >= MovementConstants.DashCooldowns[record.lastDashCategory] then
		cooldown.lastDashTime = -math.huge
		cooldown.lastDashCooldownResetAt = now
	end
end

function MovementValidationService._onRequestSprint(self: MovementValidationService, player: Player, wantsToSprint: unknown)
	if typeof(wantsToSprint) ~= "boolean" then
		return
	end

	local record = self._records[player]
	if not record or not player.Character then
		return
	end

	local now = os.clock()
	if now - record.lastSprintRequestTime < MovementValidationConstants.SprintRequestCooldown then
		return
	end
	record.lastSprintRequestTime = now

	record.isSprinting = wantsToSprint
	record.humanoid.WalkSpeed = computeWalkSpeed(record)
end

-- SprintController fires this at the fully-ramped boundary (entering/leaving the Sprinting state),
-- then keeps re-firing it true on MovementConstants.FullSprintRenewalInterval for as long as
-- IsSprintActive() stays true (Sprinting itself, or a carried boost through Sliding/WallRunning/
-- etc.) -- the ramp itself (SprintCharging) never leaves Running's WalkSpeed*SpeedTolerance
-- allowance, so the server doesn't need to mirror the client's per-frame ramp, just raise its own
-- WalkSpeed ceiling once the technique is actually complete, and keep it renewed like isSliding
-- below rather than trusting a single claim forever (_validatePlayer expires it otherwise).
function MovementValidationService._onRequestSprintTechnique(self: MovementValidationService, player: Player, isFullSprinting: unknown)
	if typeof(isFullSprinting) ~= "boolean" then
		return
	end

	local record = self._records[player]
	if not record or not player.Character then
		return
	end

	-- Deliberately free of any Qinggong cost/check -- sprinting stays available regardless of the
	-- pool (see VitalsConstants.QinggongRegenDelay's own comment for how spam of the OTHER Qinggong
	-- abilities is kept in check instead).
	record.isFullSprinting = isFullSprinting
	record.humanoid.WalkSpeed = computeWalkSpeed(record)
	if isFullSprinting then
		record.lastFullSprintRequestTime = os.clock()
		record.speedCheckExemptUntil =
			math.max(record.speedCheckExemptUntil, os.clock() + MovementValidationConstants.FullSprintSettleGrace)
	end
end

function MovementValidationService._onRequestSlide(self: MovementValidationService, player: Player, isSliding: unknown)
	if typeof(isSliding) ~= "boolean" then
		return
	end

	local record = self._records[player]
	local character = player.Character
	if not record or not character then
		return
	end

	-- Ending a slide always goes through immediately, bypassing the cooldown below -- a dropped
	-- "stop" here would leave the player permanently exempted at SlideMaxSpeed, unlike a dropped
	-- "start" which only delays the slide by a fraction of a second.
	if not isSliding then
		record.isSliding = false
		record.slideFlatSince = nil
		record.humanoid.WalkSpeed = computeWalkSpeed(record)
		return
	end

	local now = os.clock()
	if now - record.lastSlideRequestTime < MovementValidationConstants.SlideRequestCooldown then
		return
	end

	-- Independently re-checked (not just trusted) on every start AND every renewal -- a modified
	-- client claiming isSliding=true with no ground underneath is exactly how the original exploit
	-- locked in SlideMaxSpeed permanently off a single request.
	if not isOverGround(character) then
		warn(string.format("[Anti-Exploit] %s claimed a slide with no ground beneath.", player.Name))
		return
	end

	record.lastSlideRequestTime = now
	record.isSliding = true
	-- Defensive reset, not strictly required (every path that turns isSliding off already clears
	-- this) -- keeps a fresh slide from ever inheriting a stale timestamp from a previous one.
	record.slideFlatSince = nil
	record.humanoid.WalkSpeed = computeWalkSpeed(record)
end

function MovementValidationService._onRequestCrouch(self: MovementValidationService, player: Player, isCrouching: unknown)
	if typeof(isCrouching) ~= "boolean" then
		return
	end

	local record = self._records[player]
	if not record or not player.Character then
		return
	end

	if not isCrouching then
		record.isCrouching = false
		record.humanoid.WalkSpeed = computeWalkSpeed(record)
		return
	end

	local now = os.clock()
	if now - record.lastCrouchRequestTime < MovementValidationConstants.CrouchRequestCooldown then
		return
	end
	record.lastCrouchRequestTime = now

	record.isCrouching = true
	record.humanoid.WalkSpeed = computeWalkSpeed(record)
	record.speedCheckExemptUntil = math.max(record.speedCheckExemptUntil, now + MovementValidationConstants.CrouchSpeedSettleGrace)
end

function MovementValidationService._validatePlayer(_self: MovementValidationService, player: Player, record: PlayerMovementRecord, now: number)
	local character = player.Character
	if not character then
		return
	end

	local humanoid, rootPart = record.humanoid, record.rootPart
	local airborneNow = isAirborne(humanoid)

	-- State hygiene, not a speed fix (see the airborne speed check below, which no longer trusts
	-- WalkSpeed at all while airborne): a dropped RequestSlide(false) packet could otherwise leave
	-- isSliding=true lying about reality for as long as the player stays airborne -- other systems
	-- that might read it later (animation sync, a future combat system asking "is this player
	-- currently sliding") shouldn't see a slide that's no longer physically happening. Checked first,
	-- before any of the renewal/slope logic below, so the rest of this tick sees corrected state.
	if airborneNow and record.isSliding then
		record.isSliding = false
		record.slideFlatSince = nil
		humanoid.WalkSpeed = computeWalkSpeed(record)
	end

	-- Renewal timeout: SlideController re-fires RequestSlide(true) every SlideRenewalInterval for as
	-- long as the slide continues, so a live slide's lastSlideRequestTime never gets this stale. If it
	-- does -- the client stopped renewing, or never was legitimately sliding at all -- drop back to
	-- computeWalkSpeed's normal value instead of leaving SlideMaxSpeed granted off a stale claim.
	if record.isSliding and now - record.lastSlideRequestTime >= MovementValidationConstants.SlideRenewalGraceWindow then
		record.isSliding = false
		record.slideFlatSince = nil
		humanoid.WalkSpeed = computeWalkSpeed(record)
	end

	-- Same renewal-timeout idea for the Qinggong Sprinting technique: SprintController re-fires
	-- RequestSprintTechnique(true) every FullSprintRenewalInterval for as long as IsSprintActive()
	-- stays true, so a live full sprint's lastFullSprintRequestTime never gets this stale. If it does,
	-- drop isFullSprinting back off instead of leaving SprintSpeed granted off a stale claim.
	if record.isFullSprinting and now - record.lastFullSprintRequestTime >= MovementValidationConstants.FullSprintRenewalGraceWindow then
		record.isFullSprinting = false
		humanoid.WalkSpeed = computeWalkSpeed(record)
	end

	-- The renewal timeout above only proves the client is still CLAIMING a slide, not that there's
	-- still a real slope justifying one -- an exploiter can keep RequestSlide(true) renewals flowing
	-- indefinitely on completely flat ground, which the renewal check alone can't catch. Mirror the
	-- client's own SlideController flat-ground decay-to-end timer (SlideFrictionDuration) here
	-- independently: once non-steep ground has been seen for that long (plus a small network grace),
	-- force the slide off, same as a legitimate client already does to itself.
	if record.isSliding then
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = { character }

		local slopeAngle = getSlopeAngle(character, rayParams)
		local isSteep = slopeAngle ~= nil and slopeAngle >= MovementConstants.SlideSteepSlopeAngle
		-- Slope ANGLE alone doesn't say which way the player is actually traveling -- a modified
		-- client can hold a slide facing straight up a >=20deg incline, which reads as "steep" just
		-- the same, permanently resetting slideFlatSince and bypassing the timeout entirely while
		-- riding SlideMaxSpeed uphill with no time limit. Require real downward vertical velocity too
		-- (a cheap proxy, not full slope-projected velocity math -- see
		-- SlideDownhillVelocityThreshold's own comment) before treating the slope as one actually
		-- being slid down.
		local isMovingDownhill = rootPart.AssemblyLinearVelocity.Y < MovementValidationConstants.SlideDownhillVelocityThreshold

		if isSteep and isMovingDownhill then
			record.slideFlatSince = nil
		else
			record.slideFlatSince = record.slideFlatSince or now
			if now - record.slideFlatSince > MovementConstants.SlideFrictionDuration + MovementValidationConstants.SlideFlatGroundNetworkGrace then
				record.isSliding = false
				record.slideFlatSince = nil
				record.humanoid.WalkSpeed = computeWalkSpeed(record)
				warn(string.format("[Anti-Exploit] %s held flat-ground slide too long.", player.Name))
			end
		end
	end

	if record.wasAirborne and not airborneNow then
		if record.pendingLandingSettleGrace then
			record.pendingLandingSettleGrace = false
			record.speedCheckExemptUntil = math.max(record.speedCheckExemptUntil, now + MovementValidationConstants.AerialActionLandingSettleGrace)
		end
		record.hasDoubleJumped = false
	end
	record.wasAirborne = airborneNow

	-- Airborne players used to skip this whole check for as long as they stayed airborne -- not just
	-- during a dash/leap's own brief exemption window -- letting a modified client set
	-- AssemblyLinearVelocity to anything mid-air with zero governance. Only the timed exemption below
	-- (a real ability's own burst) still bypasses the check entirely; airborne now runs it too, just
	-- against MaxAirborneHorizontalSpeed instead of WalkSpeed (see baseSpeed below).
	if now < record.speedCheckExemptUntil then
		record.lastPosition = rootPart.Position
		record.lastCheckTime = now
		record.speedViolationStreak = 0
		return
	end

	local elapsed = now - record.lastCheckTime
	if elapsed > 0 then
		local currentPosition = rootPart.Position
		local horizontalDelta = Vector3.new(
			currentPosition.X - record.lastPosition.X,
			0,
			currentPosition.Z - record.lastPosition.Z
		)
		local baseSpeed = if airborneNow then MovementConstants.MaxAirborneHorizontalSpeed else humanoid.WalkSpeed
		-- Grounded SpeedTolerance (2.5x) absorbs Humanoid's own animation/ground-controller jitter --
		-- airborne motion is a clean physics trajectory with no animation fighting it, so it gets the
		-- tighter AirborneSpeedTolerance instead (see that constant's own comment for the math this
		-- was sized against). Reusing SpeedTolerance here would've allowed 375 studs/s, far looser
		-- than MaxAirborneHorizontalSpeed was meant to enforce.
		local tolerance = if airborneNow then MovementConstants.AirborneSpeedTolerance else MovementConstants.SpeedTolerance
		local maxAllowedDistance = baseSpeed * tolerance * elapsed

		local horizontalViolated = horizontalDelta.Magnitude > maxAllowedDistance

		-- Vertical ascent governance: nothing else in this file checks vertical velocity/position at
		-- all, and wall running in particular holds a player airborne indefinitely with no server
		-- enforcement of WallRunGravity, so a modified client could otherwise push
		-- AssemblyLinearVelocity.Y upward and climb into the skybox completely unchecked. Sampled as a
		-- position delta over the same elapsed window as the horizontal check (not a raw instantaneous
		-- velocity read) so a single-frame physics spike -- a landing impulse, a collision bounce --
		-- can't false-positive it. Only ascending delta is ever flagged: falling is normal physics with
		-- no exploit value, and Roblox gravity has no default terminal velocity, so capping descent
		-- would false-positive long legitimate falls.
		local verticalDelta = currentPosition.Y - record.lastPosition.Y
		local maxAllowedVerticalRise = MovementConstants.MaxVerticalAscendSpeed * MovementConstants.AirborneSpeedTolerance * elapsed
		local verticalViolated = verticalDelta > maxAllowedVerticalRise

		-- Shared streak/rubberband flow for both axes (not a second independent counter) -- either
		-- axis contributes to the same escalation, and a single rubberband (resetting the full CFrame,
		-- not just the horizontal component) naturally corrects both at once.
		if horizontalViolated or verticalViolated then
			record.speedViolationStreak += 1

			if record.speedViolationStreak >= MovementValidationConstants.SpeedViolationStreakThreshold then
				if horizontalViolated then
					warn(string.format(
						"[Anti-Exploit] %s moved %.1f studs in %.3fs (max %.1f at %s speed %.1f) -- snapped back",
						player.Name,
						horizontalDelta.Magnitude,
						elapsed,
						maxAllowedDistance,
						if airborneNow then "airborne" else "WalkSpeed",
						baseSpeed
					))
				end
				if verticalViolated then
					warn(string.format(
						"[Anti-Exploit] %s ascended %.1f studs in %.3fs (max %.1f) -- snapped back",
						player.Name,
						verticalDelta,
						elapsed,
						maxAllowedVerticalRise
					))
				end
				rootPart.CFrame = CFrame.new(record.lastPosition) * rootPart.CFrame.Rotation
				record.speedViolationStreak = 0
			end
		else
			record.speedViolationStreak = 0
		end
	end

	record.lastPosition = rootPart.Position
	record.lastCheckTime = now
end

function MovementValidationService._onHeartbeat(self: MovementValidationService)
	local now = os.clock()

	for player, record in pairs(self._records) do
		self:_validatePlayer(player, record, now)
	end
end

function MovementValidationService.Init(self: MovementValidationService)
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
		self._records[player] = nil
	end)

	requestSprint.OnServerEvent:Connect(function(player: Player, wantsToSprint: unknown)
		self:_onRequestSprint(player, wantsToSprint)
	end)

	requestSprintTechnique.OnServerEvent:Connect(function(player: Player, isFullSprinting: unknown)
		self:_onRequestSprintTechnique(player, isFullSprinting)
	end)

	requestDash.OnServerEvent:Connect(function(player: Player, category: unknown)
		self:_onRequestDash(player, category)
	end)

	requestAirDash.OnServerEvent:Connect(function(player: Player)
		self:_onRequestAirDash(player)
	end)

	requestDoubleJump.OnServerEvent:Connect(function(player: Player)
		self:_onRequestDoubleJump(player)
	end)

	requestLedgeJump.OnServerEvent:Connect(function(player: Player)
		self:_onRequestLedgeJump(player)
	end)

	requestRollCancel.OnServerEvent:Connect(function(player: Player)
		self:_onRequestRollCancel(player)
	end)

	requestSlide.OnServerEvent:Connect(function(player: Player, isSliding: unknown)
		self:_onRequestSlide(player, isSliding)
	end)

	requestCrouch.OnServerEvent:Connect(function(player: Player, isCrouching: unknown)
		self:_onRequestCrouch(player, isCrouching)
	end)

	requestWallRun.OnServerEvent:Connect(function(player: Player)
		self:_onRequestWallRun(player)
	end)

	requestWallLeap.OnServerEvent:Connect(function(player: Player)
		self:_onRequestWallLeap(player)
	end)

	requestWallCling.OnServerEvent:Connect(function(player: Player)
		self:_onRequestWallCling(player)
	end)

	requestWallBoost.OnServerEvent:Connect(function(player: Player)
		self:_onRequestWallBoost(player)
	end)

	requestWallClingDoubleJump.OnServerEvent:Connect(function(player: Player)
		self:_onRequestWallClingDoubleJump(player)
	end)

	requestWallClimbLeap.OnServerEvent:Connect(function(player: Player)
		self:_onRequestWallClimbLeap(player)
	end)

	local nextValidationTime = 0
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now < nextValidationTime then
			return
		end
		nextValidationTime = now + MovementValidationConstants.ValidationTickRate

		self:_onHeartbeat()
	end)
end

return MovementValidationService.new()
