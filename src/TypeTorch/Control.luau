--!strict
-- HTTP calls to `typetorch serve`'s control API (cli src/serve/protocol.ts). Every request carries X-TypeTorch: 1.
-- An endpoint is a local port, or a remote serve (`serve --remote` behind a tunnel): its URL and this Studio's device
-- token, sent as `Authorization: Bearer`. With a remote set (Control.remote), discovery asks only it.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Control = {}

-- Must match CONTROL_PORTS in cli src/serve/protocol.ts.
Control.PORTS = { 34880, 34881, 34882, 34883, 34884, 34885, 34886, 34887 }
Control.HOST = "localhost"

export type Remote = { url: string, token: string }
export type Endpoint = number | Remote

-- Set by App from the plugin's settings (the panel's Remote card).
Control.remote = nil :: Remote?
Control.lastRemoteError = nil :: string?

export type Hello = {
	app: string,
	api: number,
	project: string,
	universeId: number,
	placeId: number,
	rojoPort: number,
	projectFile: string,
	pid: number,
	startedAt: string,
}

-- `https://host/` -> `https://host`
function Control.trimUrl(url: string): string
	url = string.gsub(url, "^%s+", "")
	url = string.gsub(url, "[%s/]+$", "")
	return url
end

-- Where Rojo answers for an endpoint: the local port, or the remote gateway's token path.
function Control.rojoUrl(endpoint: Endpoint, hello: Hello): string
	if type(endpoint) == "table" then
		return `{endpoint.url}/r/{endpoint.token}`
	end
	return `http://{Control.HOST}:{hello.rojoPort}`
end

function Control.describe(endpoint: Endpoint): string
	return if type(endpoint) == "table" then endpoint.url else `port {endpoint}`
end

-- In Play the client DataModel can't make HTTP requests (only the game server can), so the server DataModel's copy
-- of the plugin relays them through a RemoteFunction. Calls carry a key from the plugin settings, which game scripts
-- can't read.
local BRIDGE_NAME = "TypeTorchPluginBridge"
Control.bridgeKey = nil :: (() -> string?)?
Control.viaBridge = false

-- The server side: relays the client copy's requests to serve's control API.
function Control.serveBridge(key: string)
	local bridge = Instance.new("RemoteFunction")
	bridge.Name = BRIDGE_NAME
	bridge.Archivable = false
	bridge.OnServerInvoke = function(_player, sentKey, endpoint, method, path, body)
		if sentKey == key and method == "LOGS" then
			-- The Claude window's "Server logs" in the Play client: this (the playtest server's) log history.
			return true, Control.logHistory()
		end
		if sentKey ~= key or type(method) ~= "string" or type(path) ~= "string" or string.sub(path, 1, 4) ~= "/tt/" then
			return false, "refused"
		end
		if type(endpoint) == "table" then
			if not Control.remote or endpoint.url ~= Control.remote.url then
				return false, "refused"
			end
			endpoint = Control.remote
		elseif not table.find(Control.PORTS, endpoint) then
			return false, "refused"
		end
		return Control.request(endpoint, method, path, body)
	end
	bridge.Parent = ReplicatedStorage
end

local function bridged(endpoint: Endpoint, method: string, path: string, body: any?): (boolean, any)
	local bridge = ReplicatedStorage:FindFirstChild(BRIDGE_NAME)
	if not bridge then
		return false, "waiting for the playtest server"
	end
	local ok, success, result = pcall(bridge.InvokeServer, bridge, Control.bridgeKey and Control.bridgeKey(), endpoint, method, path, body)
	if not ok then
		return false, tostring(success)
	end
	return success == true, result
end

-- One request; returns (ok, decoded body or error text). Never throws.
function Control.request(endpoint: Endpoint, method: string, path: string, body: any?): (boolean, any)
	if Control.viaBridge then
		return bridged(endpoint, method, path, body)
	end
	local headers = { ["X-TypeTorch"] = "1", ["Content-Type"] = "application/json" }
	local url
	if type(endpoint) == "table" then
		url = endpoint.url .. path
		headers.Authorization = `Bearer {endpoint.token}`
	else
		url = `http://{Control.HOST}:{endpoint}{path}`
	end
	local ok, response = pcall(HttpService.RequestAsync, HttpService, {
		Url = url,
		Method = method,
		Headers = headers,
		Body = if body ~= nil then HttpService:JSONEncode(body) else nil,
	})
	if not ok then
		return false, tostring(response)
	end
	local decoded
	local decodedOk = pcall(function()
		decoded = HttpService:JSONDecode(response.Body)
	end)
	if not decodedOk then
		return false, `bad response from {Control.describe(endpoint)}`
	end
	if not response.Success then
		return false, if type(decoded) == "table" and decoded.error then decoded.error else `HTTP {response.StatusCode}`
	end
	return true, decoded
end

-- The playtest server's log history, from the Play client (through the bridge). Returns (ok, text or error text).
function Control.serverLogs(): (boolean, any)
	return bridged(0, "LOGS", "", nil)
end

-- "My logs" / "Server logs" for the Claude window: about 64 KB, newest lines kept (framework devtools/claude-tools.ts
-- LOG_ATTACH_BYTES and formatLogHistory).
local LOG_ATTACH_BYTES = 64 * 1024
local LOG_KINDS = {
	[Enum.MessageType.MessageOutput] = "print",
	[Enum.MessageType.MessageInfo] = "info",
	[Enum.MessageType.MessageWarning] = "warn",
	[Enum.MessageType.MessageError] = "error",
}

-- This DataModel's log history as text, one `[HH:MM:SS] kind text` line each (UTC), oldest first, keeping the newest
-- lines that fit; a first line says how many older lines were dropped.
function Control.logHistory(): string
	local entries = game:GetService("LogService"):GetLogHistory()
	local lines = {}
	local bytes = 0
	local dropped = 0
	for index = #entries, 1, -1 do
		local entry = entries[index]
		local text = string.gsub(string.gsub(entry.message, "[\r\n]+", " "), "\0", "")
		local line = `[{os.date("!%H:%M:%S", math.floor(entry.timestamp))}] {LOG_KINDS[entry.messageType] or "print"} {text}`
		if bytes + #line + 1 > LOG_ATTACH_BYTES - 64 then
			dropped = index
			break
		end
		table.insert(lines, line)
		bytes += #line + 1
	end
	local ordered = {}
	if dropped > 0 then
		table.insert(ordered, `({dropped} older lines dropped)`)
	end
	for index = #lines, 1, -1 do
		table.insert(ordered, lines[index])
	end
	return table.concat(ordered, "\n")
end

-- serve's Claude event stream (`/tt/claude/stream`, a WebSocket): its URL and headers for an endpoint. A remote serve
-- knows the device's user from its token; locally the user is named in the URL.
function Control.streamTarget(endpoint: Endpoint, userId: number): (string, { [string]: string })
	local headers = { ["X-TypeTorch"] = "1" }
	if type(endpoint) == "table" then
		headers.Authorization = `Bearer {endpoint.token}`
		local url = string.gsub(endpoint.url, "^http", "ws")
		return `{url}/tt/claude/stream`, headers
	end
	return `ws://{Control.HOST}:{endpoint}/tt/claude/stream?user={userId}`, headers
end

-- Trades a pairing code from `typetorch serve pair` for a device token. `userId`: this Studio's Roblox user, whose
-- prompts the Claude window sends. Returns (ok, token or error text).
function Control.pair(url: string, code: string, name: string, userId: number?): (boolean, string)
	local ok, response = pcall(HttpService.RequestAsync, HttpService, {
		Url = `{Control.trimUrl(url)}/tt/pair`,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = HttpService:JSONEncode({ code = code, name = name, userId = if userId and userId > 0 then userId else nil }),
	})
	if not ok then
		return false, tostring(response)
	end
	local decoded
	pcall(function()
		decoded = HttpService:JSONDecode(response.Body)
	end)
	if type(decoded) ~= "table" then
		return false, `{url} isn't a typetorch serve --remote (HTTP {response.StatusCode})`
	end
	if not response.Success or type(decoded.token) ~= "string" then
		return false, decoded.error or `HTTP {response.StatusCode}`
	end
	return true, decoded.token
end

-- Probes every control port at once (or only the remote serve when one is set); returns the servers that answered
-- as typetorch serve.
function Control.discover(): { { port: Endpoint, hello: Hello } }
	local remote = Control.remote
	if remote then
		local ok, hello = Control.request(remote, "GET", "/tt/hello")
		if ok and type(hello) == "table" and hello.app == "typetorch-serve" then
			return { { port = remote, hello = hello } }
		end
		Control.lastRemoteError = if ok then "not a typetorch serve" else tostring(hello)
		return {}
	end
	local found = {}
	local pending = #Control.PORTS
	local thread = coroutine.running()
	local waiting = false
	for _, port in Control.PORTS do
		task.spawn(function()
			local ok, hello = Control.request(port, "GET", "/tt/hello")
			if ok and type(hello) == "table" and hello.app == "typetorch-serve" then
				table.insert(found, { port = port, hello = hello })
			end
			pending -= 1
			if pending == 0 and waiting then
				task.spawn(thread)
			end
		end)
	end
	if pending > 0 then
		waiting = true
		coroutine.yield()
	end
	table.sort(found, function(a, b)
		return (a.port :: number) < (b.port :: number)
	end)
	return found
end

return Control
