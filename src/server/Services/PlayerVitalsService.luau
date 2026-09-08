--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local VitalsConstants = require(Shared.Constants.VitalsConstants)
local PlayerDataService = require(script.Parent.PlayerDataService)

export type PoolName = "Health" | "Posture" | "Qi" | "Qinggong"

type PoolState = {
	Health: number,
	Posture: number,
	Qi: number,
	Qinggong: number,
}

local POOLS: { PoolName } = { "Health", "Posture", "Qi", "Qinggong" }

local function getMax(data: any, pool: PoolName): number
	if pool == "Health" then
		return data.MaxHealth
	elseif pool == "Posture" then
		return data.MaxPosture
	elseif pool == "Qi" then
		return data.MaxQi
	else
		return data.MaxQinggong
	end
end

local function getRegenPerSecond(pool: PoolName): number
	if pool == "Health" then
		return VitalsConstants.HealthRegenPerSecond
	elseif pool == "Posture" then
		return VitalsConstants.PostureRegenPerSecond
	elseif pool == "Qi" then
		return VitalsConstants.QiRegenPerSecond
	else
		return VitalsConstants.QinggongRegenPerSecond
	end
end

local function getRegenDelay(pool: PoolName): number
	if pool == "Health" then
		return VitalsConstants.HealthRegenDelay
	elseif pool == "Posture" then
		return VitalsConstants.PostureRegenDelay
	elseif pool == "Qi" then
		return VitalsConstants.QiRegenDelay
	else
		return VitalsConstants.QinggongRegenDelay
	end
end

local PlayerVitalsService = {}
PlayerVitalsService.__index = PlayerVitalsService

export type PlayerVitalsService = typeof(setmetatable(
	{} :: {
		_current: { [Player]: PoolState },
		-- os.clock() timestamp of the last time each pool was actually reduced (Spend/Drain) -- 0
		-- (never spent) regenerates immediately rather than waiting out an artificial initial delay.
		_lastSpend: { [Player]: PoolState },
	},
	PlayerVitalsService
))

function PlayerVitalsService.new(): PlayerVitalsService
	local self = setmetatable({
		_current = {},
		_lastSpend = {},
	}, PlayerVitalsService)

	return self
end

function PlayerVitalsService._sync(self: PlayerVitalsService, player: Player, pool: PoolName)
	local pools = self._current[player]
	if pools then
		player:SetAttribute(pool, pools[pool])
	end
end

function PlayerVitalsService._onProfileLoaded(self: PlayerVitalsService, player: Player, data: any)
	self._current[player] = {
		Health = data.MaxHealth,
		Posture = data.MaxPosture,
		Qi = data.MaxQi,
		Qinggong = data.MaxQinggong,
	}
	self._lastSpend[player] = {
		Health = 0,
		Posture = 0,
		Qi = 0,
		Qinggong = 0,
	}

	for _, pool in ipairs(POOLS) do
		self:_sync(player, pool)
	end
end

function PlayerVitalsService.GetCurrent(self: PlayerVitalsService, player: Player, pool: PoolName): number?
	local pools = self._current[player]
	return if pools then pools[pool] else nil
end

function PlayerVitalsService.CanAfford(self: PlayerVitalsService, player: Player, pool: PoolName, amount: number): boolean
	local current = self:GetCurrent(player, pool)
	return current ~= nil and current >= amount
end

-- Rejects outright (nothing is deducted) if unaffordable -- use for one-shot ability costs.
function PlayerVitalsService.Spend(self: PlayerVitalsService, player: Player, pool: PoolName, amount: number): boolean
	if not self:CanAfford(player, pool, amount) then
		return false
	end

	self._current[player][pool] -= amount
	local lastSpend = self._lastSpend[player]
	if lastSpend then
		lastSpend[pool] = os.clock()
	end
	self:_sync(player, pool)
	return true
end

-- Unconditional, clamped at 0 -- for continuous per-second drain, where outright refusal (like
-- Spend) doesn't make sense. The caller is responsible for reacting once a pool hits 0.
function PlayerVitalsService.Drain(self: PlayerVitalsService, player: Player, pool: PoolName, amount: number)
	local pools = self._current[player]
	if not pools then
		return
	end

	local before = pools[pool]
	pools[pool] = math.max(0, before - amount)
	if pools[pool] < before then
		local lastSpend = self._lastSpend[player]
		if lastSpend then
			lastSpend[pool] = os.clock()
		end
	end
	self:_sync(player, pool)
end

function PlayerVitalsService._regenTick(self: PlayerVitalsService, dt: number)
	local now = os.clock()

	for player, pools in pairs(self._current) do
		local data = PlayerDataService:GetData(player)
		if not data then
			continue
		end
		local lastSpend = self._lastSpend[player]

		for _, pool in ipairs(POOLS) do
			local rate = getRegenPerSecond(pool)
			if rate <= 0 then
				continue
			end

			if lastSpend and now - lastSpend[pool] < getRegenDelay(pool) then
				continue
			end

			local max = getMax(data, pool)
			if pools[pool] >= max then
				continue
			end

			pools[pool] = math.min(max, pools[pool] + rate * dt)
			self:_sync(player, pool)
		end
	end
end

function PlayerVitalsService.Init(self: PlayerVitalsService)
	PlayerDataService.Loaded:Connect(function(player: Player, data: any)
		self:_onProfileLoaded(player, data)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self._current[player] = nil
		self._lastSpend[player] = nil
	end)

	local accumulated = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulated += dt
		if accumulated < VitalsConstants.RegenTickRate then
			return
		end
		local elapsed = accumulated
		accumulated = 0
		self:_regenTick(elapsed)
	end)
end

return PlayerVitalsService.new()
