--!nonstrict
-- The plugin's dock widget: sync status, the matched server, the last compile result and the buttons. Same look as
-- the TypeTorch dev menu (Widgets.luau).

local Control = require(script.Parent.Control)
local Icons = require(script.Parent.Icons)
local Widgets = require(script.Parent.Widgets)
local COLORS = Widgets.COLORS
local make = Widgets.make

local Panel = {}
Panel.__index = Panel

-- { label, dot color, toolbar icon }
local PHASES = {
	waiting = { "Waiting for typetorch serve", COLORS.dim, Icons.idle },
	confirm = { "Found a server for another place", COLORS.warn, Icons.connecting },
	connecting = { "Connecting", COLORS.warn, Icons.connecting },
	connected = { "Synced", COLORS.good, Icons.synced },
	disconnected = { "Disconnected, retrying", COLORS.bad, Icons.error },
	paused = { "Paused", COLORS.dim, Icons.idle },
}

local MAX_ERRORS = 8
local MAX_ASSET_LINES = 12

local function ago(t: number?): string
	if not t then
		return "never"
	end
	local seconds = os.time() - t
	if seconds < 5 then
		return "just now"
	elseif seconds < 60 then
		return `{seconds} s ago`
	elseif seconds < 3600 then
		return `{seconds // 60} min ago`
	end
	return `{seconds // 3600} h ago`
end

function Panel.new(plugin: Plugin, actions, version: string)
	local self = setmetatable({}, Panel)
	self.actions = actions
	local toolbar = plugin:CreateToolbar("TypeTorch")
	self.toolbar = toolbar
	local button = toolbar:CreateButton("TypeTorchSync", "TypeTorch sync status", Icons.idle, "TypeTorch")
	button.ClickableWhenViewportHidden = true
	self.button = button
	local widget = plugin:CreateDockWidgetPluginGuiAsync(
		"TypeTorchSync",
		DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 320, 420, 260, 240)
	)
	widget.Title = "TypeTorch"
	widget.Name = "TypeTorchSync"
	self.widget = widget
	button.Click:Connect(function()
		widget.Enabled = not widget.Enabled
	end)
	widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		button:SetActive(widget.Enabled)
	end)

	local background = make("Frame", { BackgroundColor3 = COLORS.window, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) }, widget)
	local scroll = Widgets.scrolling(background)
	Widgets.pad(scroll, 12, 12)
	Widgets.verticalList(scroll, 10)

	local header = Widgets.line(scroll, "TypeTorch Sync", 18, COLORS.text, Enum.Font.BuilderSansBold)
	header.TextWrapped = false
	Widgets.line(scroll, `plugin {version}`, 14, COLORS.dim)

	-- Status card
	local statusCard = Widgets.card(scroll)
	self.dot, self.statusLabel = Widgets.statusLine(statusCard)
	self.detail = Widgets.line(statusCard, "", 14, COLORS.dim)
	self.project = Widgets.line(statusCard, "", 15)
	self.lastSync = Widgets.line(statusCard, "", 14, COLORS.dim)
	local buttons = Widgets.buttonRow(statusCard)
	Widgets.button(buttons, "Reconnect", function()
		actions.reconnect()
	end)
	self.autoButton = Widgets.button(buttons, "Auto-connect: on", function()
		actions.setAutoConnect(not self.autoConnect)
	end)
	self.confirmButton = Widgets.button(buttons, "Connect anyway", function()
		actions.confirm()
	end, COLORS.accent)
	self.confirmButton.TextColor3 = COLORS.dark

	-- Remote card: a typetorch serve on another machine (`serve --remote` behind the owner's tunnel)
	local remoteCard = Widgets.card(scroll)
	Widgets.line(remoteCard, "Remote server", 15, COLORS.text, Enum.Font.BuilderSansBold)
	self.remoteLine = Widgets.line(remoteCard, "", 14, COLORS.dim)
	self.remoteUrl = Widgets.textBox(remoteCard, "server URL, e.g. https://serve.example.com")
	self.remoteCode = Widgets.textBox(remoteCard, "pairing code from the owner")
	local remoteButtons = Widgets.buttonRow(remoteCard)
	self.pairButton = Widgets.button(remoteButtons, "Pair", function()
		actions.pairRemote(self.remoteUrl.Text, self.remoteCode.Text)
	end)
	self.localButton = Widgets.button(remoteButtons, "Use local serve", function()
		actions.forgetRemote()
	end)
	self.remoteMessage = Widgets.line(remoteCard, "", 14, COLORS.dim)

	-- Playtest card
	local playCard = Widgets.card(scroll)
	Widgets.line(playCard, "Playtest", 15, COLORS.text, Enum.Font.BuilderSansBold)
	Widgets.line(playCard, "Live playtest: code changes reach a running playtest without Stop + Play (kernel 0.5.4+).", 14, COLORS.dim)
	local playButtons = Widgets.buttonRow(playCard)
	self.liveButton = Widgets.button(playButtons, "Live playtest: on", function()
		actions.setLivePlaytest(not self.livePlaytest)
	end)

	-- Hot assets card
	local assetsCard = Widgets.card(scroll)
	Widgets.line(assetsCard, "Hot assets", 15, COLORS.text, Enum.Font.BuilderSansBold)
	Widgets.line(
		assetsCard,
		"Select a model or UI in the Explorer and press Add. Publish to dev sends what changed from this Studio: dev servers pick it up without a restart.",
		14,
		COLORS.dim
	)
	self.assetsSummary = Widgets.line(assetsCard, "", 14, COLORS.dim)
	self.assetLines = {}
	for i = 1, MAX_ASSET_LINES do
		local label = Widgets.line(assetsCard, "", 14, COLORS.text, Enum.Font.RobotoMono)
		label.Visible = false
		self.assetLines[i] = label
	end
	self.keyBox = Widgets.textBox(assetsCard, "name (optional, from the selection)")
	local markButtons = Widgets.buttonRow(assetsCard)
	Widgets.button(markButtons, "Add", function()
		actions.addSelection(self.keyBox.Text)
	end)
	Widgets.button(markButtons, "Remove", function()
		actions.removeSelection()
	end)
	local syncButtons = Widgets.buttonRow(assetsCard)
	Widgets.button(syncButtons, "Check", function()
		actions.runJob("assets-status")
	end)
	Widgets.button(syncButtons, "Upload", function()
		actions.runJob("assets-sync")
	end)
	self.deployButton = Widgets.button(syncButtons, "Publish to dev", function()
		actions.runJob("assets-deploy-dev")
	end, COLORS.accent)
	self.deployButton.TextColor3 = COLORS.dark
	self.assetsMessage = Widgets.line(assetsCard, "", 14, COLORS.dim)
	self.jobLine = Widgets.line(assetsCard, "", 14, COLORS.dim)
	game:GetService("Selection").SelectionChanged:Connect(function()
		local selected = game:GetService("Selection"):Get()
		local current = if #selected == 1 then selected[1]:GetAttribute("TypeTorchAsset") else nil
		self.keyBox.Text = if type(current) == "string" then current else ""
	end)

	-- Compile card
	local compileCard = Widgets.card(scroll)
	Widgets.line(compileCard, "Compile", 15, COLORS.text, Enum.Font.BuilderSansBold)
	self.compile = Widgets.line(compileCard, "", 14, COLORS.dim)
	self.errors = {}
	for i = 1, MAX_ERRORS do
		local label = Widgets.line(compileCard, "", 14, COLORS.bad, Enum.Font.RobotoMono)
		label.Visible = false
		self.errors[i] = label
	end

	-- Processes card
	local childrenCard = Widgets.card(scroll)
	Widgets.line(childrenCard, "typetorch serve", 15, COLORS.text, Enum.Font.BuilderSansBold)
	self.children = Widgets.line(childrenCard, "", 14, COLORS.dim)

	return self
end

function Panel:isOpen(): boolean
	return self.widget.Enabled
end

function Panel:render(state)
	local phase = PHASES[state.phase] or PHASES.waiting
	self.statusLabel.Text = phase[1]
	self.dot.BackgroundColor3 = phase[2]
	if phase[3] ~= "" and self.button.Icon ~= phase[3] then
		self.button.Icon = phase[3]
	end
	self.detail.Text = state.detail
	self.detail.Visible = state.detail ~= ""
	local server = state.server
	if server and type(server.port) == "table" then
		self.project.Text = `{server.hello.project} at {server.port.url}`
	elseif server then
		self.project.Text = `{server.hello.project}: Rojo {server.hello.rojoPort}, control {server.port}`
	else
		self.project.Text = "No server attached"
	end
	self.lastSync.Text = `Last sync {ago(state.lastSyncAt)}, {state.patches} updates`
	self.autoConnect = state.autoConnect
	self.autoButton.Text = if state.autoConnect then "Auto-connect: on" else "Auto-connect: off"
	self.confirmButton.Visible = state.phase == "confirm"
	self.livePlaytest = state.plugin == nil or state.plugin:GetSetting("TypeTorch_livePlaytest") ~= false
	self.liveButton.Text = if self.livePlaytest then "Live playtest: on" else "Live playtest: off"

	self:renderAssets(state)

	local remote = Control.remote
	self.remoteLine.Text = if remote
		then `Using {remote.url}`
		else "Working with someone else's typetorch serve? Enter their URL and the code from `typetorch serve pair`."
	self.remoteUrl.Visible = remote == nil
	self.remoteCode.Visible = remote == nil
	self.pairButton.Visible = remote == nil
	self.localButton.Visible = remote ~= nil
	self.remoteMessage.Text = state.remoteMessage or ""
	self.remoteMessage.Visible = self.remoteMessage.Text ~= ""

	local status = state.status
	if status and status.compile then
		local compile = status.compile
		local errors = compile.errors or {}
		if compile.state == "errors" then
			self.compile.Text = `{#errors} error{if #errors == 1 then "" else "s"}`
			self.compile.TextColor3 = COLORS.bad
		elseif compile.state == "ok" then
			self.compile.Text = "No errors"
			self.compile.TextColor3 = COLORS.good
		else
			self.compile.Text = if compile.state == "compiling" then "Compiling" else "Waiting for the first compile"
			self.compile.TextColor3 = COLORS.dim
		end
		for i, label in self.errors do
			local e = errors[i]
			label.Visible = e ~= nil
			if e then
				label.Text = `{e.file}:{e.line}  {e.message}`
			end
		end
		local lines = {}
		for _, child in status.children or {} do
			table.insert(lines, `{child.name}: {child.state}{if child.restarts > 0 then ` ({child.restarts} restarts)` else ""}`)
		end
		self.children.Text = if #lines > 0 then table.concat(lines, "\n") else "No processes"
	else
		self.compile.Text = if server then "Open this panel to load" else "Not connected"
		self.compile.TextColor3 = COLORS.dim
		for _, label in self.errors do
			label.Visible = false
		end
		self.children.Text = if server then "" else "Start it in the game folder: typetorch serve"
	end
end

function Panel:renderAssets(state)
	local assets = state.assets
	local lock = assets.lock
	local inLock = if lock and lock.assets then lock.assets else {}
	local lockCount = 0
	for _ in inLock do
		lockCount += 1
	end
	local problems = 0
	for _, entry in assets.marked do
		if #entry.problems > 0 then
			problems += 1
		end
	end
	if not assets.scanned then
		self.assetsSummary.Text = "Open this panel to scan the place"
	else
		self.assetsSummary.Text = `{#assets.marked} marked in this place, {lockCount} in the lockfile`
			.. if problems > 0 then `, {problems} with problems` else ""
	end
	self.assetsSummary.TextColor3 = if problems > 0 then COLORS.bad else COLORS.dim
	-- Problems first, then what Publish would send, then the rest. The last check (state.assets.changes) knows what
	-- changed; without one, a key the lockfile doesn't have is new.
	local changes = assets.changes or {}
	local rows = {}
	for _, entry in assets.marked do
		if #entry.problems > 0 then
			table.insert(rows, { `{entry.key}: {entry.problems[1]}`, COLORS.bad })
		end
	end
	local present = {}
	local later = {}
	for _, entry in assets.marked do
		present[entry.key] = true
		if #entry.problems == 0 then
			local status = changes[entry.key] or (if inLock[entry.key] then nil else "added")
			if status == "added" then
				table.insert(rows, { `{entry.key}  {entry.className}  new`, COLORS.warn })
			elseif status == "updated" then
				table.insert(rows, { `{entry.key}  {entry.className}  changed`, COLORS.warn })
			else
				table.insert(later, { `{entry.key}  {entry.className}  {if status == "unchanged" then "up to date" else "published"}`, COLORS.text })
			end
		end
	end
	for key in inLock do
		if not present[key] and assets.scanned then
			table.insert(rows, { `{key}  removed (Publish drops it)`, COLORS.dim })
		end
	end
	for _, row in later do
		table.insert(rows, row)
	end
	for i, label in self.assetLines do
		local row = rows[i]
		label.Visible = row ~= nil
		if row then
			label.Text = if i == MAX_ASSET_LINES and #rows > MAX_ASSET_LINES then `and {#rows - i + 1} more` else row[1]
			label.TextColor3 = row[2]
		end
	end
	self.deployButton.Text = `Publish to {if lock and lock.devBranch then lock.devBranch else "dev"}`
	self.assetsMessage.Text = assets.message
	self.assetsMessage.Visible = assets.message ~= ""
	self.jobLine.Text = assets.jobText
	self.jobLine.Visible = assets.jobText ~= ""
	self.jobLine.TextColor3 = if assets.job and assets.job.state == "failed" then COLORS.bad else COLORS.dim
end

return Panel
