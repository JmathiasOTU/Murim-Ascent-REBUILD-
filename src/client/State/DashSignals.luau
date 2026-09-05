--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LemonSignal = require(ReplicatedStorage.Packages.LemonSignal)
local FiniteStateMachine = require(ReplicatedStorage.Shared.FSM.FiniteStateMachine)

local DashSignals = {
	-- Fired by DashController the instant a dodge-cancel actually lands (not every attempted
	-- right-click -- see DashController's own charge check) -- read by AnimationController to
	-- play the DodgeCancelLeft/Right one-shot instead of silently stopping the dash clip like
	-- every other Dashing exit.
	Cancelled = (LemonSignal.new() :: any) :: FiniteStateMachine.Signal<>,
}

return DashSignals
