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

-- Identifies which grant last set speedCheckExemptUntil/speedCheckExemptBaseSpeed, so a check like
-- _onRequestRollCancel's can verify WHICH exemption is currently active, not just THAT one is --
-- value alone can't distinguish them (DashPower and MaxAirborneHorizontalSpeed are both 150 in this
-- codebase, so a numeric comparison would silently break the moment any constant gets retuned to
-- coincide with another). Same flat string-enum shape as Shared.Enums.MovementState/DashCategory,
-- kept local to this file since nothing outside it needs to know a player's exemption reason.
type SpeedExemptReason = string
local SpeedExemptReason = table.freeze({
	None = "None" :: SpeedExemptReason,
	Dash = "Dash" :: SpeedExemptReason,
	AirDash = "AirDash" :: SpeedExemptReason,
	RollCancel = "RollCancel" :: SpeedExemptReason,
	AerialLanding = "AerialLanding" :: SpeedExemptReason,
	CrouchSettle = "CrouchSettle" :: SpeedExemptReason,
	FullSprintSettle = "FullSprintSettle" :: SpeedExemptReason,
	WallLeap = "WallLeap" :: SpeedExemptReason,
	WallClimbLeap = "WallClimbLeap" :: SpeedExemptReason,
})

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
	-- While now < this, _validatePlayer checks against speedCheckExemptBaseSpeed instead of
	-- humanoid.WalkSpeed -- covers a dash's own velocity burst, and any other transient (e.g. residual
	-- walking momentum not yet decayed to a just-lowered WalkSpeed) too fast for WalkSpeed-based
	-- validation to tell from a speed hack. Deliberately NOT a full bypass of the check (that would
	-- give a modified client a zero-governance teleport window for the whole grace period) -- see
	-- speedCheckExemptBaseSpeed.
	speedCheckExemptUntil: number,
	-- The ceiling _validatePlayer checks against while now < speedCheckExemptUntil, set alongside it
	-- at every call site to whatever that specific grant's own real max speed is (DashPower for a
	-- ground dash or its roll-cancel settle, MaxAirborneHorizontalSpeed for an aerial action's landing
	-- settle, SprintSpeed/WalkSpeed-or-RunSpeed for the sprint/crouch settles) -- a blanket "no check
	-- at all" was too permissive, but a single shared ceiling would be wrong for most of these too.
	speedCheckExemptBaseSpeed: number,
	-- Which grant last set the two fields above -- see SpeedExemptReason's own comment for why this
	-- exists (numeric value alone can't tell two same-valued grants apart).
	speedCheckExemptReason: SpeedExemptReason,
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

-- Humanoid:GetState() is NOT server-authoritative for a player's own character. Roblox network-owns
-- a player's character parts to that player's client by default (this codebase never calls
-- SetNetworkOwner to change that), and Humanoid state transitions (Running/Jumping/Freefall/Landed)
-- are physics-derived -- computed on whichever side owns that physics, which for a player's own
-- Humanoid is the client, with the resulting state then replicated to the server as an ordinary
-- property, same as CFrame/AssemblyLinearVelocity already are (both of which this file already
-- treats as untrusted -- see isNearWall/isOverGround/getSlopeAngle above). This project's OWN client
-- code confirms ChangeState is an ordinary, reachable API with real effect for a player's own
-- Humanoid: WallRunController._tryWallLeap and WallClingController._tryWallClimbLeap both call
-- humanoid:ChangeState(Enum.HumanoidStateType.Freefall) directly from a LocalScript. A modified
-- client could call the same API with any state it likes and have GetState() report it server-side
-- too, bypassing every legality check gated on this function regardless of real physical position.
-- Independently verified instead via a downward raycast -- the same "don't trust a client-owned
-- physics property" pattern as the other coarse geometry checks in this file.
local function isAirborne(character: Model, record: PlayerMovementRecord): boolean
	local humanoid, rootPart = record.humanoid, record.rootPart

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }

	-- HipHeight + half the root part's height approximates the distance from rootPart.Position (its
	-- center) down to the character's feet when standing normally -- derived from the character's own
	-- proportions rather than a guessed fixed stud value, since HipHeight varies by rig/avatar.
	-- GroundCheckMargin is a small buffer on top for uneven terrain/stairs/ramps, same coarse-check
	-- spirit as this file's other geometry sanity checks, not pixel-perfect collision.
	local groundCheckDistance = humanoid.HipHeight + (rootPart.Size.Y / 2) + MovementValidationConstants.GroundCheckMargin
	local hasGroundNearby = workspace:Raycast(rootPart.Position, Vector3.new(0, -groundCheckDistance, 0), rayParams) ~= nil

	-- Ground-distance alone isn't enough: the instant a legitimate jump starts, Y position (and so
	-- this raycast) hasn't moved yet, so a real jump/double-jump/air-dash attempted in its very first
	-- tick or two would still see "ground within range" and be wrongly rejected. Widen with vertical
	-- velocity too -- meaningfully non-zero in EITHER direction also counts as airborne, even while
	-- still within raycast range.
	--
	-- Derived from a SERVER-OBSERVED position delta, NOT raw rootPart.AssemblyLinearVelocity.Y --
	-- that's client-owned and spoofable, and unlike isNearWall's latency projection, this function's
	-- result doesn't just gate ability legality: _validatePlayer also uses it to pick its own speed
	-- ceiling (baseSpeed = MaxAirborneHorizontalSpeed when this returns true). A grounded player
	-- spoofing raw velocity past AirborneVerticalVelocityThreshold would get bumped onto that much
	-- higher allowance while standing still, so this must stay just as untrusted as the vertical-ascend
	-- and slide-downhill checks that already made the same switch.
	--
	-- record.lastPosition/record.lastCheckTime are refreshed every ValidationTickRate tick by
	-- _validatePlayer regardless of when THIS function is called -- one of the 8 ability-request
	-- handlers, at an arbitrary time, or _validatePlayer itself -- so they're never more than about one
	-- tick stale, fresh enough to derive a meaningful velocity estimate from. MinVerticalCheckElapsed
	-- guards the one gap that doesn't cover: a call landing so soon after that refresh that the elapsed
	-- denominator is near zero, which would amplify ordinary position jitter into a spurious velocity
	-- reading. Falling back to "not moving" for that instant only narrows this OR-condition for a
	-- moment -- the raycast above remains the real source of truth regardless.
	local verticalCheckElapsed = os.clock() - record.lastCheckTime
	local isMovingVertically = verticalCheckElapsed > MovementValidationConstants.MinVerticalCheckElapsed
		and math.abs((rootPart.Position.Y - record.lastPosition.Y) / verticalCheckElapsed) > MovementValidationConstants.AirborneVerticalVelocityThreshold

	return not hasGroundNearby or isMovingVertically
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
		-- Never actually read while speedCheckExemptUntil is 0 (now < 0 is never true) -- WalkSpeed is
		-- just a sane placeholder rather than leaving it at a meaningless 0.
		speedCheckExemptBaseSpeed = MovementConstants.WalkSpeed,
		speedCheckExemptReason = SpeedExemptReason.None,
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
	-- The dash's own held velocity burst -- DashPower is exactly what WalkSpeed gets replaced by for
	-- the duration, so it's the correct ceiling rather than a full bypass.
	record.speedCheckExemptBaseSpeed = MovementConstants.DashPower
	record.speedCheckExemptReason = SpeedExemptReason.Dash
end

-- Airborne movement is already fully exempt from the speed check (see isAirborne in
-- _validatePlayer), so this is only cooldown + legality (must actually be airborne) enforcement --
-- the speedCheckExemptUntil grant below just covers the brief settle time right after landing,
-- same reasoning as the ground dash's own grant.
function MovementValidationService._onRequestAirDash(self: MovementValidationService, player: Player)
	local record = self._records[player]
	local character = player.Character
	if not record or not character then
		return
	end

	local now = os.clock()
	if now - record.lastAirDashTime < MovementConstants.AirDashCooldown then
		return
	end

	if not isAirborne(character, record) then
		warn(string.format("[Anti-Exploit] %s attempted an air dash while grounded.", player.Name))
		return
	end

	if not PlayerVitalsService:Spend(player, "Qinggong", MovementConstants.QinggongCostAirDash) then
		warn(string.format("[Anti-Exploit] %s attempted an air dash with insufficient Qinggong.", player.Name))
		return
	end

	record.lastAirDashTime = now
	record.speedCheckExemptUntil = now + MovementConstants.AirDashDuration
	-- Airborne the whole time this fires, so the airborne ceiling (comfortably above AirDashSpeed
	-- 112.5) is the right fit -- not ground-dash speed, which this ability never reaches.
	record.speedCheckExemptBaseSpeed = MovementConstants.MaxAirborneHorizontalSpeed
	record.speedCheckExemptReason = SpeedExemptReason.AirDash
	record.pendingLandingSettleGrace = true
end

-- Only overwrites vertical velocity (see DoubleJumpController), so there's nothing here for the
-- horizontal speed check to be tricked by -- airborne exemption already covers the whole arc, and
-- legality is just "actually airborne" + "hasn't already used this excursion's charge."
function MovementValidationService._onRequestDoubleJump(self: MovementValidationService, player: Player)
	local record = self._records[player]
	local character = player.Character
	if not record or not character then
		return
	end

	if not self:_throttleAbilityRequest(record, "DoubleJump") then
		return
	end

	if not isAirborne(character, record) then
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
--
-- FLAGGED, not fixed in this pass: a ground(Sliding)-to-air transition, not airborne-to-airborne like
-- WallLeap/WallClimbLeap, but Sliding is also a SprintCarryState, so the same stale-lower-exemption
-- collision (a FullSprintSettleGrace window from the Sprinting renewal still open when this fires) is
-- structurally possible here too -- LedgeJumpForwardPower (90) already exceeds SprintSpeed (38).
-- Worth the same dedicated-exemption treatment if it shows up in testing.
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

	if not isAirborne(character, record) then
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
--
-- WallRunning -> WallLeaping is an airborne-to-airborne transition (both keep the Humanoid in
-- Freefall -- see WallRunController._tryWallLeap's own ChangeState call), so it never passes through
-- _validatePlayer's wasAirborne-and-not-airborneNow landing transition the way a real landing does --
-- nothing here previously granted a speed-check exemption at all, leaving the leap's own burst
-- (WallLeapOutwardPower * SprintWallLeapMultiplier, up to ~115.5 studs/s) validated purely against
-- whatever exemption happened to already be active. That's the confirmed cause of a real,
-- latency-independent rubberband seen in testing: while Qinggong-Sprinting through a wall run (a
-- common case -- SprintWallRunSpeedMultiplier exists specifically for it), the Sprinting technique's
-- own renewal (SprintController, every ~0.5s) keeps re-granting a short FullSprintSettleGrace window
-- at the much lower SprintSpeed (38) ceiling -- active roughly 40% of the time (0.2s out of every
-- 0.5s) for as long as sprinting continues. A leap fired while that window happens to still be open
-- got judged against 38 * AirborneSpeedTolerance instead of the airborne ceiling, easily exceeded by
-- the leap's real ~115.5 studs/s burst. Granting our own exemption here -- an unconditional overwrite,
-- same as the ground dash's -- fixes this the same way a fresh dash overwrites (not merges with)
-- whatever exemption came before it.
function MovementValidationService._onRequestWallLeap(self: MovementValidationService, player: Player)
	local record = self._records[player]
	local character = player.Character
	if not record or not character then
		return
	end

	if not self:_throttleAbilityRequest(record, "WallLeap") then
		return
	end

	if not isAirborne(character, record) then
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

	local now = os.clock()
	record.speedCheckExemptUntil = now + MovementValidationConstants.WallLeapSpeedExemptionGrace
	-- Real max is ~115.5 (WallLeapOutwardPower * SprintWallLeapMultiplier), plus the instant
	-- WallLeapNormalOffset (1.5 studs) nudge applied client-side just before the impulse -- MaxAirborne
	-- HorizontalSpeed (150) comfortably covers both combined for a single validation tick.
	record.speedCheckExemptBaseSpeed = MovementConstants.MaxAirborneHorizontalSpeed
	record.speedCheckExemptReason = SpeedExemptReason.WallLeap
	-- The leap's own burst is covered by the exemption above; this still covers the EVENTUAL real
	-- landing once the leap's arc actually plays out, same as every other aerial action.
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

	if not isAirborne(character, record) then
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
--
-- FLAGGED, not fixed in this pass: same airborne-to-airborne structural gap as WallLeap/WallClimbLeap
-- (WallHanging -> WallBoost never passes through a landing transition either) -- a WallBoost fired
-- while an unrelated lower-ceiling exemption (e.g. FullSprintSettleGrace) is still open could be
-- undervalidated the same way. Lower priority than the leaps: no instant CFrame position offset
-- stacks on top here (WallBoost is a plain AssemblyLinearVelocity overwrite, see WallClingController),
-- and its own max (WallBoostPower * SprintWallJumpMultiplier ~= 108) leaves more headroom under
-- MaxAirborneHorizontalSpeed than the leaps' ~115.5-138 range did, but the same collision is still
-- structurally possible. Worth the same dedicated-exemption treatment if it shows up in testing.
function MovementValidationService._onRequestWallBoost(self: MovementValidationService, player: Player)
	local record = self._records[player]
	local character = player.Character
	if not record or not character then
		return
	end

	if not self:_throttleAbilityRequest(record, "WallBoost") then
		return
	end

	if not isAirborne(character, record) then
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
	local character = player.Character
	if not record or not character then
		return
	end

	if not self:_throttleAbilityRequest(record, "WallClingDoubleJump") then
		return
	end

	if not isAirborne(character, record) then
		warn(string.format("[Anti-Exploit] %s attempted a wall cling double jump while grounded.", player.Name))
		return
	end

	if not PlayerVitalsService:Spend(player, "Qinggong", MovementConstants.QinggongCostWallClingDoubleJump) then
		warn(string.format("[Anti-Exploit] %s attempted a wall cling double jump with insufficient Qinggong.", player.Name))
		return
	end
end

-- WallHanging's own release move (a leap off the wall) -- same legality shape as WallBoost above.
--
-- Same airborne-to-airborne structural gap as WallLeap (WallClingController._tryWallClimbLeap also
-- forces Freefall via ChangeState, and also applies an instant WallClimbLeapNormalOffset CFrame
-- nudge before its impulse) -- see _onRequestWallLeap's own comment for the full mechanism. Fixed the
-- same way: a dedicated, unconditionally-overwriting exemption grant.
function MovementValidationService._onRequestWallClimbLeap(self: MovementValidationService, player: Player)
	local record = self._records[player]
	local character = player.Character
	if not record or not character then
		return
	end

	if not self:_throttleAbilityRequest(record, "WallClimbLeap") then
		return
	end

	if not isAirborne(character, record) then
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

	local now = os.clock()
	record.speedCheckExemptUntil = now + MovementValidationConstants.WallClimbLeapSpeedExemptionGrace
	-- Real max is ~120 (WallClimbLeapOutwardPower * SprintWallJumpMultiplier), plus the instant
	-- WallClimbLeapNormalOffset (1.5 studs) nudge -- MaxAirborneHorizontalSpeed (150) covers both.
	record.speedCheckExemptBaseSpeed = MovementConstants.MaxAirborneHorizontalSpeed
	record.speedCheckExemptReason = SpeedExemptReason.WallClimbLeap
	record.pendingLandingSettleGrace = true
end

-- Dedicated action, not inferred from timing -- leaving Dashing early also happens for reasons
-- that have nothing to do with a roll cancel (a jump interrupting the dash) and those must stay
-- free of this charge gate. Legitimacy here is "the server's own dash window is still open," the
-- same window _validatePlayer uses to exempt the speed check.
--
-- Checking speedCheckExemptUntil alone isn't enough: every grace window in this file (dash,
-- crouch-settle, sprint-settle, aerial-landing-settle, the wall-leap grants) shares that one field,
-- so a player could crouch (which also opens a window, via CrouchSpeedSettleGrace) and immediately
-- fire RequestRollCancel inside it, passing this check despite never having dashed at all --
-- fraudulently setting speedCheckExemptBaseSpeed to DashPower below and spending a real charge for
-- nothing. speedCheckExemptReason confirms WHICH grant is actually open, not just that one is.
function MovementValidationService._onRequestRollCancel(self: MovementValidationService, player: Player)
	local record = self._records[player]
	if not record or not player.Character then
		return
	end

	local now = os.clock()
	if now >= record.speedCheckExemptUntil or record.speedCheckExemptReason ~= SpeedExemptReason.Dash then
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
	-- Same residual dash velocity settling out, same DashPower ceiling as the ground dash itself.
	record.speedCheckExemptBaseSpeed = MovementConstants.DashPower
	-- Deliberately its own reason, not Dash -- a SECOND RequestRollCancel landing inside this same
	-- window (without a real redash in between) should NOT pass the check above; the intended chain
	-- is cancel -> redash (which resets the reason back to Dash) -> cancel again, matching the
	-- "cancel->redash->cancel abuse" the cooldown reset below already guards against.
	record.speedCheckExemptReason = SpeedExemptReason.RollCancel
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
		local settleUntil = os.clock() + MovementValidationConstants.FullSprintSettleGrace
		-- math.max means this grant doesn't always win (an overlapping longer exemption from another
		-- source could already extend past it) -- only take over speedCheckExemptBaseSpeed when this
		-- grant is actually the one extending speedCheckExemptUntil, so the two stay in sync instead of
		-- a shorter-but-later call stomping the base speed a longer exemption is still relying on.
		if settleUntil > record.speedCheckExemptUntil then
			-- The technique's own top speed -- already the ceiling this settle window is easing INTO.
			record.speedCheckExemptBaseSpeed = MovementConstants.SprintSpeed
			record.speedCheckExemptReason = SpeedExemptReason.FullSprintSettle
		end
		record.speedCheckExemptUntil = math.max(record.speedCheckExemptUntil, settleUntil)
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

	-- Captured BEFORE isCrouching flips below -- this settle window exists to cover residual
	-- PRE-crouch velocity decaying toward CrouchSpeed, not the (lower) crouched speed itself.
	local preCrouchSpeed = if record.isSprinting then MovementConstants.RunSpeed else MovementConstants.WalkSpeed

	record.isCrouching = true
	record.humanoid.WalkSpeed = computeWalkSpeed(record)
	local settleUntil = now + MovementValidationConstants.CrouchSpeedSettleGrace
	-- Same "only take over the base speed if this grant is actually the one winning" guard as the
	-- full-sprint settle above -- see its comment.
	if settleUntil > record.speedCheckExemptUntil then
		record.speedCheckExemptBaseSpeed = preCrouchSpeed
		record.speedCheckExemptReason = SpeedExemptReason.CrouchSettle
	end
	record.speedCheckExemptUntil = math.max(record.speedCheckExemptUntil, settleUntil)
end

function MovementValidationService._validatePlayer(_self: MovementValidationService, player: Player, record: PlayerMovementRecord, now: number)
	local character = player.Character
	if not character then
		return
	end

	local humanoid, rootPart = record.humanoid, record.rootPart
	-- Runs a raycast now (see isAirborne's own comment for why GetState() can't be trusted) instead of
	-- a free property read, once per player per ValidationTickRate tick (15Hz) -- the same order of
	-- magnitude as the wall-proximity raycasts (isNearWall) already running elsewhere in this file per
	-- ability request, so this steady-state per-tick cost should be fine, but noting it explicitly
	-- rather than assuming: worth revisiting if this service's player count or tick rate grows a lot.
	local airborneNow = isAirborne(character, record)

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
		--
		-- Derived from server-observed position deltas rather than read off
		-- rootPart.AssemblyLinearVelocity.Y directly -- that's a physics property of a client-owned
		-- part, exactly as spoofable as raw position itself, which is why the vertical-ascent check
		-- above already switched to position-delta math instead of trusting it; this is the same
		-- category of value a few lines away and shouldn't trust it either. record.lastPosition/
		-- record.lastCheckTime still hold the PREVIOUS tick's sample here -- the unconditional update
		-- to this tick's values happens once, at the very end of this function, well after this block
		-- runs -- so this is a genuine server-observed delta, not a same-tick no-op.
		local slideCheckElapsed = now - record.lastCheckTime
		local isMovingDownhill = if slideCheckElapsed > 0
			then (rootPart.Position.Y - record.lastPosition.Y) / slideCheckElapsed < MovementValidationConstants.SlideDownhillVelocityThreshold
			else false

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
			local settleUntil = now + MovementValidationConstants.AerialActionLandingSettleGrace
			-- Same "only take over the base speed if this grant is actually the one winning" guard as
			-- the sprint/crouch settles above -- see their comments.
			if settleUntil > record.speedCheckExemptUntil then
				-- Every ability that grants this (air dash, ledge jump, wall run, wall leap, wall
				-- cling, wall boost, wall climb leap) carries residual AIRBORNE momentum into the
				-- landing -- but an unconditional flat MaxAirborneHorizontalSpeed grant here gave every
				-- landing the full 150 ceiling regardless of how fast the player actually was (a slow
				-- wall-cling drop got the same allowance as a max-speed wall leap), re-triggerable on
				-- every fast jump-chain instead of decaying toward reality. Measured instead from a
				-- server-observed position delta, computed locally here (NOT reusing
				-- horizontalDelta/elapsed from later in this function -- those aren't in scope yet) --
				-- mirrors the same self-contained local-delta pattern the slide-downhill check above
				-- already uses. record.lastPosition/record.lastCheckTime still hold the previous
				-- tick's values at this point, for the same reason noted there.
				local landingCheckElapsed = now - record.lastCheckTime
				if landingCheckElapsed > 0 then
					local landingHorizontalDelta = Vector3.new(
						rootPart.Position.X - record.lastPosition.X,
						0,
						rootPart.Position.Z - record.lastPosition.Z
					)
					local preLandingSpeed =
						math.min(landingHorizontalDelta.Magnitude / landingCheckElapsed, MovementConstants.MaxAirborneHorizontalSpeed)
					-- Floored at normal ground speed (never below it) so a legitimate near-stationary
					-- landing (e.g. dropping straight down off a wall cling) still gets a sane settle
					-- ceiling instead of an unrealistically low one.
					record.speedCheckExemptBaseSpeed = math.max(preLandingSpeed, computeWalkSpeed(record))
				else
					record.speedCheckExemptBaseSpeed = computeWalkSpeed(record)
				end
				record.speedCheckExemptReason = SpeedExemptReason.AerialLanding
			end
			record.speedCheckExemptUntil = math.max(record.speedCheckExemptUntil, settleUntil)
		end
		record.hasDoubleJumped = false
	end
	record.wasAirborne = airborneNow

	-- Airborne players used to skip this whole check for as long as they stayed airborne -- not just
	-- during a dash/leap's own brief exemption window -- letting a modified client set
	-- AssemblyLinearVelocity to anything mid-air with zero governance. Airborne now runs it too, just
	-- against MaxAirborneHorizontalSpeed instead of WalkSpeed (see baseSpeed below).
	--
	-- A speedCheckExemptUntil window used to be a hard early return here -- full invisibility to the
	-- speed check for the whole grace period, not just a raised allowance. Every ability that grants
	-- one (ground dash, roll cancel, the aerial-action landing settle, the sprint/crouch settles) was
	-- treated identically despite having wildly different real max speeds, so a modified client could
	-- teleport arbitrarily far during ANY of them with zero server record of it being invalid. Now it's
	-- folded into the same ceiling selection as the airborne/grounded cases below: still validated,
	-- just against speedCheckExemptBaseSpeed (set alongside speedCheckExemptUntil at each grant site to
	-- that specific ability's own real max speed) instead of a full bypass.
	local elapsed = now - record.lastCheckTime
	if elapsed > 0 then
		local currentPosition = rootPart.Position
		local horizontalDelta = Vector3.new(
			currentPosition.X - record.lastPosition.X,
			0,
			currentPosition.Z - record.lastPosition.Z
		)
		local isExempt = now < record.speedCheckExemptUntil
		-- Whatever ceiling would apply to ORDINARY (non-exempt) motion right now -- computed
		-- unconditionally, not just in the isExempt-false branch, because an exemption's own baseSpeed
		-- is set once at its grant site and can go stale relative to a legitimately-changed WalkSpeed
		-- or airborne state without ever being told to re-check. Concretely: the Qinggong Sprinting
		-- technique's full-sprint settle grant (see _onRequestSprintTechnique) re-fires every
		-- FullSprintRenewalInterval (0.5s) for as long as sprint stays held, each renewal opening a
		-- fresh FullSprintSettleGrace (0.2s) window pinned to SprintSpeed (38) -- so isExempt is true
		-- for ~40% of any sprint's duration (see FullSprintSettleGrace's own comment) off a ceiling far
		-- below what a DIFFERENT, more current source can legitimately demand mid-sprint: WalkSpeed
		-- jumping to SlideMaxSpeed * SprintSlideMaxSpeedMultiplier (175) the instant a sprint-boosted
		-- slide begins, or the airborne ceiling (MaxAirborneHorizontalSpeed, 150) the instant a
		-- wall-run/wall-leap chain goes airborne while that stale exemption happens to still be open.
		local groundOrAirBaseline = if airborneNow then MovementConstants.MaxAirborneHorizontalSpeed else humanoid.WalkSpeed
		-- Deliberately math.max, not a priority chain (never "isExempt wins" or "airborne/grounded
		-- wins" outright): either ordering can silently discard a legitimately higher value from the
		-- side that loses. A strict "isExempt always wins" reintroduces the sprint-settle masking above.
		-- A strict "groundOrAirBaseline always wins while airborne" would instead discard a wall
		-- leap/wall climb leap's OWN dedicated exemption if either ever granted more than the generic
		-- MaxAirborneHorizontalSpeed ceiling (covering its outward burst plus the instant positional
		-- offset applied alongside it) -- silently downgrading a legitimate high-speed leap back to the
		-- generic ceiling and reintroducing false-positive rubberbanding from the opposite direction.
		-- Taking the max of both never discards either value, it just keeps whichever is actually larger.
		local baseSpeed = if isExempt then math.max(record.speedCheckExemptBaseSpeed, groundOrAirBaseline) else groundOrAirBaseline
		-- Grounded SpeedTolerance (2.5x) absorbs Humanoid's own animation/ground-controller jitter --
		-- irrelevant for a genuine physics burst (a clean trajectory with nothing animation-driven
		-- fighting it), which is why airborne motion gets the tighter AirborneSpeedTolerance instead.
		-- But NOT every exemption is a physics burst -- crouch-settle and full-sprint-settle grant much
		-- lower base speeds (WalkSpeed/RunSpeed/SprintSpeed range, not DashPower/MaxAirborneHorizontal
		-- Speed-range), and a legitimate crouch transition's own animation/root-part swing could
		-- plausibly exceed a 1.5x allowance built around a ~16-24 base -- applying the tight tolerance
		-- there would false-positive ordinary crouching, not catch an exploit. isPhysicsBurst separates
		-- the two -- but now that baseSpeed can resolve from EITHER source above, it has to check which
		-- one actually WON, not just whether the raw exemption value in isolation happens to clear the
		-- threshold: a grounded exemption can be at DashPower (150, clears the threshold on its own) and
		-- still lose to an even higher, animation-driven groundOrAirBaseline that overlaps with it (e.g.
		-- a ground dash fired mid-sprint-boosted-slide, WalkSpeed already at 175) -- that grounded,
		-- controller-driven motion should get the looser grounded tolerance regardless of the losing
		-- exemption's own magnitude, the same reasoning crouch-settle/full-sprint-settle already rely on.
		-- Ground dash/roll cancel (DashPower, 150) with no such overlap, the aerial-landing settle's
		-- measured pre-landing speed (capped at MaxAirborneHorizontalSpeed, 150, only for an actually-fast
		-- landing), and wall leap/wall climb leap (MaxAirborneHorizontalSpeed, 150) all still qualify
		-- exactly as before once they're actually the winning source; crouch-settle (WalkSpeed/RunSpeed)
		-- and full-sprint-settle (SprintSpeed, 38) both fall well under the threshold either way.
		local isPhysicsBurst = isExempt
			and record.speedCheckExemptBaseSpeed >= groundOrAirBaseline
			and record.speedCheckExemptBaseSpeed >= MovementConstants.MaxAirborneHorizontalSpeed
		local tolerance = if isPhysicsBurst or airborneNow then MovementConstants.AirborneSpeedTolerance else MovementConstants.SpeedTolerance
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
						if isExempt then "exempt" elseif airborneNow then "airborne" else "WalkSpeed",
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
