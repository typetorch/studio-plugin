--!nonstrict
-- The plugin's dock widget: sync status, the matched server, the last compile result and the buttons. Same look as
-- the TypeTorch dev menu (Widgets.luau).

local Assets = require(script.Parent.Assets)
local Control = require(script.Parent.Control)
local Icons = require(script.Parent.Icons)
local Widgets = require(script.Parent.Widgets)
local COLORS = Widgets.COLORS
local make = Widgets.make

local Panel = {}
Panel.__index = Panel

-- The toolbar button's icon: assets/toolbar-icon.png (the TypeTorch logo) uploaded as a Roblox image. Empty shows
-- Studio's default icon until it is uploaded. A phase's own status icon (Icons.luau), once set, replaces it.
local TOOLBAR_ICON = ""

-- { label, dot color, toolbar icon }
local PHASES = {
	waiting = { "Waiting for typetorch serve", COLORS.dim, Icons.idle },
	confirm = { "Found a server for another place", COLORS.warn, Icons.connecting },
	connecting = { "Connecting", COLORS.warn, Icons.connecting },
	connected = { "Synced", COLORS.good, Icons.synced },
	disconnected = { "Disconnected", COLORS.bad, Icons.error },
	paused = { "Paused", COLORS.dim, Icons.idle },
	idle = { "Playtest", COLORS.dim, Icons.idle },
}

local MAX_ERRORS = 8
local MAX_ASSET_LINES = 12
local MAX_DIFF_LINES = 40

-- A diff line's tone (Assets.describeDiff) to its color.
local DIFF_TONES = { added = COLORS.good, removed = COLORS.bad, changed = COLORS.warn, text = COLORS.text, dim = COLORS.dim }

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
	local button = toolbar:CreateButton("TypeTorchSync", "TypeTorch sync status", if Icons.idle ~= "" then Icons.idle else TOOLBAR_ICON, "TypeTorch")
	button.ClickableWhenViewportHidden = true
	self.button = button
	local widget = Widgets.dock(plugin, "TypeTorchSync", 320, 420, 260, 240, true)
	widget.Title = "TypeTorch"
	widget.Name = "TypeTorchSync"
	self.widget = widget
	button.Click:Connect(function()
		widget.Enabled = not widget.Enabled
	end)
	widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		button:SetActive(widget.Enabled)
	end)
	Widgets.keepOpen(plugin, widget)
	button:SetActive(widget.Enabled)

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
	self.statusButtons = buttons
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

	-- Server card: which serve this Studio uses (this computer's, or a `serve --remote` behind the owner's tunnel). The
	-- link box is always there: pasting a new link switches servers from either side.
	local remoteCard = Widgets.card(scroll)
	self.remoteCard = remoteCard
	Widgets.line(remoteCard, "Server", 15, COLORS.text, Enum.Font.BuilderSansBold)
	self.remoteLine = Widgets.line(remoteCard, "", 14, COLORS.text)
	self.remoteLink = Widgets.textBox(remoteCard, "")
	local function pair()
		local link = self.remoteLink.Text
		if Control.trimUrl(link) == "" then
			self.remoteLink:CaptureFocus()
			return
		end
		actions.pairRemote(link)
	end
	self.remoteLink.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			pair()
		end
	end)
	local remoteButtons = Widgets.buttonRow(remoteCard)
	self.pairButton = Widgets.button(remoteButtons, "Pair", pair)
	self.localButton = Widgets.button(remoteButtons, "Use this computer's serve", function()
		actions.forgetRemote()
	end)
	self.remoteHint = Widgets.line(remoteCard, "", 14, COLORS.dim)
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
	self.assetsCard = assetsCard
	Widgets.line(assetsCard, "Hot assets", 15, COLORS.text, Enum.Font.BuilderSansBold)
	self.assetsSummary = Widgets.line(assetsCard, "", 14, COLORS.dim)
	-- One row per hot asset: its line, and a Diff button when the last check sent what changed in it (cli 0.12.2+).
	-- The button opens the diff view under the rows for that key (again to close).
	self.assetRows = {}
	self.rowKeys = {}
	self.diffKey = nil
	for i = 1, MAX_ASSET_LINES do
		local row = Widgets.inlineRow(assetsCard)
		row.Visible = false
		local label = Widgets.line(row, "", 14, COLORS.text, Enum.Font.RobotoMono)
		local button = Widgets.smallButton(row, "Diff", function()
			local key = self.rowKeys[i]
			self.diffKey = if self.diffKey == key then nil else key
			if self.lastState then
				self:renderAssets(self.lastState)
			end
		end)
		self.assetRows[i] = { row = row, label = label, button = button }
	end
	local diffPanel = Widgets.subPanel(assetsCard)
	diffPanel.Visible = false
	self.diffPanel = diffPanel
	self.diffTitle = Widgets.line(diffPanel, "", 14, COLORS.text, Enum.Font.BuilderSansBold)
	self.diffLines = {}
	for i = 1, MAX_DIFF_LINES do
		local label = Widgets.line(diffPanel, "", 14, COLORS.text, Enum.Font.RobotoMono)
		label.Visible = false
		self.diffLines[i] = label
	end
	-- Add and Remove follow the Explorer selection; Check, Upload and Publish show only when they have work.
	self.selectionHint = Widgets.line(assetsCard, "Select a model or UI in the Explorer to add it", 14, COLORS.dim)
	self.keyBox = Widgets.textBox(assetsCard, "name (optional, from the selection)")
	self.keyBox:GetPropertyChangedSignal("Text"):Connect(function()
		if self.lastState then
			self:renderAssets(self.lastState)
		end
	end)
	self.markButtons = Widgets.buttonRow(assetsCard)
	self.addButton = Widgets.button(self.markButtons, "Add", function()
		actions.addSelection(self.keyBox.Text)
	end)
	self.removeButton = Widgets.button(self.markButtons, "Remove", function()
		actions.removeSelection()
	end)
	self.syncButtons = Widgets.buttonRow(assetsCard)
	self.checkButton = Widgets.button(self.syncButtons, "Check", function()
		actions.runJob("assets-status")
	end)
	self.uploadButton = Widgets.button(self.syncButtons, "Upload", function()
		actions.runJob("assets-sync")
	end)
	self.deployButton = Widgets.button(self.syncButtons, "Publish to dev", function()
		actions.runJob("assets-deploy-dev")
	end, COLORS.accent)
	self.deployButton.TextColor3 = COLORS.dark
	self.checkedLine = Widgets.line(assetsCard, "", 14, COLORS.dim)
	self.assetsMessage = Widgets.line(assetsCard, "", 14, COLORS.dim)
	self.jobLine = Widgets.line(assetsCard, "", 14, COLORS.dim)
	game:GetService("Selection").SelectionChanged:Connect(function()
		local selected = game:GetService("Selection"):Get()
		local current = if #selected == 1 then selected[1]:GetAttribute("TypeTorchAsset") else nil
		self.keyBox.Text = if type(current) == "string" then current else ""
		if self.lastState then
			self:renderAssets(self.lastState)
		end
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
	elseif state.lostAt and state.lostProject then
		self.project.Text = `Was syncing {state.lostProject}`
	else
		self.project.Text = "No server attached"
	end
	self.lastSync.Text = if state.lostAt
		then `Connection lost {ago(state.lostAt)}, last sync {ago(state.lastSyncAt)}`
		else `Last sync {ago(state.lastSyncAt)}, {state.patches} updates`
	self.lastSync.TextColor3 = if state.lostAt then COLORS.bad else COLORS.dim
	self.autoConnect = state.autoConnect
	self.autoButton.Text = if state.autoConnect then "Auto-connect: on" else "Auto-connect: off"
	self.confirmButton.Visible = state.phase == "confirm"
	self.livePlaytest = state.plugin == nil or state.plugin:GetSetting("TypeTorch_livePlaytest") ~= false
	self.liveButton.Text = if self.livePlaytest then "Live playtest: on" else "Live playtest: off"

	-- A playtest's panel: status, playtest and compile only (pairing and hot assets act on the edit session).
	local editing = state.mode == "edit"
	self.statusButtons.Visible = editing
	self.remoteCard.Visible = editing
	self.assetsCard.Visible = editing
	if editing then
		self:renderAssets(state)
	end

	local remote = Control.remote
	self.remoteLine.Text = if remote then `Remote: {remote.url}` else "This computer's typetorch serve"
	self.remoteLink.PlaceholderText = if remote
		then "new pairing link, to switch servers"
		else "pairing link, e.g. https://serve.example.com#code"
	self.remoteHint.Text = if remote
		then "Paste a new link from `typetorch serve pair --url` to switch, or go back to this computer's serve."
		else "To use someone else's serve, paste the link from `typetorch serve pair --url`."
	self.localButton.Visible = remote ~= nil
	-- A pairing code works once: empty the box when the server switches (kept after a failed pair, to fix it).
	local remoteUrl = if remote then remote.url else ""
	if self.shownRemote ~= nil and self.shownRemote ~= remoteUrl then
		self.remoteLink.Text = ""
	end
	self.shownRemote = remoteUrl
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
	self.lastState = state
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
	local diffs = assets.diffs or {}
	-- { text, color, key (a row with a Diff button when the last check sent that key's diff), status }
	local rows = {}
	for _, entry in assets.marked do
		if #entry.problems > 0 then
			table.insert(rows, { `{entry.key}: {entry.problems[1]}`, COLORS.bad })
		end
	end
	local present = {}
	local later = {}
	local pending = 0
	for _, entry in assets.marked do
		present[entry.key] = true
		if #entry.problems == 0 then
			local status = changes[entry.key] or (if inLock[entry.key] then nil else "added")
			if status == "added" then
				pending += 1
				table.insert(rows, { `{entry.key}  {entry.className}  new`, COLORS.warn, entry.key, status })
			elseif status == "updated" then
				pending += 1
				table.insert(rows, { `{entry.key}  {entry.className}  changed`, COLORS.warn, entry.key, status })
			else
				table.insert(later, { `{entry.key}  {entry.className}  {if status == "unchanged" then "up to date" else "published"}`, COLORS.text })
			end
		end
	end
	for key in inLock do
		if not present[key] and assets.scanned then
			pending += 1
			table.insert(rows, { `{key}  removed (Publish drops it)`, COLORS.dim, key, "removed" })
		end
	end
	for _, row in later do
		table.insert(rows, row)
	end
	local shown = nil
	for i, parts in self.assetRows do
		local row = rows[i]
		local overflow = i == MAX_ASSET_LINES and #rows > MAX_ASSET_LINES
		parts.row.Visible = row ~= nil
		local key = if row and not overflow and diffs[row[3]] then row[3] else nil
		self.rowKeys[i] = key
		if row then
			parts.label.Text = if overflow then `and {#rows - i + 1} more` else row[1]
			parts.label.TextColor3 = row[2]
			parts.button.Visible = key ~= nil
			parts.label.Size = if key then UDim2.new(1, -Widgets.SMALL_BUTTON_WIDTH - 8, 0, 0) else UDim2.new(1, 0, 0, 0)
			parts.button.BackgroundColor3 = if key == self.diffKey then COLORS.stroke else COLORS.button
			if key and key == self.diffKey then
				shown = { key = key, status = row[4] }
			end
		end
	end
	-- The diff view: the open key's lines (Assets.describeDiff), while that key still has a diff.
	self.diffPanel.Visible = shown ~= nil
	if shown then
		self.diffTitle.Text = `{shown.key}: {if shown.status == "added" then "new" elseif shown.status == "removed" then "removed" else "what changed"}`
		local lines = Assets.describeDiff(diffs[shown.key], shown.status)
		for i, label in self.diffLines do
			local line = lines[i]
			local overflow = i == MAX_DIFF_LINES and #lines > MAX_DIFF_LINES
			label.Visible = line ~= nil
			if line then
				label.Text = if overflow then `and {#lines - i + 1} more lines` else line.text
				label.TextColor3 = if overflow then COLORS.dim else DIFF_TONES[line.tone] or COLORS.text
			end
		end
	else
		self.diffKey = nil
	end
	-- Add: something selected that isn't a hot asset yet, or one hot asset to rename from the name box. Remove: a
	-- selected hot asset.
	local selected = game:GetService("Selection"):Get()
	local unmarked, marked = 0, 0
	for _, instance in selected do
		if instance.Parent ~= game then
			if instance:GetAttribute(Assets.ATTRIBUTE) ~= nil then
				marked += 1
			else
				unmarked += 1
			end
		end
	end
	local single = if #selected == 1 and unmarked + marked == 1 then selected[1] else nil
	local renaming = single ~= nil
		and marked == 1
		and self.keyBox.Text ~= ""
		and self.keyBox.Text ~= single:GetAttribute(Assets.ATTRIBUTE)
	self.selectionHint.Visible = unmarked + marked == 0
	self.keyBox.Visible = single ~= nil
	self.addButton.Visible = unmarked > 0 or renaming
	self.addButton.Text = if renaming then "Rename" else "Add"
	self.removeButton.Visible = marked > 0
	self.markButtons.Visible = self.addButton.Visible or self.removeButton.Visible
	-- Check: there are hot assets and serve is attached. Upload and Publish: the last check, or the lockfile, says
	-- something would change and nothing has a problem. All hidden while a job runs.
	local idle = state.server ~= nil and not (assets.job and assets.job.state == "running")
	self.checkButton.Visible = idle and (#assets.marked > 0 or lockCount > 0)
	self.uploadButton.Visible = idle and pending > 0 and problems == 0
	self.deployButton.Visible = self.uploadButton.Visible
	self.syncButtons.Visible = self.checkButton.Visible or self.deployButton.Visible
	self.deployButton.Text = `Publish to {if lock and lock.devBranch then lock.devBranch else "dev"}`
	-- When the last check ran (a button, or the automatic one every 30 s while this panel is open and serve attached).
	self.checkedLine.Visible = assets.checkedAt ~= nil
	if assets.checkedAt then
		self.checkedLine.Text = `Checked {ago(assets.checkedAt)}{if idle and #assets.marked > 0 then ", checks again every 30 s" else ""}`
	end
	self.assetsMessage.Text = assets.message
	self.assetsMessage.Visible = assets.message ~= ""
	self.jobLine.Text = assets.jobText
	self.jobLine.Visible = assets.jobText ~= ""
	self.jobLine.TextColor3 = if assets.job and assets.job.state == "failed" then COLORS.bad else COLORS.dim
end

return Panel
