--!strict

local DEFAULT_COLOR = Color3.fromRGB(204, 204, 204)

local function sampleSurfaceColor(rayResult: RaycastResult?): Color3
	if not rayResult then
		return DEFAULT_COLOR
	end

	if rayResult.Instance:IsA("Terrain") then
		if rayResult.Material == Enum.Material.Water then
			return DEFAULT_COLOR
		end

		local ok, terrainColor = pcall(function()
			return workspace.Terrain:GetMaterialColor(rayResult.Material)
		end)
		return if ok then DEFAULT_COLOR:Lerp(terrainColor, 0.5) else DEFAULT_COLOR
	end

	return DEFAULT_COLOR:Lerp(rayResult.Instance.Color, 0.5)
end

return sampleSurfaceColor
