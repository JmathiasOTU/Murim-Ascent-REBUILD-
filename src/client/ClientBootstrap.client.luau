--!strict

local MovementController = require(script.Parent.Controllers.MovementController)
local AirborneController = require(script.Parent.Controllers.AirborneController)
local DashController = require(script.Parent.Controllers.DashController)
local AirDashController = require(script.Parent.Controllers.AirDashController)
local DoubleJumpController = require(script.Parent.Controllers.DoubleJumpController)
local SlideController = require(script.Parent.Controllers.SlideController)
local CrouchController = require(script.Parent.Controllers.CrouchController)
local AnimationController = require(script.Parent.Controllers.AnimationController)
local FootstepController = require(script.Parent.Controllers.FootstepController)
local MovementSoundController = require(script.Parent.Controllers.MovementSoundController)
local MovementVFXController = require(script.Parent.Controllers.MovementVFXController)
local movementFSM = require(script.Parent.State.MovementFSM)
local AssetPreloader = require(script.Parent.Loading.AssetPreloader)
local MovementAnimations = require(script.Parent.Animation.MovementAnimations)
local DirectionalWalkAnimations = require(script.Parent.Animation.DirectionalWalkAnimations)
local DashAnimations = require(script.Parent.Animation.DashAnimations)
local QinggongAnimations = require(script.Parent.Animation.QinggongAnimations)
local DodgeCancelAnimations = require(script.Parent.Animation.DodgeCancelAnimations)
local MovementSounds = require(script.Parent.Audio.MovementSounds)
local QinggongSounds = require(script.Parent.Audio.QinggongSounds)
local MovementVFXTemplates = require(script.Parent.VFX.MovementVFXTemplates)
local QinggongVFXTemplates = require(script.Parent.VFX.QinggongVFXTemplates)

movementFSM.Changed:Connect(function(newState: string)
	print("State : " .. newState)
end)

task.spawn(function()
	AssetPreloader.PreloadAll(
		MovementAnimations,
		DirectionalWalkAnimations,
		DashAnimations,
		QinggongAnimations,
		DodgeCancelAnimations,
		MovementSounds,
		QinggongSounds,
		MovementVFXTemplates,
		QinggongVFXTemplates
	)
end)

MovementController:Init()
AirborneController:Init()
DashController:Init()
AirDashController:Init()
DoubleJumpController:Init()
SlideController:Init()
CrouchController:Init()
AnimationController:Init()
FootstepController:Init()
MovementSoundController:Init()
MovementVFXController:Init()
