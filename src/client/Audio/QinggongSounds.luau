--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementState = require(ReplicatedStorage.Shared.Enums.MovementState)
local qinggongSoundFolder = require(script.Parent.QinggongSoundFolder)
local wallClimbSoundFolder = qinggongSoundFolder:WaitForChild("WallClimbing")

local QinggongSounds: { [string]: Sound } = table.freeze({
	[MovementState.AirDashing] = qinggongSoundFolder:WaitForChild("AirDash") :: Sound,
	[MovementState.DoubleJumping] = qinggongSoundFolder:WaitForChild("DoubleJump") :: Sound,
	[MovementState.LedgeJumping] = qinggongSoundFolder:WaitForChild("LedgeJump") :: Sound,
	-- Looped ambient wind while running along the wall; MovementSoundController stops it explicitly
	-- on exit the same way it already does for Sliding's long clip.
	[MovementState.WallRunning] = qinggongSoundFolder:WaitForChild("WallRun") :: Sound,
	[MovementState.WallLeaping] = qinggongSoundFolder:WaitForChild("Wall Leap") :: Sound,
	-- Looped grip-loss slide while hanging; stopped explicitly on exit the same way as WallRunning's
	-- clip above (see MovementSoundController).
	[MovementState.WallHanging] = wallClimbSoundFolder:WaitForChild("WallClingSlideDown") :: Sound,
	[MovementState.WallBoost] = wallClimbSoundFolder:WaitForChild("WallBoost") :: Sound,
	-- No distinct SFX asset for the recovery hop -- reuses the plain double jump sound, same as the
	-- old game's did.
	[MovementState.WallClingDoubleJump] = qinggongSoundFolder:WaitForChild("DoubleJump") :: Sound,
	-- Nested under WallClimbing so it doesn't collide with WallLeaping's own flat "Wall Leap" above --
	-- a distinct cue for leaping off a clung wall vs. off a wall run.
	[MovementState.WallClimbLeaping] = wallClimbSoundFolder:WaitForChild("Wall Leap") :: Sound,
	-- Volume is driven continuously by MovementSoundController while ramping/active (see
	-- SprintController), not just played at its authored volume like everything else here.
	[MovementState.Sprinting] = qinggongSoundFolder:WaitForChild("Sprinting") :: Sound,
})

return QinggongSounds
