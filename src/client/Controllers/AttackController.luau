--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.Shared
local CombatState = require(Shared.Enums.CombatState)
local CombatConstants = require(Shared.Constants.CombatConstants)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local combatFSM = require(script.Parent.Parent.State.CombatFSM)

local requestAttack = ReplicatedStorage.Remotes.RequestAttack :: RemoteEvent

local player = Players.LocalPlayer

-- Mirrors CombatValidationService's own TOTAL_ATTACK_DURATION -- purely for local prediction, so
-- this controller's revert timing stays in sync with the server's rather than drifting from a
-- separately-maintained flat duration.
local TOTAL_ATTACK_DURATION = CombatConstants.AttackWindupTime + CombatConstants.AttackActiveTime + CombatConstants.AttackRecoveryTime

local AttackController = {}
AttackController.__index = AttackController

export type AttackController = typeof(setmetatable(
	{} :: {
		_connections: { RBXScriptConnection },
		_attackEndThread: thread?,
		-- Purely a local prediction gate for responsiveness -- CombatValidationService keeps its own
		-- independent copy server-side and is the only one that actually governs the outcome (see
		-- Section 3's "Server-Side Cooldowns").
		_lastAttackRequestTime: number,
	},
	AttackController
))

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

function AttackController.new(): AttackController
	local self = setmetatable({
		_connections = {},
		_attackEndThread = nil,
		_lastAttackRequestTime = -math.huge,
	}, AttackController)

	return self
end

function AttackController._cancelAttackEndThread(self: AttackController)
	if self._attackEndThread then
		task.cancel(self._attackEndThread)
		self._attackEndThread = nil
	end
end

-- No hit detection yet -- see CombatValidationService's own comment on why this bit stops at the
-- request/cooldown/state-transition plumbing.
function AttackController._tryAttack(self: AttackController)
	if combatFSM:GetState() ~= CombatState.Idle then
		return
	end

	local now = os.clock()
	if now - self._lastAttackRequestTime < CombatConstants.AttackCooldown then
		return
	end
	self._lastAttackRequestTime = now

	combatFSM:TransitionTo(CombatState.Attacking)
	requestAttack:FireServer()

	self:_cancelAttackEndThread()
	self._attackEndThread = task.delay(TOTAL_ATTACK_DURATION, function()
		self._attackEndThread = nil
		if combatFSM:GetState() == CombatState.Attacking then
			combatFSM:TransitionTo(CombatState.Idle)
		end
	end)
end

function AttackController._setupCharacter(self: AttackController, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	disconnectAll(self._connections)
	self:_cancelAttackEndThread()
	self._lastAttackRequestTime = -math.huge

	table.insert(
		self._connections,
		humanoid.Died:Connect(function()
			disconnectAll(self._connections)
			self:_cancelAttackEndThread()
		end)
	)
end

function AttackController.Init(self: AttackController)
	onCharacterAdded(player, function(character: Model)
		self:_setupCharacter(character)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end

		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end

		if not player.Character then
			return
		end

		self:_tryAttack()
	end)
end

return AttackController.new()
