--!strict

local PlayerDataService = require(script.Parent.Services.PlayerDataService)
local PlayerVitalsService = require(script.Parent.Services.PlayerVitalsService)
local MovementValidationService = require(script.Parent.Services.MovementValidationService)
local FootstepRelayService = require(script.Parent.Services.FootstepRelayService)
local HitRegistrationService = require(script.Parent.Services.HitRegistrationService)
local CombatValidationService = require(script.Parent.Services.CombatValidationService)

-- Order matters: PlayerVitalsService listens for PlayerDataService.Loaded, and
-- MovementValidationService spends/drains Qinggong through PlayerVitalsService.
PlayerDataService:Init()
PlayerVitalsService:Init()
MovementValidationService:Init()
FootstepRelayService:Init()
-- HitRegistrationService before CombatValidationService: the latter calls into the former the
-- moment a RequestAttack is validated, so its PlayerRemoving cleanup should already be wired up.
HitRegistrationService:Init()
CombatValidationService:Init()

-- "Dodge" is the ground Dash (Combat_Framework_Design_Doc Section 3), not its own combat state --
-- MovementValidationService and HitRegistrationService have no existing require relationship
-- either way, so this composition lives here rather than introducing one.
HitRegistrationService:SetIsDodgingQuery(function(player: Player): boolean
	return MovementValidationService:IsDashInvulnerable(player)
end)
