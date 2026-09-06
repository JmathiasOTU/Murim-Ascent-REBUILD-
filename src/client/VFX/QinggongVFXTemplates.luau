--!strict

local qinggongVFXFolder = require(script.Parent.QinggongVFXFolder)

local doubleJumpTrailTemplate = qinggongVFXFolder:WaitForChild("DoubleJumpTrailVFX")

local doubleJumpTrailAttachment0: Attachment? = nil
local doubleJumpTrailAttachment1: Attachment? = nil
local doubleJumpTrailTrail: Trail? = nil

for _, child in ipairs(doubleJumpTrailTemplate:GetChildren()) do
	if child:IsA("Trail") and not doubleJumpTrailTrail then
		doubleJumpTrailTrail = child
	elseif child:IsA("Attachment") then
		if not doubleJumpTrailAttachment0 then
			doubleJumpTrailAttachment0 = child
		elseif not doubleJumpTrailAttachment1 then
			doubleJumpTrailAttachment1 = child
		end
	end
end

if not (doubleJumpTrailTrail and doubleJumpTrailAttachment0 and doubleJumpTrailAttachment1) then
	warn("QinggongVFXTemplates: DoubleJumpTrailVFX needs a Trail and two Attachments as direct children")
end

local QinggongVFXTemplates = table.freeze({
	AirDashVFX = qinggongVFXFolder:WaitForChild("AirDashVFX") :: BasePart,
	DoubleJumpVFX = qinggongVFXFolder:WaitForChild("DoubleJumpVFX") :: BasePart,
	LedgeJumpVFX = qinggongVFXFolder:WaitForChild("LedgeJumpVFX") :: BasePart,
	DoubleJumpTrailAttachment0 = doubleJumpTrailAttachment0,
	DoubleJumpTrailAttachment1 = doubleJumpTrailAttachment1,
	DoubleJumpTrailTrail = doubleJumpTrailTrail,
})

return QinggongVFXTemplates
