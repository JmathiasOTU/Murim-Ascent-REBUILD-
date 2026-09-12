--!strict

local MovementController = require(script.Parent.Controllers.Movement.MovementController)
local SprintController = require(script.Parent.Controllers.Movement.SprintController)
local AirborneController = require(script.Parent.Controllers.Movement.AirborneController)
local DashController = require(script.Parent.Controllers.Movement.DashController)
local AirDashController = require(script.Parent.Controllers.Qinggong.AirDashController)
local WallRunController = require(script.Parent.Controllers.Qinggong.WallRunController)
local WallClingController = require(script.Parent.Controllers.Qinggong.WallClingController)
local DoubleJumpController = require(script.Parent.Controllers.Qinggong.DoubleJumpController)
local SlideController = require(script.Parent.Controllers.Movement.SlideController)
local CrouchController = require(script.Parent.Controllers.Movement.CrouchController)
local AnimationController = require(script.Parent.Controllers.Movement.AnimationController)
local CameraController = require(script.Parent.Controllers.Core.CameraController)
local FootstepController = require(script.Parent.Controllers.Core.FootstepController)
local MovementSoundController = require(script.Parent.Controllers.Core.MovementSoundController)
local MovementVFXController = require(script.Parent.Controllers.Core.MovementVFXController)
local AttackController = require(script.Parent.Controllers.Combat.AttackController)
local CombatAnimationController = require(script.Parent.Controllers.Combat.CombatAnimationController)
local GuardController = require(script.Parent.Controllers.Combat.GuardController)
local movementFSM = require(script.Parent.State.MovementFSM)
local combatFSM = require(script.Parent.State.CombatFSM)
local AssetPreloader = require(script.Parent.Loading.AssetPreloader)
local MovementAnimations = require(script.Parent.Animation.Movement.MovementAnimations)
local DirectionalWalkAnimations = require(script.Parent.Animation.Movement.DirectionalWalkAnimations)
local DashAnimations = require(script.Parent.Animation.Movement.DashAnimations)
local QinggongAnimations = require(script.Parent.Animation.Qinggong.QinggongAnimations)
local DodgeCancelAnimations = require(script.Parent.Animation.Movement.DodgeCancelAnimations)
local WallRunAnimations = require(script.Parent.Animation.Qinggong.WallRunAnimations)
local WallClimbAnimations = require(script.Parent.Animation.Qinggong.WallClimbAnimations)
local SprintAnimation = require(script.Parent.Animation.Movement.SprintAnimation)
local JianAnimations = require(script.Parent.Animation.Combat.JianAnimations)
local FistAnimations = require(script.Parent.Animation.Combat.FistAnimations)
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
		JianAnimations,
		FistAnimations,
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
CombatAnimationController:Init()
GuardController:Init()
