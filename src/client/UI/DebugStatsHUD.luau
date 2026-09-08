--!strict
local Players = game:GetService("Players")

local DebugStatsHUD = {}

local BAR_WIDTH = 300
local BAR_SPACING = 4

local QINGGONG_BAR_WIDTH = 24
local QINGGONG_BAR_HEIGHT = 200

local function makeHorizontalBar(parent: Instance, layoutOrder: number, color: Color3, height: number): (Frame, TextLabel)
	local background = Instance.new("Frame")
	background.Name = "Bar"
	background.LayoutOrder = layoutOrder
	background.Size = UDim2.new(0, BAR_WIDTH, 0, height)
	background.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	background.BorderSizePixel = 0
	background.Parent = parent

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = background

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.5
	label.Text = ""
	label.Parent = background

	return fill, label
end

local function fraction(current: number, max: number): number
	if max <= 0 then
		return 0
	end
	return math.clamp(current / max, 0, 1)
end

function DebugStatsHUD.start()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "DebugStatsHUD"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local horizontalHolder = Instance.new("Frame")
	horizontalHolder.Name = "HorizontalBars"
	horizontalHolder.AnchorPoint = Vector2.new(0, 1)
	horizontalHolder.Position = UDim2.new(0, 20, 1, -20)
	horizontalHolder.Size = UDim2.new(0, BAR_WIDTH, 0, 0)
	horizontalHolder.AutomaticSize = Enum.AutomaticSize.Y
	horizontalHolder.BackgroundTransparency = 1
	horizontalHolder.Parent = screenGui

	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, BAR_SPACING)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	listLayout.Parent = horizontalHolder

	local healthFill, healthLabel = makeHorizontalBar(horizontalHolder, 1, Color3.fromRGB(200, 30, 30), 24)
	local postureFill, postureLabel = makeHorizontalBar(horizontalHolder, 2, Color3.fromRGB(230, 200, 40), 14)
	local qiFill, qiLabel = makeHorizontalBar(horizontalHolder, 3, Color3.fromRGB(190, 130, 230), 14)

	local qinggongBackground = Instance.new("Frame")
	qinggongBackground.Name = "QinggongBar"
	qinggongBackground.AnchorPoint = Vector2.new(1, 1)
	qinggongBackground.Position = UDim2.new(1, -20, 1, -20)
	qinggongBackground.Size = UDim2.new(0, QINGGONG_BAR_WIDTH, 0, QINGGONG_BAR_HEIGHT)
	qinggongBackground.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	qinggongBackground.BorderSizePixel = 0
	qinggongBackground.Parent = screenGui

	local qinggongFill = Instance.new("Frame")
	qinggongFill.Name = "Fill"
	qinggongFill.AnchorPoint = Vector2.new(0, 1)
	qinggongFill.Position = UDim2.new(0, 0, 1, 0)
	qinggongFill.Size = UDim2.new(1, 0, 1, 0)
	qinggongFill.BackgroundColor3 = Color3.fromRGB(120, 230, 210)
	qinggongFill.BorderSizePixel = 0
	qinggongFill.Parent = qinggongBackground

	local qinggongLabel = Instance.new("TextLabel")
	qinggongLabel.Name = "Label"
	qinggongLabel.AnchorPoint = Vector2.new(0.5, 1)
	qinggongLabel.Position = UDim2.new(0.5, 0, 0, -4)
	qinggongLabel.Size = UDim2.new(3, 0, 0, 16)
	qinggongLabel.BackgroundTransparency = 1
	qinggongLabel.Font = Enum.Font.GothamBold
	qinggongLabel.TextSize = 12
	qinggongLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	qinggongLabel.TextStrokeTransparency = 0.5
	qinggongLabel.Text = ""
	qinggongLabel.Parent = qinggongBackground

	-- Current* attributes are set by PlayerVitalsService (server-authoritative, drained/regenerated
	-- there) and Max* by PlayerDataService -- both replicate automatically via Player attributes, no
	-- remote needed. Missing Current* (e.g. before PlayerVitalsService's first sync) falls back to
	-- the Max value so bars read full rather than empty during that brief window.
	local function refresh()
		local maxHealth = player:GetAttribute("MaxHealth") :: number? or 0
		local maxPosture = player:GetAttribute("MaxPosture") :: number? or 0
		local maxQi = player:GetAttribute("MaxQi") :: number? or 0
		local maxQinggong = player:GetAttribute("MaxQinggong") :: number? or 0

		local health = player:GetAttribute("Health") :: number? or maxHealth
		local posture = player:GetAttribute("Posture") :: number? or maxPosture
		local qi = player:GetAttribute("Qi") :: number? or maxQi
		local qinggong = player:GetAttribute("Qinggong") :: number? or maxQinggong

		healthFill.Size = UDim2.new(fraction(health, maxHealth), 0, 1, 0)
		healthLabel.Text = string.format("HP  %d / %d", health, maxHealth)

		postureFill.Size = UDim2.new(fraction(posture, maxPosture), 0, 1, 0)
		postureLabel.Text = string.format("POSTURE  %d / %d", posture, maxPosture)

		qiFill.Size = UDim2.new(fraction(qi, maxQi), 0, 1, 0)
		qiLabel.Text = string.format("QI  %d / %d", qi, maxQi)

		qinggongFill.Size = UDim2.new(1, 0, fraction(qinggong, maxQinggong), 0)
		qinggongLabel.Text = string.format("QINGGONG  %d / %d", qinggong, maxQinggong)
	end

	refresh()
	player.AttributeChanged:Connect(refresh)
end

return DebugStatsHUD
