--!strict
-- Copies each cue's VFX object into the "VFX" folder the exported module spawns them from.

local Packager = {}

local function within(inst: Instance?, root: Instance): boolean
	return inst ~= nil and (inst == root or inst:IsDescendantOf(root))
end

-- A copy that works on its own: anchored, non-colliding, and with no joints or constraints left
-- pointing at parts that stayed behind (the rig, the map...).
function Packager.prepare(object: Instance): Instance?
	local archivable = object.Archivable
	object.Archivable = true
	local ok, copy = pcall(object.Clone, object)
	object.Archivable = archivable

	if not ok or not copy then
		return nil
	end

	-- Attachments (and bones) can't exist on their own, so they ride in an invisible part.
	if copy:IsA("Attachment") then
		local holder = Instance.new("Part")
		holder.Name = copy.Name
		holder.Transparency = 1
		holder.Size = Vector3.new(0.2, 0.2, 0.2)
		copy.CFrame = CFrame.new()
		copy.Parent = holder
		copy = holder
	end

	local items = copy:GetDescendants()
	table.insert(items, copy)

	for _, item in items do
		if item:IsA("JointInstance") or item:IsA("WeldConstraint") or item:IsA("NoCollisionConstraint") then
			local joint = item :: any
			if not (within(joint.Part0, copy) and within(joint.Part1, copy)) then
				item:Destroy()
			end
		elseif item:IsA("Constraint") then
			local constraint = item :: Constraint
			if not (within(constraint.Attachment0, copy) and within(constraint.Attachment1, copy)) then
				item:Destroy()
			end
		elseif item:IsA("BasePart") then
			item.Anchored = true
			item.CanCollide = false
			item.CanTouch = false
			item.CanQuery = false
		end
	end

	return copy
end

-- One copy per distinct VFX object, named by the cue's Asset name.
function Packager.build(cues: { { Object: Instance?, Asset: string? } }): (Folder, number)
	local folder = Instance.new("Folder")
	folder.Name = "VFX"

	local packed = {}
	local count = 0
	for _, cue in cues do
		local object, asset = cue.Object, cue.Asset
		if object and asset and not packed[asset] then
			packed[asset] = true

			local copy = Packager.prepare(object)
			if copy then
				copy.Name = asset
				copy.Parent = folder
				count += 1
			end
		end
	end

	return folder, count
end

return Packager
