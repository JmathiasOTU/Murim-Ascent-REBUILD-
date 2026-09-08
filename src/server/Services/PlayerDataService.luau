--!strict

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileStoreModule = require(ServerScriptService.ServerPackages.ProfileStore)
local LemonSignal = require(ReplicatedStorage.Packages.LemonSignal)

local Shared = ReplicatedStorage.Shared
local PlayerDataSchema = require(Shared.Constants.PlayerDataSchema)
local PlayerDataConstants = require(script.Parent.Parent.Constants.PlayerDataConstants)

type ProfileData = typeof(PlayerDataSchema.Default)
type Profile = ProfileStoreModule.Profile<ProfileData>

-- LemonSignal's Wally link module re-exports the value but not the `Signal` type -- same reasoning
-- as FiniteStateMachine.luau's own local declaration.
type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> { Disconnect: (self: any) -> () },
	Fire: (self: Signal<T...>, T...) -> (),
	Destroy: (self: Signal<T...>) -> (),
}

local profileStore = ProfileStoreModule.New(PlayerDataConstants.DataStoreName, PlayerDataSchema.Default)

local PlayerDataService = {}
PlayerDataService.__index = PlayerDataService

export type PlayerDataService = typeof(setmetatable(
	{} :: {
		_profiles: { [Player]: Profile },
		-- Fires once a player's profile has finished loading (Reconcile + Migrate already applied)
		-- -- see PlayerVitalsService for the main consumer.
		Loaded: Signal<Player, ProfileData>,
	},
	PlayerDataService
))

function PlayerDataService.new(): PlayerDataService
	local self = setmetatable({
		_profiles = {},
		Loaded = (LemonSignal.new() :: any) :: Signal<Player, ProfileData>,
	}, PlayerDataService)

	return self
end

function PlayerDataService._loadProfile(self: PlayerDataService, player: Player)
	local profile = profileStore:StartSessionAsync(tostring(player.UserId), {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})

	if not profile then
		player:Kick("Failed to load your data. Please rejoin.")
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()
	PlayerDataSchema.Migrate(profile.Data)

	-- Debug-HUD-only for now: replicates just the four vitals via attributes (auto-replicating,
	-- no remote needed) so DebugStatsHUD has something real to read. Current* values don't exist
	-- yet (no combat/regen system), so there's nothing else to sync.
	local data = profile.Data
	player:SetAttribute("MaxHealth", data.MaxHealth)
	player:SetAttribute("MaxPosture", data.MaxPosture)
	player:SetAttribute("MaxQi", data.MaxQi)
	player:SetAttribute("MaxQinggong", data.MaxQinggong)

	-- Another server stole the session (or this one is shutting down and released it itself) --
	-- either way this server can no longer treat the profile as live.
	profile.OnSessionEnd:Connect(function()
		self._profiles[player] = nil
		player:Kick("Your data session was taken over by another server. Please rejoin.")
	end)

	-- The player may have already left while StartSessionAsync was yielding.
	if player.Parent ~= Players then
		profile:EndSession()
		return
	end

	self._profiles[player] = profile
	self.Loaded:Fire(player, profile.Data)
end

function PlayerDataService._releaseProfile(self: PlayerDataService, player: Player)
	local profile = self._profiles[player]
	if not profile then
		return
	end

	self._profiles[player] = nil
	profile:EndSession()
end

-- Nil until the session finishes loading (StartSessionAsync yields) or if it failed/ended --
-- callers must handle the nil case rather than assuming data is always ready.
function PlayerDataService.GetData(self: PlayerDataService, player: Player): ProfileData?
	local profile = self._profiles[player]
	return if profile then profile.Data else nil
end

function PlayerDataService.Init(self: PlayerDataService)
	Players.PlayerAdded:Connect(function(player: Player)
		self:_loadProfile(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_releaseProfile(player)
	end)

	-- Covers players who joined while this script was still loading.
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			self:_loadProfile(player)
		end)
	end
end

return PlayerDataService.new()
