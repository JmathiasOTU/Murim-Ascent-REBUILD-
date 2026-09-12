--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.Shared
local CombatState = require(Shared.Enums.CombatState)
local CombatConstants = require(Shared.Constants.CombatConstants)
local WeaponDefinitions = require(Shared.Constants.WeaponDefinitions)
local WeaponTypes = require(Shared.Constants.Weapons.WeaponTypes)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local FiniteStateMachine = require(Shared.FSM.FiniteStateMachine)
local LemonSignal = require(ReplicatedStorage.Packages.LemonSignal)
local combatFSM = require(script.Parent.Parent.Parent.State.CombatFSM)

local requestAttack = ReplicatedStorage.Remotes.RequestAttack :: RemoteEvent

local player = Players.LocalPlayer

local AttackController = {}
AttackController.__index = AttackController

export type AttackController = typeof(setmetatable(
	{} :: {
		_comboIndex: number,
		_comboEndThread: thread?,
		-- combatFSM's own Changed signal only fires on a COARSE state change (Idle<->Attacking) --
		-- successive combo steps never leave the Attacking state, so CombatAnimationController needs
		-- this separate per-step signal to know when a new step actually starts (Section 5: "combo
		-- index tracked as data not sub-states").
		ComboStepStarted: FiniteStateMachine.Signal<string>,
	},
	AttackController
))

function AttackController.new(): AttackController
	local self = setmetatable({
		_comboIndex = 0,
		_comboEndThread = nil,
		ComboStepStarted = (LemonSignal.new() :: any) :: FiniteStateMachine.Signal<string>,
	}, AttackController)

	return self
end

function AttackController._cancelComboEndThread(self: AttackController)
	if self._comboEndThread then
		task.cancel(self._comboEndThread)
		self._comboEndThread = nil
	end
end

function AttackController._beginStep(self: AttackController, stepIndex: number, stepId: string, stepData: WeaponTypes.ComboStepData)
	self._comboIndex = stepIndex
	combatFSM:TransitionTo(CombatState.Attacking)
	requestAttack:FireServer(stepId)
	self.ComboStepStarted:Fire(stepId)

	self:_cancelComboEndThread()
	local stepDuration = stepData.Windup + stepData.Active + stepData.Recovery
	self._comboEndThread = task.delay(stepDuration, function()
		self._comboEndThread = nil
		self._comboIndex = 0
		if combatFSM:GetState() == CombatState.Attacking then
			combatFSM:TransitionTo(CombatState.Idle)
		end
	end)
end

function AttackController._tryAttack(self: AttackController)
	local currentState = combatFSM:GetState()
	if currentState ~= CombatState.Idle and currentState ~= CombatState.Attacking then
		return
	end

	local weaponDef = WeaponDefinitions[CombatConstants.PlaceholderEquippedWeaponId]
	if not weaponDef then
		return
	end

	local nextIndex = if currentState == CombatState.Idle then 1 else self._comboIndex + 1
	if nextIndex > #weaponDef.ComboSteps then
		-- Finisher already thrown -- must return to Idle before a new combo can start, same "no
		-- auto-chain" default the Running Attack uses (Section 4).
		return
	end

	local stepId = weaponDef.ComboSteps[nextIndex]
	local stepData = weaponDef.ComboData[stepId]
	if not stepData then
		return
	end

	self:_beginStep(nextIndex, stepId, stepData)
end

function AttackController._resetForNewCharacter(self: AttackController)
	self:_cancelComboEndThread()
	self._comboIndex = 0
end

function AttackController.Init(self: AttackController)
	onCharacterAdded(player, function(character: Model)
		self:_resetForNewCharacter()

		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		humanoid.Died:Connect(function()
			self:_resetForNewCharacter()
			combatFSM:TransitionTo(CombatState.Idle)
		end)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self:_tryAttack()
		end
	end)
end

return AttackController.new()
