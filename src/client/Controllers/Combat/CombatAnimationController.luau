--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local CombatState = require(Shared.Enums.CombatState)
local CombatConstants = require(Shared.Constants.CombatConstants)
local AnimationConstants = require(Shared.Constants.AnimationConstants)
local onCharacterAdded = require(Shared.Utils.OnCharacterAdded)
local combatFSM = require(script.Parent.Parent.Parent.State.CombatFSM)
local CombatAnimations = require(script.Parent.Parent.Parent.Animation.Combat.CombatAnimations)
local AttackController = require(script.Parent.AttackController)

local player = Players.LocalPlayer

local CombatAnimationController = {}
CombatAnimationController.__index = CombatAnimationController

export type CombatAnimationController = typeof(setmetatable(
	{} :: {
		_tracks: { [string]: AnimationTrack },
		_activeTrack: AnimationTrack?,
	},
	CombatAnimationController
))

function CombatAnimationController.new(): CombatAnimationController
	local self = setmetatable({
		_tracks = {},
		_activeTrack = nil,
	}, CombatAnimationController)

	return self
end

function CombatAnimationController._setupCharacter(self: CombatAnimationController, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local animator = humanoid:WaitForChild("Animator") :: Animator

	local weaponAnimations = CombatAnimations[CombatConstants.PlaceholderEquippedWeaponId]
	local tracks: { [string]: AnimationTrack } = {}
	if weaponAnimations then
		for stepId, animation in pairs(weaponAnimations) do
			local track = animator:LoadAnimation(animation)
			track.Looped = false
			track.Priority = Enum.AnimationPriority.Action
			tracks[stepId] = track
		end
	end
	self._tracks = tracks
	self._activeTrack = nil
end

function CombatAnimationController._onComboStepStarted(self: CombatAnimationController, stepId: string)
	if self._activeTrack then
		self._activeTrack:Stop(AnimationConstants.DashFadeOutTime)
	end

	local track = self._tracks[stepId]
	if not track then
		return
	end

	track:Play(AnimationConstants.DashFadeInTime)
	self._activeTrack = track
end

function CombatAnimationController._onCombatStateChanged(self: CombatAnimationController, newState: string)
	if newState ~= CombatState.Attacking and self._activeTrack then
		self._activeTrack:Stop(AnimationConstants.DashFadeOutTime)
		self._activeTrack = nil
	end
end

function CombatAnimationController.Init(self: CombatAnimationController)
	onCharacterAdded(player, function(character: Model)
		self:_setupCharacter(character)
	end)

	AttackController.ComboStepStarted:Connect(function(stepId: string)
		self:_onComboStepStarted(stepId)
	end)

	combatFSM.Changed:Connect(function(newState: string)
		self:_onCombatStateChanged(newState)
	end)
end

return CombatAnimationController.new()
