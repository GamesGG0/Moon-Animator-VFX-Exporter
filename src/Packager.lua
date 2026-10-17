--!strict
-- Copies each cue's VFX object into the "VFX" folder the exported module spawns them from.

local isEffect = require(script.Parent.Exporter).isEffect

local Packager = {}

local function within(inst: Instance?, root: Instance): boolean
	return inst ~= nil and (inst == root or inst:IsDescendantOf(root))
end

-- Where `inst` is inside `root`: each step down as a name and which of the same-named children
-- it is, so it can be found again in a copy.
local function stepsTo(root: Instance, inst: Instance): { { Name: string, Nth: number } }?
	local steps = {}
	local node = inst
	while node ~= root do
		local parent = node.Parent
		if not parent then
			return nil
		end
		local nth = 0
		for _, sibling in parent:GetChildren() do
			if sibling.Name == node.Name then
				nth += 1
			end
			if sibling == node then
				break
			end
		end
		table.insert(steps, 1, { Name = node.Name, Nth = nth })
		node = parent
	end
	return steps
end

local function follow(root: Instance, steps: { { Name: string, Nth: number } }): Instance?
	local node = root
	for _, step in steps do
		local nth, found = 0, nil
		for _, child in node:GetChildren() do
			if child.Name == step.Name then
				nth += 1
				if nth == step.Nth then
					found = child
					break
				end
			end
		end
		if not found then
			return nil
		end
		node = found
	end
	return node
end

-- A copy that works on its own: anchored, non-colliding, and with no joints or constraints left
-- pointing at parts that stayed behind (the rig, the map...). What it's carried in (`wrap`):
--   "Part"            an invisible part (an effect that lived in a prop's part)
--   "Attachment"      a copy of the attachment it was in (an effect in a rig's attachment)
--   "AttachmentPart"  that attachment, in an invisible part (an effect in a prop's attachment)
-- An attachment (or bone) on its own also rides in an invisible part. `leaveOut` are descendants
-- that aren't copied (keyframed effects, which their own cues spawn). With `only`, the effects in
-- the copy are just those (the ones an event emitted by name).
function Packager.prepare(object: Instance, wrap: string?, leaveOut: { Instance }?, only: { Instance }?): Instance?
	local function stepsFor(list: { Instance }?): { any }
		local result = {}
		for _, inst in list or {} do
			if inst ~= object and inst:IsDescendantOf(object) then
				table.insert(result, stepsTo(object, inst))
			end
		end
		return result
	end
	local leaving, keeping = stepsFor(leaveOut), stepsFor(only)

	local archivable = object.Archivable
	object.Archivable = true
	local ok, copy = pcall(object.Clone, object)
	object.Archivable = archivable

	if not ok or not copy then
		return nil
	end

	-- Everything to remove is found before any is, so removing one doesn't change where another is.
	local found = {}
	for _, steps in leaving do
		table.insert(found, follow(copy, steps) or copy)
	end
	if only then
		local kept = {}
		for _, steps in keeping do
			local inst = follow(copy, steps)
			if inst then
				kept[inst] = true
			end
		end
		for _, item in copy:GetDescendants() do
			if not kept[item] and isEffect(item) then
				table.insert(found, item)
			end
		end
	end
	for _, inst in found do
		if inst ~= copy then
			inst:Destroy()
		end
	end

	if (wrap == "Attachment" or wrap == "AttachmentPart") and object.Parent then
		local holder = Instance.new("Attachment")
		holder.Name = object.Parent.Name
		copy.Parent = holder
		copy = holder
	end

	if wrap == "Part" or wrap == "AttachmentPart" or (copy:IsA("Attachment") and wrap ~= "Attachment") then
		local holder = Instance.new("Part")
		holder.Name = copy.Name
		holder.Transparency = 1
		holder.Size = Vector3.new(0.2, 0.2, 0.2)
		if copy:IsA("Attachment") then
			copy.CFrame = CFrame.new()
		end
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
			-- Carrying effects an event named: the event emitted them, not the part.
			if only then
				item.Transparency = 1
			end
		elseif only and item:IsA("Decal") then
			item.Transparency = 1
		end
	end

	return copy
end

-- One copy per distinct VFX object, named by the cue's Asset name. Keyframed effects inside
-- another cue's object are left out of that copy: their own cue spawns and animates them.
function Packager.build(cues: { { Object: Instance?, Asset: string?, Wrap: string?, Animation: any?, Only: { Instance }? } }): (Folder, number)
	local folder = Instance.new("Folder")
	folder.Name = "VFX"

	local keyframed = {}
	for _, cue in cues do
		if cue.Animation and cue.Object then
			table.insert(keyframed, cue.Object)
		end
	end

	local packed = {}
	local count = 0
	for _, cue in cues do
		local object, asset = cue.Object, cue.Asset
		if object and asset and not packed[asset] then
			packed[asset] = true

			local copy = Packager.prepare(object, cue.Wrap, keyframed, cue.Only)
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
