--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local MovementConstants = require(Shared.Constants.MovementConstants)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local regenCharges = require(Shared.Utils.RegenCharges)
local MovementValidationConstants = require(script.Parent.Parent.Constants.MovementValidationConstants)

local requestSprint = ReplicatedStorage.Remotes.RequestSprint :: RemoteEvent
local requestDash = ReplicatedStorage.Remotes.RequestDash :: RemoteEvent
local requestRollCancel = ReplicatedStorage.Remotes.RequestRollCancel :: RemoteEvent
local requestSlide = ReplicatedStorage.Remotes.RequestSlide :: RemoteEvent

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
	lastDashTime: number,
	-- While now < this, _validatePlayer skips its speed check entirely -- the dash's velocity
	-- burst is real physics driven by the client's own LinearVelocity constraint, not something
	-- WalkSpeed-based validation can distinguish from a speed hack.
	dashSpeedExemptUntil: number,
	rollCancelCharges: number,
	rollCancelChargeRegenStart: number,
	-- -math.huge means "eligible" -- see _onRequestRollCancel.
	lastDashCooldownResetAt: number,
	lastPosition: Vector3,
	lastCheckTime: number,
}

local function computeWalkSpeed(record: PlayerMovementRecord): number
	if record.isSliding then
		return MovementConstants.SlideMaxSpeed
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
		lastDashTime = -math.huge,
		dashSpeedExemptUntil = 0,
		rollCancelCharges = MovementConstants.RollCancelMaxCharges,
		rollCancelChargeRegenStart = os.clock(),
		lastDashCooldownResetAt = -math.huge,
		lastPosition = rootPart.Position,
		lastCheckTime = os.clock(),
	}
end

function MovementValidationService._onRequestDash(self: MovementValidationService, player: Player)
	local record = self._records[player]
	if not record or not player.Character then
		return
	end

	local now = os.clock()
	if now - record.lastDashTime < MovementConstants.DashCooldown then
		return
	end

	record.lastDashTime = now
	record.dashSpeedExemptUntil = now + MovementConstants.DashDuration
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
	if now >= record.dashSpeedExemptUntil then
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
	record.dashSpeedExemptUntil = now + MovementValidationConstants.DashCancelExemptionGrace
	record.lastPosition = record.rootPart.Position
	record.lastCheckTime = now

	-- Only once per DashCooldown window, so chaining cancel -> instant re-dash -> cancel again
	-- doesn't grant a second reset.
	if now - record.lastDashCooldownResetAt >= MovementConstants.DashCooldown then
		record.lastDashTime = -math.huge
		record.lastDashCooldownResetAt = now
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

function MovementValidationService._validatePlayer(_self: MovementValidationService, player: Player, record: PlayerMovementRecord, now: number)
	if not player.Character then
		return
	end

	local humanoid, rootPart = record.humanoid, record.rootPart

	if now < record.dashSpeedExemptUntil then
		record.lastPosition = rootPart.Position
		record.lastCheckTime = now
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
			warn(string.format(
				"[Anti-Exploit] %s moved %.1f studs in %.3fs (max %.1f at WalkSpeed %d) -- snapped back",
				player.Name,
				horizontalDelta.Magnitude,
				elapsed,
				maxAllowedDistance,
				humanoid.WalkSpeed
			))
			rootPart.CFrame = CFrame.new(record.lastPosition) * rootPart.CFrame.Rotation
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

	requestDash.OnServerEvent:Connect(function(player: Player)
		self:_onRequestDash(player)
	end)

	requestRollCancel.OnServerEvent:Connect(function(player: Player)
		self:_onRequestRollCancel(player)
	end)

	requestSlide.OnServerEvent:Connect(function(player: Player, isSliding: unknown)
		self:_onRequestSlide(player, isSliding)
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
