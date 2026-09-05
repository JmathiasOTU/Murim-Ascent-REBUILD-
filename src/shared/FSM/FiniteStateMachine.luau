--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LemonSignal = require(ReplicatedStorage.Packages.LemonSignal)

-- LemonSignal's Wally link module re-exports the value but not the `Signal` type, so
-- we declare the shape ourselves rather than name a type that isn't visible here.
export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> { Disconnect: (self: any) -> () },
	Fire: (self: Signal<T...>, T...) -> (),
	Destroy: (self: Signal<T...>) -> (),
}

local FiniteStateMachine = {}
FiniteStateMachine.__index = FiniteStateMachine

export type FiniteStateMachine<State> = typeof(setmetatable(
	{} :: {
		_state: State,
		Changed: Signal<State, State>,
	},
	FiniteStateMachine
))

function FiniteStateMachine.new<State>(initialState: State): FiniteStateMachine<State>
	local self = setmetatable({
		_state = initialState,
		Changed = (LemonSignal.new() :: any) :: Signal<State, State>,
	}, FiniteStateMachine)

	return self
end

function FiniteStateMachine.GetState<State>(self: FiniteStateMachine<State>): State
	return self._state
end

function FiniteStateMachine.TransitionTo<State>(self: FiniteStateMachine<State>, newState: State)
	local oldState = self._state
	if oldState == newState then
		return
	end

	self._state = newState
	self.Changed:Fire(newState, oldState)
end

function FiniteStateMachine.Destroy<State>(self: FiniteStateMachine<State>)
	self.Changed:Destroy()
end

return FiniteStateMachine
