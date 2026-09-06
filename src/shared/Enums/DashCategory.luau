--!strict

export type DashCategory = string

local DashCategory = table.freeze({
	Forward = "Forward" :: DashCategory,
	Side = "Side" :: DashCategory,
})

return DashCategory
