--!strict

local PlayerDataConstants = table.freeze({
	-- Bump this (e.g. "PlayerData_v2") only if you need to abandon existing saves entirely --
	-- PlayerDataSchema's own SchemaVersion/migrations handle ordinary field changes without one.
	DataStoreName = "PlayerData_v1",
})

return PlayerDataConstants
