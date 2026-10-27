--!nonstrict
-- Hot assets from inside Studio: mark and unmark instances (the TypeTorchAsset attribute), and check the place by the
-- same rules `typetorch assets sync` applies (cli src/assets.ts exportScript): a valid unique key, no scripts inside,
-- not inside another hot asset, not a service, no "/" in a parent's name. The plugin exports them from the open place
-- itself (no publish needed); checking and uploading run in `typetorch serve` (POST /tt/jobs with the export), since
-- uploads use the project's assets key.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
local Selection = game:GetService("Selection")
local SerializationService = game:GetService("SerializationService")

local Assets = {}

Assets.ATTRIBUTE = "TypeTorchAsset"
local KEY_MAX = 64

export type Marked = {
	key: string,
	instance: Instance,
	path: string,
	className: string,
	problems: { string },
}

function Assets.keyError(key: any): string?
	if type(key) ~= "string" or #key == 0 then
		return "the key is empty"
	elseif #key > KEY_MAX then
		return `the key is longer than {KEY_MAX} characters`
	elseif not string.match(key, "^[a-z0-9/_%-]+$") then
		return `the key may only use lowercase a-z, 0-9, "/", "-" and "_"`
	end
	return nil
end

-- A key from an instance's name: lowercase, anything else becomes "-".
function Assets.suggestKey(instance: Instance): string
	local key = string.lower(instance.Name)
	key = string.gsub(key, "[^a-z0-9/_%-]+", "-")
	key = string.gsub(key, "^%-+", "")
	key = string.gsub(key, "%-+$", "")
	if key == "" then
		key = "asset"
	end
	return string.sub(key, 1, KEY_MAX)
end

local function pathOf(instance: Instance): string
	local parts = {}
	local current = instance.Parent
	while current and current ~= game do
		table.insert(parts, 1, current.Name)
		current = current.Parent
	end
	return table.concat(parts, "/")
end

local function hasScripts(instance: Instance): number
	local count = if instance:IsA("LuaSourceContainer") then 1 else 0
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("LuaSourceContainer") then
			count += 1
		end
	end
	return count
end

-- Every marked instance in the place with its problems, sorted by key.
function Assets.scan(): { Marked }
	local found = {}
	local byInstance = {}
	for _, service in game:GetChildren() do
		pcall(function()
			if service:GetAttribute(Assets.ATTRIBUTE) ~= nil then
				local entry = {
					key = tostring(service:GetAttribute(Assets.ATTRIBUTE)),
					instance = service,
					path = "",
					className = service.ClassName,
					problems = { "a service can't be a hot asset" },
				}
				table.insert(found, entry)
			end
			for _, instance in service:GetDescendants() do
				local raw = instance:GetAttribute(Assets.ATTRIBUTE)
				if raw ~= nil then
					local entry = {
						key = tostring(raw),
						instance = instance,
						path = pathOf(instance),
						className = instance.ClassName,
						problems = {},
					}
					local keyProblem = Assets.keyError(raw)
					if keyProblem then
						table.insert(entry.problems, keyProblem)
					end
					table.insert(found, entry)
					byInstance[instance] = entry
				end
			end
		end)
	end
	local seen = {}
	for _, entry in found do
		if seen[entry.key] then
			table.insert(entry.problems, `the key is also used at {seen[entry.key].path}`)
		end
		seen[entry.key] = entry
		local instance = entry.instance
		local scripts = hasScripts(instance)
		if scripts > 0 then
			table.insert(entry.problems, `holds {scripts} script{if scripts == 1 then "" else "s"}`)
		end
		local ancestor = instance.Parent
		while ancestor and ancestor ~= game do
			if byInstance[ancestor] then
				table.insert(entry.problems, `inside the hot asset "{byInstance[ancestor].key}"`)
				break
			end
			if string.find(ancestor.Name, "/", 1, true) then
				table.insert(entry.problems, `a parent's name has a "/": {ancestor.Name}`)
			end
			ancestor = ancestor.Parent
		end
	end
	table.sort(found, function(a, b)
		return a.key < b.key
	end)
	return found
end

-- A key no other marked instance uses: `key`, else `key-2`, `key-3`, ...
local function freeKey(key: string, taken: { [string]: boolean }): string
	if not taken[key] then
		return key
	end
	local n = 2
	while taken[`{string.sub(key, 1, KEY_MAX - 4)}-{n}`] do
		n += 1
	end
	return `{string.sub(key, 1, KEY_MAX - 4)}-{n}`
end

-- Marks every selected instance that isn't one yet. `name`: the key when exactly one instance is selected (else, or
-- when empty, a key from each instance's name). Returns (ok, message).
function Assets.addSelection(name: string?): (boolean, string)
	local selected = Selection:Get()
	if #selected == 0 then
		return false, "Select a model or UI in the Explorer first"
	end
	local taken = {}
	for _, entry in Assets.scan() do
		taken[entry.key] = true
	end
	local chosen = if name and #selected == 1 and name ~= "" then name else nil
	if chosen then
		local problem = Assets.keyError(chosen)
		if problem then
			return false, problem
		end
	end
	local added, skipped = {}, {}
	local recording = ChangeHistoryService:TryBeginRecording("TypeTorch: add hot assets")
	for _, instance in selected do
		local current = instance:GetAttribute(Assets.ATTRIBUTE)
		if instance.Parent == game then
			table.insert(skipped, `{instance.Name} is a service`)
		elseif hasScripts(instance) > 0 then
			table.insert(skipped, `{instance.Name} holds scripts`)
		elseif current ~= nil and (chosen == nil or chosen == current) then
			table.insert(skipped, `{instance.Name} is already "{current}"`)
		else
			if current ~= nil then
				taken[current] = nil
			end
			local key = freeKey(chosen or Assets.suggestKey(instance), taken)
			taken[key] = true
			instance:SetAttribute(Assets.ATTRIBUTE, key)
			table.insert(added, `{instance.Name} as "{key}"`)
		end
	end
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
	local text = if #added > 0 then `Added {table.concat(added, ", ")}. Publish to dev sends it.` else "Nothing added"
	if #skipped > 0 then
		text ..= ` (skipped: {table.concat(skipped, "; ")})`
	end
	return #added > 0, text
end

-- Unmarks the selected hot assets. Returns (ok, message).
function Assets.removeSelection(): (boolean, string)
	local selected = Selection:Get()
	local count = 0
	local recording = ChangeHistoryService:TryBeginRecording("TypeTorch: remove hot assets")
	for _, instance in selected do
		if instance:GetAttribute(Assets.ATTRIBUTE) ~= nil then
			instance:SetAttribute(Assets.ATTRIBUTE, nil)
			count += 1
		end
	end
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
	if count == 0 then
		return false, "Nothing selected is a hot asset"
	end
	return true, `Removed {count}. Running servers keep it until the next Publish to dev.`
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_BYTES = {}
for i = 1, 64 do
	B64_BYTES[i - 1] = string.byte(B64, i)
end

function Assets.base64(data: buffer): string
	local size = buffer.len(data)
	local out = buffer.create(((size + 2) // 3) * 4)
	local o = 0
	for i = 0, size - 1, 3 do
		local a = buffer.readu8(data, i)
		local b = if i + 1 < size then buffer.readu8(data, i + 1) else 0
		local c = if i + 2 < size then buffer.readu8(data, i + 2) else 0
		local n = bit32.bor(bit32.lshift(a, 16), bit32.lshift(b, 8), c)
		buffer.writeu8(out, o, B64_BYTES[bit32.extract(n, 18, 6)])
		buffer.writeu8(out, o + 1, B64_BYTES[bit32.extract(n, 12, 6)])
		buffer.writeu8(out, o + 2, if i + 1 < size then B64_BYTES[bit32.extract(n, 6, 6)] else 61)
		buffer.writeu8(out, o + 3, if i + 2 < size then B64_BYTES[bit32.extract(n, 0, 6)] else 61)
		o += 4
	end
	return buffer.tostring(out)
end

-- Stamps the live runtime puts on hot assets (cli src/assets.ts): never part of an export.
local STAMPS = { "TypeTorchAssetId", "TypeTorchAssetHash", "TypeTorchAssetVersion" }
local TAG_PREFIX = "__typetorch_asset:"
local MAGIC = "TTA1"

-- A copy without the runtime's stamps when the instance has any (an asset copied from a live server), else itself.
local function exportable(instance: Instance): Instance
	local stamped = false
	for _, name in STAMPS do
		if instance:GetAttribute(name) ~= nil then
			stamped = true
		end
	end
	for _, tag in CollectionService:GetTags(instance) do
		if string.sub(tag, 1, #TAG_PREFIX) == TAG_PREFIX then
			stamped = true
		end
	end
	if not stamped then
		return instance
	end
	local archivable = instance.Archivable
	instance.Archivable = true
	local copy = instance:Clone()
	instance.Archivable = archivable
	for _, name in STAMPS do
		copy:SetAttribute(name, nil)
	end
	for _, tag in CollectionService:GetTags(copy) do
		if string.sub(tag, 1, #TAG_PREFIX) == TAG_PREFIX then
			CollectionService:RemoveTag(copy, tag)
		end
	end
	return copy
end

-- The open place's hot assets as `typetorch assets sync --studio-export` reads them: the export task's metadata (cli
-- src/assets.ts exportScript) plus `binary`, "TTA1" and each serialized asset back to back, in base64. Yields.
-- Returns (ok, export or message).
function Assets.export(): (boolean, any)
	local marked = Assets.scan()
	for _, entry in marked do
		if #entry.problems > 0 then
			return false, `Fix the problems first ({entry.key}: {entry.problems[1]})`
		end
	end
	local parts, metas = {}, {}
	local total = #MAGIC
	for _, entry in marked do
		local ok, result = pcall(function()
			return SerializationService:SerializeInstancesAsync({ exportable(entry.instance) })
		end)
		if not ok then
			return false, `{entry.key}: couldn't serialize ({result})`
		end
		local path = {}
		local current = entry.instance.Parent
		while current and current ~= game do
			table.insert(path, 1, current.Name)
			current = current.Parent
		end
		table.insert(parts, result)
		table.insert(metas, {
			key = entry.key,
			keyType = "string",
			path = path,
			name = entry.instance.Name,
			className = entry.className,
			scripts = {},
			scriptCount = 0,
			offset = total,
			size = buffer.len(result),
		})
		total += buffer.len(result)
	end
	local out = buffer.create(total)
	buffer.writestring(out, 0, MAGIC)
	for i, part in parts do
		buffer.copy(out, metas[i].offset, part)
	end
	return true,
		{
			v = 1,
			placeVersion = game.PlaceVersion,
			placeId = string.format("%d", game.PlaceId),
			services = {},
			assets = metas,
			ok = true,
			binary = Assets.base64(out),
		}
end

-- A one-line summary of a finished job's JSON answer (cli `typetorch assets status|sync --json`).
function Assets.describeJob(job): string
	if job.state == "running" then
		local last = job.tail and job.tail[#job.tail]
		return if last then `Running: {last}` else "Running"
	elseif job.state == "failed" then
		return `Failed: {job.error or "see typetorch serve's log"}`
	end
	local result = job.result
	if type(result) ~= "table" then
		return "Done"
	end
	local counts = { added = 0, updated = 0, removed = 0, unchanged = 0 }
	for _, change in result.changes or {} do
		counts[change.status] = (counts[change.status] or 0) + 1
	end
	local summary = `{counts.added} new, {counts.updated} changed, {counts.removed} removed, {counts.unchanged} unchanged`
	if result.dryRun then
		return if result.upToDate then `Up to date ({summary})` else `To publish: {summary}`
	end
	local text = `Uploaded: {summary}`
	local deploy = result.deploy
	if type(deploy) == "table" then
		if deploy.proposal then
			text ..= `. Deploy waits for approval: {deploy.approve or "typetorch approve"}`
		else
			text ..= ". Dev servers updated"
		end
	end
	return text
end

function Assets.formatBytes(n: number): string
	if n < 1024 then
		return `{n} B`
	elseif n < 1024 * 1024 then
		return `{string.format("%.1f", n / 1024)} KB`
	end
	return `{string.format("%.1f", n / (1024 * 1024))} MB`
end

local function summaryText(summary): string
	local text = `{summary.instances} instance{if summary.instances == 1 then "" else "s"}, {Assets.formatBytes(summary.bytes)}`
	local classes = {}
	for className, count in summary.classes or {} do
		table.insert(classes, { className, count })
	end
	table.sort(classes, function(a, b)
		return if a[2] ~= b[2] then a[2] > b[2] else a[1] < b[1]
	end)
	local parts = {}
	for _, pair in classes do
		table.insert(parts, `{pair[1]} x{pair[2]}`)
	end
	return if #parts > 0 then `{text}: {table.concat(parts, ", ")}` else text
end

export type DiffLine = { text: string, tone: "added" | "removed" | "changed" | "text" | "dim" }

-- The panel's lines for one checked asset's `diff` (cli `assets status --json`, src/assetdiff.ts): the instances
-- added, removed and changed with their properties, already bounded by serve. `status`: the change's status
-- ("added", "updated", "removed"). An older serve sends no diff: callers hide the button then.
function Assets.describeDiff(diff, status: string): { DiffLine }
	local lines: { DiffLine } = {}
	local function line(text: string, tone)
		table.insert(lines, { text = text, tone = tone or "text" })
	end
	local before, after = diff.before, diff.after
	if status == "added" then
		line(if after then `New: {summaryText(after)}` else "New asset", "dim")
		return lines
	elseif status == "removed" then
		line(if before then `Was {summaryText(before)}; not in the place any more` else "Not in the place any more", "dim")
		return lines
	end
	if diff.baseline ~= "state" or not before or not after then
		if type(diff.note) == "string" then
			line(diff.note, "dim")
		end
		if after then
			line(`Now {summaryText(after)}`, "dim")
		end
		return lines
	end
	line(`{before.instances} -> {after.instances} instances, {Assets.formatBytes(before.bytes)} -> {Assets.formatBytes(after.bytes)}`, "dim")
	for _, entry in diff.entries or {} do
		if entry.kind == "added" then
			line(`+ {entry.path}  {entry.className}`, "added")
		elseif entry.kind == "removed" then
			line(`- {entry.path}  {entry.className}`, "removed")
		else
			line(`~ {entry.path}  {entry.className}`, "changed")
			for _, prop in entry.props or {} do
				local from = if prop.from ~= nil then tostring(prop.from) else "(none)"
				local to = if prop.to ~= nil then tostring(prop.to) else "(removed)"
				line(`    {prop.name}: {from} -> {to}`, "text")
			end
			if (entry.moreProps or 0) > 0 then
				line(`    and {entry.moreProps} more propert{if entry.moreProps == 1 then "y" else "ies"}`, "dim")
			end
		end
	end
	if (diff.more or 0) > 0 then
		line(`and {diff.more} more instance{if diff.more == 1 then "" else "s"}`, "dim")
	end
	if type(diff.undecoded) == "table" and #diff.undecoded > 0 then
		line(`Also changed (not decoded): {table.concat(diff.undecoded, ", ")}`, "dim")
	end
	if type(diff.note) == "string" then
		line(diff.note, "dim")
	end
	return lines
end

return Assets
