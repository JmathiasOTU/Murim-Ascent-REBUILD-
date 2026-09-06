--!strict

local soundsByCategory = {
	Plastic = { "rbxassetid://7326203155" },
	Grass = { "rbxassetid://507863105" },
	Metal = { "rbxassetid://6876957898" },
	Wood = { "rbxassetid://507863457" },
	Concrete = { "rbxassetid://5761648082" },
	Fabric = { "rbxassetid://6240702531" },
	Sand = { "rbxassetid://265653329" },
	Glass = { "rbxassetid://9117949159" },
}

local materialMap: { [string]: { string } } = {
	SmoothPlastic = soundsByCategory.Plastic,
	ForceField = soundsByCategory.Plastic,
	Foil = soundsByCategory.Plastic,
	Plastic = soundsByCategory.Plastic,

	WoodPlanks = soundsByCategory.Wood,
	Wood = soundsByCategory.Wood,

	Ground = soundsByCategory.Fabric,
	Fabric = soundsByCategory.Fabric,

	DiamondPlate = soundsByCategory.Metal,
	CorrodedMetal = soundsByCategory.Metal,
	Metal = soundsByCategory.Metal,

	LeafyGrass = soundsByCategory.Grass,
	Grass = soundsByCategory.Grass,
	Mud = soundsByCategory.Grass,
	Snow = soundsByCategory.Grass,
	Glacier = soundsByCategory.Grass,

	Pavement = soundsByCategory.Concrete,
	Limestone = soundsByCategory.Concrete,
	Salt = soundsByCategory.Concrete,
	Asphalt = soundsByCategory.Concrete,
	Neon = soundsByCategory.Concrete,
	CrackedLava = soundsByCategory.Concrete,
	Basalt = soundsByCategory.Concrete,
	Sandstone = soundsByCategory.Concrete,
	Rock = soundsByCategory.Concrete,
	Cobblestone = soundsByCategory.Concrete,
	Pebble = soundsByCategory.Concrete,
	Brick = soundsByCategory.Concrete,
	Granite = soundsByCategory.Concrete,
	Marble = soundsByCategory.Concrete,
	Ice = soundsByCategory.Concrete,
	Slate = soundsByCategory.Concrete,
	Concrete = soundsByCategory.Concrete,

	Sand = soundsByCategory.Sand,
	Glass = soundsByCategory.Glass,
}

local FootstepSounds = {}

function FootstepSounds.GetRandomSound(materialName: string): string
	local sounds = materialMap[materialName] or soundsByCategory.Plastic
	return sounds[math.random(1, #sounds)]
end

return FootstepSounds
