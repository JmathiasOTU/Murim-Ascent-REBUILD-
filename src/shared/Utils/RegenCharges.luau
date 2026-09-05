--!strict

-- Lazily catches a charge pool up to what elapsed time would have regenerated, capped at
-- maxCharges -- no background ticker needed for a per-player resource this low-frequency.
-- Returns the new (charges, regenStart) pair; call sites own their own state.
local function regenCharges(
	charges: number,
	regenStart: number,
	now: number,
	maxCharges: number,
	cooldownPerCharge: number
): (number, number)
	if charges >= maxCharges then
		return maxCharges, now
	end

	local elapsed = now - regenStart
	local gained = math.floor(elapsed / cooldownPerCharge)
	if gained <= 0 then
		return charges, regenStart
	end

	return math.min(maxCharges, charges + gained), regenStart + gained * cooldownPerCharge
end

return regenCharges
