--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local FiniteStateMachine = require(Shared.FSM.FiniteStateMachine)
local CombatState = require(Shared.Enums.CombatState)

return FiniteStateMachine.new(CombatState.Idle)
