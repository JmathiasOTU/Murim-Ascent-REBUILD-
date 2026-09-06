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

local requestSprint = ReplicatedStorage.Remotes.RequestSprint :: RemoteEvent
local requestDash = ReplicatedStorage.Remotes.RequestDash :: RemoteEvent
local requestAirDash = ReplicatedStorage.Remotes.RequestAirDash :: RemoteEvent
local requestDoubleJump = ReplicatedStorage.Remotes.RequestDoubleJump :: RemoteEvent
local requestLedgeJump = ReplicatedStorage.Remotes.RequestLedgeJump :: RemoteEvent
local requestRollCancel = ReplicatedStorage.Remotes.RequestRollCancel :: RemoteEvent
local requestSlide = ReplicatedStorage.Remotes.RequestSlide :: RemoteEvent
local requestCrouch = ReplicatedStorage.Remotes.RequestCrouch :: RemoteEvent

type PlayerMovementRecord = {
	humanoid: Humanoid,
	rootPart: BasePart,
	lastSprintRequestTime: number,
	isSprinting: boolean,
	lastSlideRequestTime: number,
	-- Sliding can run for a variable, physics-driven duration (decaying friction, re-accelerating
	-- down a steep slope), unlike Dash's fixed duration -- so instead of a timed exemption window,
	-- WalkSpeed itself is bumped to cover it for exactly as long as the client reports sliding,
	-- the same boolean-driven pattern RequestSprint already uses.
	isSliding: boolean,
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
}

local function isAirborne(humanoid: Humanoid): boolean
	local state = humanoid:GetState()
	return state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall
end

local function computeWalkSpeed(record: PlayerMovementRecord): number
	if record.isSliding then
		return MovementConstants.SlideMaxSpeed
	end
	if record.isCrouching then
		return MovementConstants.CrouchSpeed
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
		lastSlideRequestTime = 0,
		isSliding = false,
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
	}
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

	if not isAirborne(record.humanoid) then
		warn(string.format("[Anti-Exploit] %s attempted a double jump while grounded.", player.Name))
		return
	end

	if record.hasDoubleJumped then
		warn(string.format("[Anti-Exploit] %s attempted multiple double jumps in one airborne cycle.", player.Name))
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

function MovementValidationService._onRequestSlide(self: MovementValidationService, player: Player, isSliding: unknown)
	if typeof(isSliding) ~= "boolean" then
		return
	end

	local record = self._records[player]
	if not record or not player.Character then
		return
	end

	-- Ending a slide always goes through immediately, bypassing the cooldown below -- a dropped
	-- "stop" here would leave the player permanently exempted at SlideMaxSpeed, unlike a dropped
	-- "start" which only delays the slide by a fraction of a second.
	if not isSliding then
		record.isSliding = false
		record.humanoid.WalkSpeed = computeWalkSpeed(record)
		return
	end

	local now = os.clock()
	if now - record.lastSlideRequestTime < MovementValidationConstants.SlideRequestCooldown then
		return
	end
	record.lastSlideRequestTime = now

	record.isSliding = true
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
	if not player.Character then
		return
	end

	local humanoid, rootPart = record.humanoid, record.rootPart
	local airborneNow = isAirborne(humanoid)

	if record.wasAirborne and not airborneNow then
		if record.pendingLandingSettleGrace then
			record.pendingLandingSettleGrace = false
			record.speedCheckExemptUntil = math.max(record.speedCheckExemptUntil, now + MovementValidationConstants.AerialActionLandingSettleGrace)
		end
		record.hasDoubleJumped = false
	end
	record.wasAirborne = airborneNow

	if now < record.speedCheckExemptUntil or airborneNow then
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
		local maxAllowedDistance = humanoid.WalkSpeed * MovementConstants.SpeedTolerance * elapsed

		if horizontalDelta.Magnitude > maxAllowedDistance then
			record.speedViolationStreak += 1

			if record.speedViolationStreak >= MovementValidationConstants.SpeedViolationStreakThreshold then
				warn(string.format(
					"[Anti-Exploit] %s moved %.1f studs in %.3fs (max %.1f at WalkSpeed %d) -- snapped back",
					player.Name,
					horizontalDelta.Magnitude,
					elapsed,
					maxAllowedDistance,
					humanoid.WalkSpeed
				))
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
