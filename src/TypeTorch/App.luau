--!nonstrict
-- The plugin's controller. In edit mode it finds `typetorch serve` by itself (Control.discover every 2 s), attaches to
-- the server whose universeId matches this place, runs Rojo's ServeSession against that server's Rojo, and reconnects
-- on its own whenever the connection drops: nobody clicks Connect. A place that doesn't match (another experience, or
-- an unpublished file) is never synced without a click on "Connect anyway".
-- In every mode it also listens for an agent's commands and forwards Studio's Output (Agent.luau). In a playtest's
-- server it also syncs Rojo into the running game ("Live playtest", on by default) and sets LiveReload on
-- ServerStorage.TypeTorchDev while that sync is up, so the kernel (0.5.4+) remounts the local payload on each change:
-- code changes reach the playtest without Stop + Play.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Root = script.Parent.Parent
local Rojo = Root.Rojo
local ApiContext = require(Rojo.Plugin.ApiContext)
local ServeSession = require(Rojo.Plugin.ServeSession)
local Log = require(Rojo.Packages.Log)

local Agent = require(script.Parent.Agent)
local Assets = require(script.Parent.Assets)
local Claude = require(script.Parent.Claude)
local Control = require(script.Parent.Control)
local Panel = require(script.Parent.Panel)

local App = {}

local VERSION = "0.7.1"
local PROBE_SECONDS = 2
local HEARTBEAT_SECONDS = 5
local STATUS_SECONDS = 3
local MAX_BACKOFF = 5
-- After this many empty probes in a row, probe less often.
local IDLE_PROBES = 15
local IDLE_PROBE_SECONDS = 5
local AGENT_RECONNECT_WAIT = 10
-- After the playtest sync connects, wait this long before turning LiveReload on: Rojo's first sync isn't a change.
local LIVE_RELOAD_DELAY = 1
local LIVE_SETTING = "TypeTorch_livePlaytest"
-- { url, token } of a paired remote serve (`typetorch serve --remote` behind a tunnel); nil: local serve.
local REMOTE_SETTING = "TypeTorch_remote"
-- Must match REMOTE_DEFAULT_PORT in cli src/serve/remote.ts.
local LOCAL_GATEWAY_PORT = 34890
-- The key the Play client's requests carry through the server's bridge (Control.serveBridge); Edit makes it.
local BRIDGE_SETTING = "TypeTorch_bridgeKey"

type Server = { port: Control.Endpoint, hello: Control.Hello }

local state = {
	id = HttpService:GenerateGUID(false),
	mode = "edit",
	plugin = nil :: Plugin?,
	autoConnect = true,
	-- "waiting" (no serve found), "confirm" (found, needs a click), "connecting", "connected", "disconnected", "paused"
	phase = "waiting",
	detail = "",
	server = nil :: Server?,
	candidates = {} :: { Server },
	confirmed = {} :: { [number]: boolean }, -- pid -> clicked "Connect anyway"
	anyway = false, -- an agent asked to connect anyway: accept the server whatever its experience
	emptyProbes = 0,
	session = nil,
	lastSyncAt = nil :: number?,
	patches = 0,
	backoff = 1,
	status = nil, -- the last GET /tt/status (compile state, children)
	-- The Hot assets card: what the place marks (scanned here), what the lockfile knows (GET /tt/assets), the last job,
	-- the last check's per-key diffs (the Diff button), and what the automatic check compares against: the export it
	-- last sent (`lastExport`: its bytes and the lockfile's hashes then), so an unchanged place costs no job.
	assets = {
		marked = {},
		scanned = false,
		lock = nil,
		lockSig = "",
		changes = nil,
		diffs = {},
		message = "",
		job = nil,
		jobServer = nil,
		jobText = "",
		checkedAt = nil :: number?,
		lastCheckClock = nil :: number?,
		lastExport = nil,
	},
	wake = nil :: thread?,
	remoteMessage = "",
	-- When the sync last dropped (and which project it was): set until it connects again, so a serve that went away
	-- shows as Disconnected rather than as a fresh "Waiting". A deliberate switch (pairing, auto-connect off) clears it.
	lostAt = nil :: number?,
	lostProject = nil :: string?,
}

local panel
local createUi: (Plugin) -> ()
local checkAssets: () -> ()

local function settingKey(): string
	return `TypeTorch_autoConnect_{if game.PlaceId ~= 0 then tostring(game.PlaceId) else "local"}`
end

-- The serve pid the user (or an agent) accepted for this place with "Connect anyway"; read by the playtest.
local function confirmedKey(): string
	return `TypeTorch_confirmedPid_{if game.PlaceId ~= 0 then tostring(game.PlaceId) else "local"}`
end

local function livePlaytest(): boolean
	local saved = state.plugin and state.plugin:GetSetting(LIVE_SETTING)
	return saved ~= false
end

local liveGeneration = 0

-- The kernel watches ServerStorage.TypeTorchDev's LiveReload attribute (playtest server only).
local function setLiveReload(on: boolean)
	liveGeneration += 1
	local generation = liveGeneration
	local dev = ServerStorage:FindFirstChild("TypeTorchDev")
	if not dev then
		return
	end
	if not on then
		dev:SetAttribute("LiveReload", nil)
		return
	end
	task.delay(LIVE_RELOAD_DELAY, function()
		if generation == liveGeneration and dev.Parent then
			dev:SetAttribute("LiveReload", true)
		end
	end)
end

local function render()
	if panel then
		panel:render(state)
	end
end

local function setPhase(phase: string, detail: string?)
	state.phase = phase
	state.detail = detail or ""
	render()
end

-- Tells serve what this plugin is doing (also its heartbeat). Failures are fine: serve may be gone.
local function report()
	local server = state.server
	-- The Play client's copy only shows status: the server's copy reports for the playtest.
	if not server or state.mode == "client" then
		return
	end
	local status = if state.phase == "connected"
		then "connected"
		elseif state.phase == "connecting" then "connecting"
		elseif state.phase == "paused" then "paused"
		elseif state.phase == "confirm" or state.phase == "idle" then "idle"
		else "disconnected"
	local ok = Control.request(server.port, "POST", "/tt/plugin/state", { id = state.id, status = status, detail = state.detail })
	if not ok then
		-- Unknown id after a serve restart: register again.
		Control.request(server.port, "POST", "/tt/plugin/hello", App.helloBody())
	end
end

function App.helloBody()
	return {
		id = state.id,
		mode = state.mode,
		placeId = game.PlaceId,
		gameId = game.GameId,
		placeName = game.Name,
		pluginVersion = VERSION,
	}
end

-- Which server to attach to: the one for this experience; an unpublished place only when exactly one runs.
local function choose(found: { Server }): (Server?, boolean)
	for _, server in found do
		if game.GameId ~= 0 and server.hello.universeId == game.GameId then
			return server, true
		end
	end
	if #found == 1 or (state.anyway and #found > 0) then
		return found[1], false
	end
	return nil, false
end

local function stopSession()
	local session = state.session
	state.session = nil
	if session then
		pcall(session.stop, session)
	end
end

-- Wakes the main loop early (a click, a reconnect request).
local function wake()
	local thread = state.wake
	if thread and coroutine.status(thread) == "suspended" then
		state.wake = nil
		task.spawn(thread)
	end
end

local function waitOrWake(seconds: number)
	state.wake = coroutine.running()
	local timer = task.delay(seconds, function()
		wake()
	end)
	coroutine.yield()
	pcall(task.cancel, timer)
end

-- Starts Rojo's sync against `server`. Returns when the session is connected or failed.
local function connect(server: Server)
	state.server = server
	setPhase(
		"connecting",
		if type(server.port) == "table"
			then `{server.hello.project} at {server.port.url}`
			else `{server.hello.project} on port {server.hello.rojoPort}`
	)
	Control.request(server.port, "POST", "/tt/plugin/hello", App.helloBody())
	local api = ApiContext.new(Control.rojoUrl(server.port, server.hello))
	local session = ServeSession.new({ apiContext = api, twoWaySync = false })
	state.session = session
	local settled = false
	local synced = false
	session:onStatusChanged(function(status, detail)
		if state.session ~= session then
			return
		end
		if status == ServeSession.Status.Connected then
			state.backoff = 1
			state.lastSyncAt = os.time()
			synced = true
			state.lostAt = nil
			setPhase("connected", `{server.hello.project} ({server.hello.projectFile})`)
			if state.mode == "edit" then
				-- serve may have restarted or be another one: look at the hot assets again.
				task.spawn(checkAssets)
			end
		elseif status == ServeSession.Status.Disconnected then
			state.session = nil
			if synced and not state.lostAt then
				state.lostAt = os.time()
				state.lostProject = server.hello.project
			end
			setPhase("disconnected", if detail then `Retrying: {detail}` else "Connection closed, retrying")
		end
		if state.mode == "server" then
			setLiveReload(status == ServeSession.Status.Connected)
		end
		if status ~= ServeSession.Status.Connecting then
			settled = true
			report()
			wake()
		end
	end)
	session:hookPostcommit(function()
		state.lastSyncAt = os.time()
		state.patches += 1
		render()
	end)
	session:start()
	while not settled and state.session == session do
		waitOrWake(1)
	end
end

local function loop()
	local lastHeartbeat = 0
	while state.plugin do
		if state.session then
			-- Connected: heartbeat; notice a restarted serve (new pid) and reattach to it.
			if os.clock() - lastHeartbeat >= HEARTBEAT_SECONDS then
				lastHeartbeat = os.clock()
				local server = state.server
				local ok, hello = Control.request(server.port, "GET", "/tt/hello")
				if ok and hello.pid ~= server.hello.pid then
					stopSession()
					state.lostAt = os.time()
					state.lostProject = server.hello.project
					setPhase("disconnected", "typetorch serve restarted, reconnecting")
				else
					report()
				end
			end
			waitOrWake(1)
		else
			-- Keep finding serve even when not syncing, so an agent's commands still reach this plugin.
			local found = Control.discover()
			state.candidates = found
			local server, matches = choose(found)
			if server then
				state.emptyProbes = 0
			else
				state.emptyProbes += 1
			end
			if not state.autoConnect then
				state.server = server
				setPhase("paused", "Auto-connect is off")
				report()
				waitOrWake(PROBE_SECONDS)
			elseif not server then
				state.server = nil
				local reason = if Control.remote
					then `Can't reach {Control.remote.url}: {Control.lastRemoteError or "no answer"}`
					elseif #found == 0 then "Run `typetorch serve` in the game folder"
					else `{#found} servers run, none for this experience ({game.GameId})`
				-- After a drop it stays Disconnected (red) until serve is back, retrying meanwhile.
				setPhase(if state.lostAt then "disconnected" else "waiting", reason)
				waitOrWake(if state.emptyProbes > IDLE_PROBES then IDLE_PROBE_SECONDS else PROBE_SECONDS)
			elseif not matches and not state.confirmed[server.hello.pid] and not state.anyway then
				state.server = server
				setPhase(
					"confirm",
					if game.GameId == 0
						then `This place isn't published. Sync {server.hello.project} into it?`
						else `{server.hello.project} is for experience {server.hello.universeId}, this place is {game.GameId}`
				)
				report()
				waitOrWake(PROBE_SECONDS)
			elseif server.hello.rojoPort == 0 then
				state.server = server
				setPhase("connecting", "Rojo is starting")
				waitOrWake(1)
			else
				connect(server)
				if not state.session then
					-- Failed or dropped: retry with a short backoff, re-probing in case serve moved.
					waitOrWake(state.backoff)
					state.backoff = math.min(state.backoff * 2, MAX_BACKOFF)
				end
			end
		end
	end
end

-- Reads serve's status (compile errors, children) while the panel is open.
local ASSET_SCAN_EVERY = 3 -- status ticks
-- Failed polls in a row before a job counts as lost (serve gone).
local JOB_MISSES = 5

local function refreshAssets()
	state.assets.marked = Assets.scan()
	state.assets.scanned = true
	if state.server then
		local ok, lock = Control.request(state.server.port, "GET", "/tt/assets")
		state.assets.lock = if ok then lock else nil
	end
	-- The lockfile's entries as one string (keys and hashes), so the automatic check notices a sync or a commit that
	-- moved the lockfile under it. A serve older than 0.15.0 sends no hashes: the keys alone still count.
	local parts = {}
	local lock = state.assets.lock
	if lock and type(lock.assets) == "table" then
		for key, entry in lock.assets do
			table.insert(parts, `{key}={if type(entry) == "table" and entry.hash then entry.hash else "?"}`)
		end
	end
	table.sort(parts)
	state.assets.lockSig = table.concat(parts, ";")
end

local function statusLoop()
	local ticks = 0
	while state.plugin do
		if panel and panel:isOpen() then
			if state.server then
				local ok, status = Control.request(state.server.port, "GET", "/tt/status")
				state.status = if ok then status else nil
			end
			if state.mode == "edit" and ticks % ASSET_SCAN_EVERY == 0 then
				refreshAssets()
			end
			ticks += 1
			render()
		end
		task.wait(STATUS_SECONDS)
	end
end

-- After (re)connecting: rescan the place and, when there are hot assets, run a quiet Check against this serve.
checkAssets = function()
	refreshAssets()
	local lock = state.assets.lock
	if #state.assets.marked > 0 or (lock and lock.assets and next(lock.assets) ~= nil) then
		App.runJob("assets-status", true)
	else
		render()
	end
end

local function assetsMessage(text: string)
	state.assets.message = text
	refreshAssets()
	render()
end

-- The last check's verdict per key ("added", "updated", "unchanged"), from a job's `changes`.
local function rememberChanges(job)
	local result = job and job.result
	if type(result) ~= "table" or type(result.changes) ~= "table" then
		return
	end
	local byKey = {}
	local diffs = {}
	for _, change in result.changes do
		if type(change) == "table" and type(change.key) == "string" then
			-- after an upload everything it sent is up to date
			byKey[change.key] = if result.dryRun or change.error then change.status else "unchanged"
			-- a check's diff per key (cli 0.15.0+; an older serve sends none, and the panel shows no Diff button)
			if result.dryRun and type(change.diff) == "table" then
				diffs[change.key] = change.diff
			end
		end
	end
	state.assets.changes = byKey
	state.assets.diffs = diffs
end

function App.addSelection(name: string)
	local ok, message = Assets.addSelection(name)
	assetsMessage(message)
	if ok then
		App.runJob("assets-status", true)
	end
end

function App.removeSelection()
	local ok, message = Assets.removeSelection()
	assetsMessage(message)
	if ok then
		App.runJob("assets-status", true)
	end
end

-- What the automatic check compares between two exports: the serialized assets and each one's key, parent path,
-- name and class (a moved asset keeps its bytes but changes the lockfile's path).
local function exportSig(export): string
	local parts = {}
	for _, meta in export.assets do
		table.insert(parts, `{meta.key}:{table.concat(meta.path, "/")}/{meta.name}:{meta.className}`)
	end
	return `{export.binary}|{table.concat(parts, ";")}`
end

-- Exports the place's hot assets and runs a job on them in typetorch serve, following it until it ends. `quiet`: an
-- automatic check (no message when serve isn't there). `auto`: the timed check: a problem in the place is skipped
-- silently (the card already shows it), and an export equal to the last check's, with the lockfile unchanged, is
-- counted as checked without a job.
function App.runJob(kind: string, quiet: boolean?, auto: boolean?)
	local server = state.server
	if not server then
		if not quiet then
			assetsMessage("Start typetorch serve first")
		end
		return
	end
	-- One job at a time per serve; a job left running on a serve that went away doesn't block the new one.
	if state.assets.job and state.assets.job.state == "running" and state.assets.jobServer == server then
		return
	end
	local check = kind == "assets-status"
	if check then
		state.assets.lastCheckClock = os.clock()
	end
	if not auto then
		state.assets.jobText = "Exporting from this place"
		render()
	end
	local exported, export = Assets.export()
	if not exported then
		if not auto then
			state.assets.jobText = ""
			assetsMessage(export)
		end
		return
	end
	local last = state.assets.lastExport
	if auto and last and last.sig == exportSig(export) and last.lockSig == state.assets.lockSig then
		state.assets.checkedAt = os.time()
		render()
		return
	end
	if not quiet then
		state.assets.message = ""
	end
	local ok, job = Control.request(server.port, "POST", "/tt/jobs", { kind = kind, export = export })
	if not ok then
		state.assets.job = nil
		state.assets.jobText = `Couldn't start: {job}`
		render()
		return
	end
	state.assets.job = job
	state.assets.jobServer = server
	task.spawn(function()
		local misses = 0
		while state.plugin and job.state == "running" do
			state.assets.jobText = Assets.describeJob(job)
			render()
			task.wait(1)
			if state.assets.job ~= job then
				return -- a newer job replaced it
			end
			local polled, latest = Control.request(server.port, "GET", `/tt/jobs?id={job.id}`)
			if polled then
				misses = 0
				job = latest
				state.assets.job = job
			else
				misses += 1
				if misses >= JOB_MISSES or state.server ~= server then
					job = { id = job.id, state = "failed", error = "lost the connection to typetorch serve" }
					state.assets.job = job
				end
			end
		end
		if state.assets.job ~= job then
			return
		end
		state.assets.jobText = Assets.describeJob(job)
		if job.state == "done" then
			rememberChanges(job)
		end
		refreshAssets()
		if check and job.state == "done" then
			-- the next automatic check skips its job while the place and the lockfile stay as they are now
			state.assets.checkedAt = os.time()
			state.assets.lastExport = { sig = exportSig(export), lockSig = state.assets.lockSig }
		elseif not check then
			state.assets.lastExport = nil
		end
		render()
	end)
end

-- The timed check (AUTO_CHECK_SECONDS after the last one started): only with the panel open in edit mode, serve
-- attached, hot assets marked and no job running; it never queues (one loop, and a running job is skipped). Most
-- rounds end at the export comparison in runJob and never reach serve.
local AUTO_CHECK_SECONDS = 30

local function autoCheckLoop()
	while state.plugin do
		task.wait(1)
		local assets = state.assets
		local due = assets.lastCheckClock == nil or os.clock() - assets.lastCheckClock >= AUTO_CHECK_SECONDS
		if
			due
			and panel
			and panel:isOpen()
			and state.mode == "edit"
			and state.server ~= nil
			and state.phase ~= "confirm"
			and assets.scanned
			and #assets.marked > 0
			and not (assets.job and assets.job.state == "running")
		then
			App.runJob("assets-status", true, true)
		end
	end
end

-- Drops the connection and starts over (a full resync).
local function loadRemote()
	local saved = state.plugin and state.plugin:GetSetting(REMOTE_SETTING)
	if type(saved) == "table" and type(saved.url) == "string" and type(saved.token) == "string" then
		Control.remote = { url = saved.url, token = saved.token }
	else
		Control.remote = nil
	end
end

-- Who this Studio is, for the owner's `typetorch serve devices`.
local function deviceName(): string
	local ok, name = pcall(function()
		local userId = game:GetService("StudioService"):GetUserId()
		return game:GetService("Players"):GetNameFromUserIdAsync(userId)
	end)
	return if ok and type(name) == "string" then name else "Studio"
end

-- Pairs with a remote serve: `url` is the owner's tunnel, `code` from `typetorch serve pair`.
-- `link`: the pairing link `<url>#<code>` that `typetorch serve pair --url` prints (split on the last '#'), or a bare
-- code for a serve --remote on this machine (its gateway's default port).
function App.pairRemote(link: string)
	link = Control.trimUrl(link)
	local url, code = string.match(link, "^(.*)#([^#]*)$")
	if url == nil then
		url, code = `http://localhost:{LOCAL_GATEWAY_PORT}`, link
	end
	url = Control.trimUrl(url)
	code = Control.trimUrl(code)
	if not string.match(url, "^https?://[%w%.%-]+") then
		state.remoteMessage = "Paste the whole link, e.g. https://serve.example.com#code"
		render()
		return
	end
	if code == "" then
		state.remoteMessage = "The link has no code after '#': run `typetorch serve pair --url` again"
		render()
		return
	end
	state.remoteMessage = "Pairing"
	render()
	local okId, userId = pcall(function()
		return game:GetService("StudioService"):GetUserId()
	end)
	local ok, token = Control.pair(url, code, deviceName(), if okId then userId else nil)
	if not ok then
		state.remoteMessage = `Couldn't pair: {token}`
		render()
		return
	end
	state.plugin:SetSetting(REMOTE_SETTING, { url = url, token = token })
	state.remoteMessage = `Paired with {url}`
	state.lostAt = nil
	loadRemote()
	App.reconnect()
end

-- Back to the local serve (the pairing stays valid on the owner's side until they unpair it).
function App.forgetRemote()
	state.plugin:SetSetting(REMOTE_SETTING, nil)
	state.remoteMessage = "Using the typetorch serve on this computer"
	state.lostAt = nil
	loadRemote()
	App.reconnect()
end

function App.reconnect()
	stopSession()
	state.backoff = 1
	setPhase("connecting", "Reconnecting")
	wake()
end

function App.setAutoConnect(on: boolean)
	state.autoConnect = on
	if state.plugin then
		state.plugin:SetSetting(settingKey(), on)
	end
	if not on then
		stopSession()
		state.lostAt = nil
	end
	wake()
end

function App.confirm()
	if state.server then
		state.confirmed[state.server.hello.pid] = true
		if state.plugin then
			state.plugin:SetSetting(confirmedKey(), state.server.hello.pid)
		end
	end
	wake()
end

function App.setLivePlaytest(on: boolean)
	if state.plugin then
		state.plugin:SetSetting(LIVE_SETTING, on)
	end
	render()
end

-- An agent's "reconnect": auto-connect on, resync from scratch, and wait (a while) to say how it went.
local function agentReconnect(args)
	if args.anyway then
		state.anyway = true
		if state.server then
			App.confirm()
		end
	end
	if not state.autoConnect then
		App.setAutoConnect(true)
	end
	App.reconnect()
	local started = os.clock()
	while os.clock() - started < AGENT_RECONNECT_WAIT do
		task.wait(0.25)
		if state.phase == "connected" then
			break
		end
		-- Nothing to connect to, or waiting for a click: no use waiting longer.
		if
			(state.phase == "waiting" or state.phase == "confirm" or state.phase == "disconnected")
			and os.clock() - started > 3
		then
			break
		end
	end
	return true, { phase = state.phase, detail = state.detail }
end

local function testService()
	local ok, service = pcall(game.GetService, game, "StudioTestService")
	return if ok then service else nil
end

-- Starts a playtest. ExecutePlayModeAsync yields until the test ends, so it runs on its own thread; an error within
-- the first moments is reported as the command's failure.
local function agentPlay(args)
	local service = testService()
	local runMode = args.mode == "run"
	local failure
	task.spawn(function()
		local ok, err
		if service then
			ok, err = pcall(function()
				if runMode then
					service:ExecuteRunModeAsync({})
				else
					service:ExecutePlayModeAsync({})
				end
			end)
		else
			ok, err = false, "StudioTestService isn't available in this Studio"
		end
		if not ok and runMode then
			ok, err = pcall(RunService.Run, RunService)
		end
		if not ok then
			failure = tostring(err)
		end
	end)
	task.wait(1.5)
	if failure then
		return false, `couldn't start the playtest: {failure}`
	end
	return true, { mode = if runMode then "run" else "play" }
end

local function agentStop()
	if state.mode == "server" then
		local service = testService()
		if not service then
			return false, "StudioTestService isn't available in this Studio"
		end
		local ok, err = pcall(service.EndTest, service, {})
		if not ok then
			return false, `couldn't end the playtest: {err}`
		end
		return true, {}
	elseif state.mode == "edit" then
		if not RunService:IsRunning() then
			return false, "no playtest server is attached; is a playtest running?"
		end
		local ok, err = pcall(RunService.Stop, RunService)
		if not ok then
			return false, `couldn't stop Run mode: {err}`
		end
		return true, {}
	end
	return false, "send stop to the playtest server (the default target)"
end

local function startAgent()
	local handlers = {
		ping = function()
			return true, {
				mode = state.mode,
				phase = state.phase,
				detail = state.detail,
				livePlaytest = livePlaytest(),
			}
		end,
		stop = agentStop,
	}
	if state.mode == "edit" then
		handlers.reconnect = agentReconnect
		handlers.play = agentPlay
	end
	Agent.start({
		id = state.id,
		mode = state.mode,
		server = function()
			return state.server
		end,
		helloBody = App.helloBody,
		alive = function()
			return state.plugin ~= nil
		end,
		handlers = handlers,
		onReconnectAttribute = if state.mode == "edit"
			then function()
				task.spawn(agentReconnect, { anyway = false })
			end
			else nil,
	})
end

-- Whether the playtest may sync from `server`: the same rule as the edit session (its experience, or the serve the
-- user accepted with "Connect anyway"), and only while the edit session's auto-connect is on.
local function playtestMaySync(server: Server, matches: boolean): boolean
	if not livePlaytest() or state.plugin:GetSetting(settingKey()) == false then
		return false
	end
	return matches or state.plugin:GetSetting(confirmedKey()) == server.hello.pid
end

-- A playtest's server or client DataModel: the agent's commands and the Output; on the server, the live sync too.
local function playtestLoop()
	while state.plugin do
		local found = Control.discover()
		local server, matches = choose(found)
		if server and (not state.server or state.server.hello.pid ~= server.hello.pid) then
			stopSession() -- serve restarted: start over
			state.server = server
			-- The client only shows status and the Claude window: the server's copy is the playtest's plugin.
			if state.mode ~= "client" then
				Control.request(server.port, "POST", "/tt/plugin/hello", App.helloBody())
			end
		elseif not server then
			stopSession()
			state.server = nil
		end
		if state.server then
			local current = state.server
			if
				state.mode == "server"
				and not state.session
				and current.hello.rojoPort ~= 0
				and playtestMaySync(current, matches)
			then
				connect(current)
			elseif state.mode == "server" and state.session and not livePlaytest() then
				stopSession()
				setLiveReload(false)
				setPhase("idle", "Live playtest is off")
			end
			report()
		end
		-- Until attached, look again soon: the server's copy may not have opened the bridge yet.
		task.wait(if state.server then HEARTBEAT_SECONDS else 1)
	end
end

local function bridgeKey(plugin: Plugin): string
	local key = plugin:GetSetting(BRIDGE_SETTING)
	if type(key) ~= "string" then
		key = HttpService:GenerateGUID(false)
		plugin:SetSetting(BRIDGE_SETTING, key)
	end
	return key
end

function App.start(plugin: Plugin)
	state.plugin = plugin
	Control.settings = plugin
	plugin.Unloading:Connect(function()
		state.plugin = nil
		stopSession()
		wake()
	end)
	loadRemote()
	local saved = plugin:GetSetting(settingKey())
	state.autoConnect = if saved == nil then true else saved == true
	Log.setLogLevelThunk(function()
		return Log.Level.Warning
	end)
	if not RunService:IsEdit() then
		state.mode = if RunService:IsServer() then "server" else "client"
		state.phase = "idle"
		if state.mode == "client" then
			Control.viaBridge = true
			Control.bridgeKey = function()
				return plugin:GetSetting(BRIDGE_SETTING)
			end
		elseif not RunService:IsRunMode() then
			Control.serveBridge(bridgeKey(plugin))
		end
		-- Studio shows the toolbar and windows of the DataModel in view: the client in Play, the server in Run. Without
		-- them there, the TypeTorch and Claude buttons and windows vanish until Stop.
		if RunService:IsClient() or RunService:IsRunMode() then
			createUi(plugin)
			render()
			task.spawn(statusLoop)
		end
		task.spawn(playtestLoop)
		if state.mode ~= "client" then
			startAgent()
		end
		return
	end
	bridgeKey(plugin)
	createUi(plugin)
	render()
	task.spawn(loop)
	task.spawn(statusLoop)
	task.spawn(autoCheckLoop)
	startAgent()
end

-- The TypeTorch panel and the Claude window.
createUi = function(plugin: Plugin)
	panel = Panel.new(plugin, {
		reconnect = App.reconnect,
		setAutoConnect = App.setAutoConnect,
		confirm = App.confirm,
		setLivePlaytest = App.setLivePlaytest,
		addSelection = App.addSelection,
		removeSelection = App.removeSelection,
		runJob = App.runJob,
		suggestKey = Assets.suggestKey,
		pairRemote = App.pairRemote,
		forgetRemote = App.forgetRemote,
	}, VERSION)
	Claude.new(plugin, panel.toolbar, function()
		return if state.server then state.server.port else nil
	end)
end

return App
