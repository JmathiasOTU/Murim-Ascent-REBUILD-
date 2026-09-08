--!strict

local Players = game:GetService("Players")

-- Reads Qinggong straight off the LocalPlayer's replicated attribute (see PlayerVitalsService) --
-- a fast local check for whether an ability's own controller should even attempt to fire, not the
-- authoritative spend, which happens server-side (MovementValidationService).
local function hasEnoughQinggong(cost: number): boolean
	local current = Players.LocalPlayer:GetAttribute("Qinggong")
	return typeof(current) == "number" and current >= cost
end

return hasEnoughQinggong
