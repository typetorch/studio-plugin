--!nonstrict
-- Claude's game tools, answered by this Studio on the place that is open (dev-server src/game-tools.ts, the Studio
-- set): game_status, game_logs, inspect and find, all read-only. A prompt sent from this Studio runs as job "" on the
-- dev machine; its tool requests wait there until this plugin picks them up through serve (`/tt/claude/v1`:
-- GET /v1/game/pending → GET /v1/game/requests/:id → POST /v1/game/requests/:id/result). Only the Edit DataModel
-- answers, and only requests of prompts in this chat. Results are plain data, capped like the framework's.
-- This plugin never runs code it receives: run_luau (and any other tool) is answered "not available in Studio".
-- Studio prompts run in Code mode, where the dev-server doesn't offer run_luau anyway; Claude changes the game
-- through files instead.

local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")

local StudioTools = {}

local MAX_DATA = 60000
local MAX_CHILDREN = 100
local MAX_PROPS = 200
local FIND_VISITS = 30000
local LINE_CHARS = 1000
local REQUEST_ID = "^%x+$"

-- Properties shown when ReflectionService can't list a class's own.
local COMMON_PROPS = {
	"Name", "Archivable", "Anchored", "CanCollide", "CanTouch", "CanQuery", "Transparency", "Color", "Material",
	"Size", "Position", "Orientation", "CFrame", "Shape", "Locked", "Massless", "PrimaryPart", "WorldPivot",
	"Value", "Enabled", "Visible", "Text", "TextColor3", "TextSize", "Font", "BackgroundColor3",
	"BackgroundTransparency", "Image", "ImageColor3", "AnchorPoint", "ZIndex", "LayoutOrder", "Brightness", "Range",
	"Texture", "MeshId", "TextureID", "SoundId", "Volume", "Looped", "Playing", "Disabled", "RunContext",
	"Ambient", "OutdoorAmbient", "ClockTime", "FogEnd", "Gravity", "Health", "MaxHealth", "WalkSpeed", "JumpPower",
}

local function cut(text: string, max: number): string
	return if #text > max then string.sub(text, 1, max) .. "… (cut)" else text
end

local function toJson(value: any): string
	local ok, text = pcall(HttpService.JSONEncode, HttpService, value)
	local json = if ok then text else `"unserializable: {text}"`
	return cut(json, MAX_DATA)
end

local function round(n: number): number
	return math.floor(n * 1000 + 0.5) / 1000
end

-- A short readable form of a property or attribute value.
local function encode(value: any): string
	local kind = typeof(value)
	if kind == "Instance" then
		local ok, path = pcall(value.GetFullName, value)
		return if ok then path else "Instance"
	elseif kind == "string" then
		return string.format("%q", value)
	elseif kind == "Vector3" then
		return `{round(value.X)}, {round(value.Y)}, {round(value.Z)}`
	elseif kind == "Vector2" then
		return `{round(value.X)}, {round(value.Y)}`
	elseif kind == "CFrame" then
		local x, y, z = value:ToOrientation()
		return `pos {round(value.X)}, {round(value.Y)}, {round(value.Z)} rot {round(math.deg(x))}, {round(math.deg(y))}, {round(math.deg(z))}`
	elseif kind == "Color3" then
		return `rgb({math.floor(value.R * 255 + 0.5)}, {math.floor(value.G * 255 + 0.5)}, {math.floor(value.B * 255 + 0.5)})`
	elseif kind == "number" then
		return tostring(round(value))
	end
	return tostring(value)
end

-- An instance from "game.Workspace.Map", "Workspace/Map/Part", `Workspace.Map["Spawn point"]` or "ServerStorage".
local function resolvePath(path: string): Instance?
	local text = string.match(path, "^%s*(.-)%s*$") or ""
	local names = {}
	if string.find(text, "/", 1, true) then
		for part in string.gmatch(text, "[^/]+") do
			table.insert(names, part)
		end
	else
		while #text > 0 do
			local quoted, rest = string.match(text, '^%[%s*"(.-)"%s*%]%.?(.*)$')
			if quoted then
				table.insert(names, quoted)
				text = rest
			else
				local plain, after = string.match(text, "^([^%.%[]+)%.?(.*)$")
				if not plain then
					break
				end
				table.insert(names, plain)
				text = after
			end
		end
	end
	if names[1] == "game" then
		table.remove(names, 1)
	end
	local current: Instance = game
	for index, name in names do
		local child = current:FindFirstChild(name)
		if not child and index == 1 then
			local ok, service = pcall(game.GetService, game, name)
			if ok and typeof(service) == "Instance" then
				child = service
			end
		end
		if not child then
			return nil
		end
		current = child
	end
	return current
end

local function luaPath(instance: Instance): string
	local names = {}
	local at: Instance? = instance
	while at and at ~= game do
		table.insert(names, 1, at.Name)
		at = at.Parent
	end
	local parts = { "game" }
	for _, name in names do
		table.insert(parts, if string.match(name, "^[%a_][%w_]*$") then `.{name}` else string.format("[%q]", name))
	end
	return table.concat(parts)
end

local function propertyNames(instance: Instance): { string }
	local ok, props = pcall(function()
		return game:GetService("ReflectionService"):GetPropertiesOfClass(instance.ClassName)
	end)
	if ok and type(props) == "table" and #props > 0 then
		local names = {}
		for _, prop in props do
			local name = type(prop) == "table" and prop.Name
			if type(name) == "string" then
				table.insert(names, name)
			end
		end
		if #names > 0 then
			return names
		end
	end
	return COMMON_PROPS
end

local function childrenNode(instance: Instance, depth: number)
	local ok, children = pcall(instance.GetChildren, instance)
	local list = if ok then children else {}
	local node: any = { name = instance.Name, className = instance.ClassName, children = #list }
	if depth > 0 and #list > 0 then
		node.list = {}
		for index = 1, math.min(#list, MAX_CHILDREN) do
			table.insert(node.list, childrenNode(list[index], depth - 1))
		end
		if #list > MAX_CHILDREN then
			node.more = #list - MAX_CHILDREN
		end
	end
	return node
end

local function inspect(args): string
	local path = if type(args.path) == "string" then args.path else ""
	local instance = resolvePath(path)
	if not instance then
		error(`no instance at {string.sub(path, 1, 200)}`, 0)
	end
	local depth = if type(args.depth) == "number" then math.clamp(math.floor(args.depth), 0, 3) else 1
	local reply: any = { path = luaPath(instance), className = instance.ClassName }
	if args.properties ~= false then
		local props = {}
		local count = 0
		for _, name in propertyNames(instance) do
			if count >= MAX_PROPS then
				break
			end
			local ok, value = pcall(function()
				return (instance :: any)[name]
			end)
			if ok and value ~= nil then
				props[name] = string.sub(encode(value), 1, 300)
				count += 1
			end
		end
		reply.properties = props
		local attrs = {}
		for name, value in instance:GetAttributes() do
			attrs[name] = string.sub(encode(value), 1, 300)
		end
		reply.attributes = attrs
		reply.tags = instance:GetTags()
	end
	reply.tree = childrenNode(instance, depth)
	return toJson(reply)
end

local function find(args): string
	local query = string.lower(if type(args.query) == "string" then args.query else "")
	if query == "" then
		error("empty query", 0)
	end
	local root = if type(args.under) == "string" then resolvePath(args.under) else game
	if not root then
		error(`no instance at {string.sub(tostring(args.under), 1, 200)}`, 0)
	end
	local limit = if type(args.limit) == "number" then math.clamp(math.floor(args.limit), 1, 200) else 50
	local hits = {}
	local queue = { root }
	local head = 1
	local visits = 0
	while head <= #queue and #hits < limit and visits < FIND_VISITS do
		local instance = queue[head]
		head += 1
		visits += 1
		if visits % 1000 == 0 then
			task.wait()
		end
		local ok, matched = pcall(function()
			return string.find(string.lower(instance.Name), query, 1, true) ~= nil or string.find(string.lower(instance.ClassName), query, 1, true) ~= nil
		end)
		if ok and matched and instance ~= root then
			table.insert(hits, { path = luaPath(instance), className = instance.ClassName })
		end
		local childrenOk, children = pcall(instance.GetChildren, instance)
		if childrenOk then
			for _, child in children do
				table.insert(queue, child)
			end
		end
	end
	return toJson({ hits = hits, capped = #hits >= limit or visits >= FIND_VISITS, visited = visits })
end

local LOG_KINDS = {
	[Enum.MessageType.MessageOutput] = "print",
	[Enum.MessageType.MessageInfo] = "info",
	[Enum.MessageType.MessageWarning] = "warn",
	[Enum.MessageType.MessageError] = "error",
}

-- Studio output as `[index] [HH:MM:SS] kind text`, oldest first; `since` is an index from an earlier call.
local function gameLogs(args): string
	local history = LogService:GetLogHistory()
	local since = if type(args.since) == "number" then args.since else 0
	local filter = if type(args.filter) == "string" and args.filter ~= "" then string.lower(args.filter) else nil
	local limit = if type(args.limit) == "number" then math.clamp(math.floor(args.limit), 1, 500) else 100
	local lines = {}
	for index, entry in history do
		if index > since and (not filter or string.find(string.lower(entry.message), filter, 1, true)) then
			local kind = LOG_KINDS[entry.messageType] or "log"
			table.insert(lines, `[{index}] [{os.date("!%H:%M:%S", math.floor(entry.timestamp))}] {kind} {string.sub(entry.message, 1, LINE_CHARS)}`)
		end
	end
	local dropped = math.max(0, #lines - limit)
	local kept = table.move(lines, dropped + 1, #lines, 1, {})
	local header = `Studio output: {#kept} line(s){if dropped > 0 then `, {dropped} older dropped` else ""}; next since = {#history}`
	return cut(header .. "\n" .. table.concat(kept, "\n"), MAX_DATA)
end

local function gameStatus(): string
	local selected = {}
	for index, instance in Selection:Get() do
		if index > 20 then
			break
		end
		table.insert(selected, { path = luaPath(instance), className = instance.ClassName })
	end
	return toJson({
		where = "Roblox Studio",
		mode = if RunService:IsRunning() then "playtest" else "edit",
		placeName = game.Name,
		placeId = game.PlaceId,
		gameId = game.GameId,
		selection = selected,
		workspaceChildren = #workspace:GetChildren(),
	})
end

local function answer(request): any
	local args = if type(request.args) == "table" then request.args else {}
	local tool = request.tool
	local ok, data = pcall(function()
		if tool == "inspect" then
			return inspect(args)
		elseif tool == "find" then
			return find(args)
		elseif tool == "game_logs" then
			return gameLogs(args)
		elseif tool == "game_status" then
			return gameStatus()
		end
		error(`{tostring(tool)} is not available in Studio`, 0)
	end)
	if ok then
		return { ok = true, output = {}, data = data }
	end
	return { ok = false, output = {}, error = string.sub(tostring(data), 1, LINE_CHARS) }
end

-- Polls for this chat's tool requests while a prompt runs (Edit DataModel only), and answers each once.
function StudioTools.start(claude, userId: () -> number)
	if not RunService:IsEdit() then
		return
	end
	local handled: { [string]: boolean } = {}
	local function v1(method: string, path: string, body: any?)
		return claude:request("POST", "/tt/claude/v1", { user = userId(), method = method, path = path, body = body })
	end
	local function ours(promptId: any): boolean
		for _, message in claude.messages do
			if message.id == promptId then
				return true
			end
		end
		return false
	end
	local function handle(id: string)
		local ok, request = v1("GET", `/v1/game/requests/{id}`)
		if not ok or type(request) ~= "table" then
			return
		end
		local result = answer(request)
		v1("POST", `/v1/game/requests/{id}/result`, result)
	end
	task.spawn(function()
		while true do
			task.wait(0.5)
			if claude:running() then
				local ok, reply = v1("GET", "/v1/game/pending")
				if ok and type(reply) == "table" and type(reply.requests) == "table" then
					for _, pending in reply.requests do
						local id = pending.id
						if type(id) == "string" and string.match(id, REQUEST_ID) and not handled[id] and ours(pending.promptId) then
							handled[id] = true
							task.spawn(handle, id)
						end
					end
				end
			end
		end
	end)
end

-- For tests and the Agent: the tools without the polling.
StudioTools.answer = answer
StudioTools.resolvePath = resolvePath

return StudioTools
