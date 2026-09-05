--!strict

local ContentProvider = game:GetService("ContentProvider")

local AssetPreloader = {}

function AssetPreloader.PreloadAll(...: { [any]: any })
	local instances: { Instance } = {}
	for _, group in ipairs({ ... }) do
		for _, instance in pairs(group) do
			table.insert(instances, instance :: Instance)
		end
	end

	local startTime = os.clock()

	local ok, err = pcall(function()
		ContentProvider:PreloadAsync(instances, function(contentId: string, status: Enum.AssetFetchStatus)
			if status == Enum.AssetFetchStatus.Failure then
				warn(`AssetPreloader: failed to preload {contentId}`)
			end
		end)
	end)

	if not ok then
		warn(`AssetPreloader: PreloadAsync errored - {err}`)
		return
	end

	print(string.format("AssetPreloader: preloaded %d assets in %.2fs", #instances, os.clock() - startTime))
end

return AssetPreloader
