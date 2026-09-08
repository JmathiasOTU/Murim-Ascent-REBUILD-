--!strict

local CURRENT_VERSION = 1

local DEFAULT_PROFILE = {
	SchemaVersion = CURRENT_VERSION,

	-- Core Vitals: baseline capacities only. Current Health/Posture/Qi/Qinggong are runtime FSM
	-- state, not persisted -- they reset on spawn like every other resource in this genre.
	MaxHealth = 100,
	MaxPosture = 100,
	MaxQi = 100,
	MaxQinggong = 100,

	-- Character Genetics
	Gender = "Male",
	BodyType = "Balanced",
	Family = "",
	Temperament = "",
	Traits = {} :: { string },

	-- Combat & Progression
	Level = 1,
	XP = 0,
	EquippedWeapon = "Fists",
	WeaponMastery = {
		Light = 0,
		Medium = 0,
		Heavy = 0,
	},
	UnlockedTechniques = {} :: { string },
}

-- Keyed by the version a profile is migrating FROM. Profile:Reconcile() (see PlayerDataService)
-- already backfills brand new fields for free -- an entry here is only needed for actual
-- restructuring/renames of an EXISTING field that Reconcile can't do. Bump CURRENT_VERSION
-- whenever one is added.
local MIGRATIONS: { [number]: (data: any) -> () } = {}

local PlayerDataSchema = {
	CurrentVersion = CURRENT_VERSION,
	Default = DEFAULT_PROFILE,
}

function PlayerDataSchema.Migrate(data: any)
	data.SchemaVersion = data.SchemaVersion or 1
	while data.SchemaVersion < CURRENT_VERSION do
		local migrate = MIGRATIONS[data.SchemaVersion]
		if migrate then
			migrate(data)
		end
		data.SchemaVersion += 1
	end
end

return PlayerDataSchema
