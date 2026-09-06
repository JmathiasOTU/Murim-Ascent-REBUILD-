--!strict

local basicMovementVFXFolder = require(script.Parent.BasicMovementVFXFolder)

local dashTrailTemplate = basicMovementVFXFolder:WaitForChild("DashTrail")

local dashTrailAttachment0: Attachment? = nil
local dashTrailAttachment1: Attachment? = nil
local dashTrailTrail: Trail? = nil

for _, child in ipairs(dashTrailTemplate:GetChildren()) do
	if child:IsA("Trail") and not dashTrailTrail then
		dashTrailTrail = child
	elseif child:IsA("Attachment") then
		if not dashTrailAttachment0 then
			dashTrailAttachment0 = child
		elseif not dashTrailAttachment1 then
			dashTrailAttachment1 = child
		end
	end
end

if not (dashTrailTrail and dashTrailAttachment0 and dashTrailAttachment1) then
	warn("MovementVFXTemplates: DashTrail needs a Trail and two Attachments as direct children")
end

local MovementVFXTemplates = table.freeze({
	DashDust = basicMovementVFXFolder:WaitForChild("DashDust") :: BasePart,
	SlideDust = basicMovementVFXFolder:WaitForChild("SlideDust") :: BasePart,
	Footsteps = basicMovementVFXFolder:WaitForChild("Footsteps") :: BasePart,
	DashTrailAttachment0 = dashTrailAttachment0,
	DashTrailAttachment1 = dashTrailAttachment1,
	DashTrailTrail = dashTrailTrail,
})

return MovementVFXTemplates
