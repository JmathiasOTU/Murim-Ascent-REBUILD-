--!strict

export type Direction8 = string

local Direction8 = table.freeze({
	Forward = "Forward" :: Direction8,
	FrontRight = "FrontRight" :: Direction8,
	Right = "Right" :: Direction8,
	BackRight = "BackRight" :: Direction8,
	Back = "Back" :: Direction8,
	BackLeft = "BackLeft" :: Direction8,
	Left = "Left" :: Direction8,
	FrontLeft = "FrontLeft" :: Direction8,
})

return Direction8
