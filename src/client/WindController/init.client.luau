local Camera = workspace.CurrentCamera
local RunService = game:GetService("RunService")

local WIND_DIRECTION = Vector3.new(1,0,0.3)
local WIND_SPEED = 20
local WIND_POWER = 0.5


local WindLines = require(script.WindLines)
local WindShake = require(script.WindShake)

WindLines:Init({
	Direction = WIND_DIRECTION;
	Speed = WIND_SPEED;
	Lifetime = 1.5;
	SpawnRate = 11;
})


WindShake:SetDefaultSettings({
	WindSpeed = WIND_SPEED;
	WindDirection = WIND_DIRECTION;
	WindPower = WIND_POWER;
})
WindShake:Init()
