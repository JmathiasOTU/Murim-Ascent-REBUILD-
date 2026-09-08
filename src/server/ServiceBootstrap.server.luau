--!strict

local PlayerDataService = require(script.Parent.Services.PlayerDataService)
local PlayerVitalsService = require(script.Parent.Services.PlayerVitalsService)
local MovementValidationService = require(script.Parent.Services.MovementValidationService)
local FootstepRelayService = require(script.Parent.Services.FootstepRelayService)
local CombatValidationService = require(script.Parent.Services.CombatValidationService)

-- Order matters: PlayerVitalsService listens for PlayerDataService.Loaded, and
-- MovementValidationService spends/drains Qinggong through PlayerVitalsService.
PlayerDataService:Init()
PlayerVitalsService:Init()
MovementValidationService:Init()
FootstepRelayService:Init()
CombatValidationService:Init()
