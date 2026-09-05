--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local FiniteStateMachine = require(Shared.FSM.FiniteStateMachine)
local MovementState = require(Shared.Enums.MovementState)

return FiniteStateMachine.new(MovementState.Idle)
