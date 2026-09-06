--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local FootstepConstants = require(Shared.Constants.FootstepConstants)

local notifyFootstep = ReplicatedStorage.Remotes.NotifyFootstep :: UnreliableRemoteEvent
local playFootstepSFX = ReplicatedStorage.Remotes.PlayFootstepSFX :: UnreliableRemoteEvent

local FootstepRelayService = {}
FootstepRelayService.__index = FootstepRelayService

export type FootstepRelayService = typeof(setmetatable(
	{} :: {
		_lastNotifyTime: { [Player]: number },
	},
	FootstepRelayService
))

function FootstepRelayService.new(): FootstepRelayService
	local self = setmetatable({
		_lastNotifyTime = {},
	}, FootstepRelayService)

	return self
end

function FootstepRelayService._onNotifyFootstep(self: FootstepRelayService, player: Player, materialName: unknown)
	if typeof(materialName) ~= "string" then
		return
	end

	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then
		return
	end

	local now = os.clock()
	if now - (self._lastNotifyTime[player] or 0) < FootstepConstants.NotifyCooldown then
		return
	end
	self._lastNotifyTime[player] = now

	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= player then
			local otherCharacter = otherPlayer.Character
			local otherRootPart = otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
			if otherRootPart and (otherRootPart.Position - rootPart.Position).Magnitude <= FootstepConstants.AudibleRange then
				playFootstepSFX:FireClient(otherPlayer, player, materialName)
			end
		end
	end
end

function FootstepRelayService.Init(self: FootstepRelayService)
	Players.PlayerRemoving:Connect(function(player: Player)
		self._lastNotifyTime[player] = nil
	end)

	notifyFootstep.OnServerEvent:Connect(function(player: Player, materialName: unknown)
		self:_onNotifyFootstep(player, materialName)
	end)
end

return FootstepRelayService.new()
