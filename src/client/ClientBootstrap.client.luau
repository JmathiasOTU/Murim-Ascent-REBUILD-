--!strict

local MovementController = require(script.Parent.Controllers.MovementController)
local AirborneController = require(script.Parent.Controllers.AirborneController)
local DashController = require(script.Parent.Controllers.DashController)
local SlideController = require(script.Parent.Controllers.SlideController)
local AnimationController = require(script.Parent.Controllers.AnimationController)
local movementFSM = require(script.Parent.State.MovementFSM)
local AssetPreloader = require(script.Parent.Loading.AssetPreloader)
local MovementAnimations = require(script.Parent.Animation.MovementAnimations)
local DirectionalWalkAnimations = require(script.Parent.Animation.DirectionalWalkAnimations)
local DashAnimations = require(script.Parent.Animation.DashAnimations)
local DodgeCancelAnimations = require(script.Parent.Animation.DodgeCancelAnimations)

movementFSM.Changed:Connect(function(newState: string)
	print("State : " .. newState)
end)

task.spawn(function()
	AssetPreloader.PreloadAll(MovementAnimations, DirectionalWalkAnimations, DashAnimations, DodgeCancelAnimations)
end)

MovementController:Init()
AirborneController:Init()
DashController:Init()
SlideController:Init()
AnimationController:Init()
