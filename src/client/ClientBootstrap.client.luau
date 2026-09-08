--!strict

local MovementController = require(script.Parent.Controllers.MovementController)
local SprintController = require(script.Parent.Controllers.SprintController)
local AirborneController = require(script.Parent.Controllers.AirborneController)
local DashController = require(script.Parent.Controllers.DashController)
local AirDashController = require(script.Parent.Controllers.AirDashController)
local WallRunController = require(script.Parent.Controllers.WallRunController)
local WallClingController = require(script.Parent.Controllers.WallClingController)
local DoubleJumpController = require(script.Parent.Controllers.DoubleJumpController)
local SlideController = require(script.Parent.Controllers.SlideController)
local CrouchController = require(script.Parent.Controllers.CrouchController)
local AnimationController = require(script.Parent.Controllers.AnimationController)
local CameraController = require(script.Parent.Controllers.CameraController)
local FootstepController = require(script.Parent.Controllers.FootstepController)
local MovementSoundController = require(script.Parent.Controllers.MovementSoundController)
local MovementVFXController = require(script.Parent.Controllers.MovementVFXController)
local AttackController = require(script.Parent.Controllers.AttackController)
local movementFSM = require(script.Parent.State.MovementFSM)
local combatFSM = require(script.Parent.State.CombatFSM)
local AssetPreloader = require(script.Parent.Loading.AssetPreloader)
local MovementAnimations = require(script.Parent.Animation.MovementAnimations)
local DirectionalWalkAnimations = require(script.Parent.Animation.DirectionalWalkAnimations)
local DashAnimations = require(script.Parent.Animation.DashAnimations)
local QinggongAnimations = require(script.Parent.Animation.QinggongAnimations)
local DodgeCancelAnimations = require(script.Parent.Animation.DodgeCancelAnimations)
local WallRunAnimations = require(script.Parent.Animation.WallRunAnimations)
local WallClimbAnimations = require(script.Parent.Animation.WallClimbAnimations)
local SprintAnimation = require(script.Parent.Animation.SprintAnimation)
local MovementSounds = require(script.Parent.Audio.MovementSounds)
local QinggongSounds = require(script.Parent.Audio.QinggongSounds)
local MovementVFXTemplates = require(script.Parent.VFX.MovementVFXTemplates)
local QinggongVFXTemplates = require(script.Parent.VFX.QinggongVFXTemplates)
local Watermark = require(script.Parent.UI.Watermark)
local DebugStatsHUD = require(script.Parent.UI.DebugStatsHUD)

movementFSM.Changed:Connect(function(newState: string)
	print("State : " .. newState)
end)

combatFSM.Changed:Connect(function(newState: string)
	print("Combat State : " .. newState)
end)

task.spawn(function()
	AssetPreloader.PreloadAll(
		MovementAnimations,
		DirectionalWalkAnimations,
		DashAnimations,
		QinggongAnimations,
		DodgeCancelAnimations,
		WallRunAnimations,
		WallClimbAnimations,
		{ SprintAnimation },
		MovementSounds,
		QinggongSounds,
		MovementVFXTemplates,
		QinggongVFXTemplates
	)
end)

Watermark.start()
DebugStatsHUD.start()

MovementController:Init()
SprintController:Init()
AirborneController:Init()
DashController:Init()
AirDashController:Init()
-- Registered before WallClingController/DoubleJumpController: all three bind Space, and Roblox
-- fires InputBegan listeners in connection order, so a successful wall-run entry here updates the
-- FSM before either of the next two reads it -- letting their own state guards naturally no-op
-- instead of also grabbing a wall or consuming the double jump charge on the same press.
WallRunController:Init()
-- Registered before DoubleJumpController for the same reason -- a successful wall cling/boost/leap
-- entry takes priority over a plain double jump on the same Space press.
WallClingController:Init()
DoubleJumpController:Init()
SlideController:Init()
CrouchController:Init()
AnimationController:Init()
CameraController:Init()
FootstepController:Init()
MovementSoundController:Init()
MovementVFXController:Init()
AttackController:Init()
