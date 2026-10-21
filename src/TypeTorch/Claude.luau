--!nonstrict
-- The Claude window: prompts Claude Code on the machine that runs `typetorch serve --claude` (remote-claude from
-- @typetorch/dev-server), like the in-game DEV > Claude tab. Code mode: Claude edits the branch serve runs on, then a
-- Deploy / Discard proposal comes back. Requests go through serve's control API (`/tt/claude/...`), locally or through
-- a paired remote serve; serve pairs with remote-claude for this Studio's Roblox user, so there is no code to paste.

local Control = require(script.Parent.Control)
local Widgets = require(script.Parent.Widgets)
local COLORS = Widgets.COLORS
local make = Widgets.make

local Claude = {}
Claude.__index = Claude

local POLL_SECONDS = 0.7
local SLOW_POLL_SECONDS = 2
-- A prompt that is still going after this long is left to the transcript on the owner's side.
local MAX_POLL_SECONDS = 30 * 60
local MAX_LINES = 400
-- Must match FINISHED_STATES in dev-server src/prompts.ts.
local FINISHED = { deployed = true, discarded = true, answered = true, failed = true, cancelled = true }

local STATE_TEXT = {
	queued = "Waiting for Claude",
	running = "Claude is working",
	committed = "Changes committed",
	proposed = "Ready to deploy",
	building = "Deploying",
	deployed = "Deployed",
	discarded = "Discarded",
	answered = "Done",
	failed = "Failed",
	cancelled = "Stopped",
}

type Endpoint = Control.Endpoint

local function userId(): number
	local ok, id = pcall(function()
		return game:GetService("StudioService"):GetUserId()
	end)
	return if ok and type(id) == "number" then id else 0
end

-- `toolbar`: the TypeTorch toolbar (Panel). `endpoint()`: the serve this Studio is attached to, or nil.
function Claude.new(plugin: Plugin, toolbar: PluginToolbar, endpoint: () -> Endpoint?)
	local self = setmetatable({}, Claude)
	self.endpoint = endpoint
	self.conversationId = nil :: string?
	self.prompt = nil -- { id, since, state, blocks = { [block]: TextLabel } }
	self.lines = {} :: { Instance }
	self.busy = false

	local button = toolbar:CreateButton("TypeTorchClaude", "Prompt Claude Code on the typetorch serve machine", "", "Claude")
	button.ClickableWhenViewportHidden = true
	local widget = plugin:CreateDockWidgetPluginGuiAsync(
		"TypeTorchClaude",
		DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 360, 520, 280, 300)
	)
	widget.Title = "TypeTorch Claude"
	widget.Name = "TypeTorchClaude"
	self.widget = widget
	button.Click:Connect(function()
		widget.Enabled = not widget.Enabled
	end)
	widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		button:SetActive(widget.Enabled)
		if widget.Enabled then
			task.spawn(function()
				self:refreshStatus()
			end)
		end
	end)

	local background = make("Frame", { BackgroundColor3 = COLORS.window, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) }, widget)
	Widgets.pad(background, 10, 10)

	-- Top: the session line. Bottom: the prompt box and buttons. Between: the transcript.
	local top = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, background)
	Widgets.verticalList(top, 4)
	local title = Widgets.line(top, "Claude", 18, COLORS.text, Enum.Font.BuilderSansBold)
	title.TextWrapped = false
	self.statusDot, self.statusLabel = Widgets.statusLine(top)
	self.statusLabel.TextSize = 14
	self.statusLabel.Font = Enum.Font.BuilderSans

	local bottom = make("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, background)
	Widgets.verticalList(bottom, 6)
	self.proposalCard = Widgets.card(bottom)
	self.proposalLine = Widgets.line(self.proposalCard, "", 14, COLORS.text)
	local proposalButtons = Widgets.buttonRow(self.proposalCard)
	local deploy = Widgets.button(proposalButtons, "Deploy", function()
		self:decide("deploy")
	end, COLORS.accent)
	deploy.TextColor3 = COLORS.dark
	Widgets.button(proposalButtons, "Discard", function()
		self:decide("discard")
	end)
	self.proposalCard.Visible = false

	local box = Widgets.textBox(bottom, "Ask Claude to change the game, e.g. make the lobby door open on touch")
	box.MultiLine = true
	box.TextWrapped = true
	box.TextYAlignment = Enum.TextYAlignment.Top
	box.Font = Enum.Font.BuilderSans
	box.Size = UDim2.new(1, 0, 0, 72)
	local padding = box:FindFirstChildOfClass("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	self.box = box
	local buttons = Widgets.buttonRow(bottom)
	self.sendButton = Widgets.button(buttons, "Send", function()
		self:send(box.Text)
	end, COLORS.accent)
	self.sendButton.TextColor3 = COLORS.dark
	self.stopButton = Widgets.button(buttons, "Stop", function()
		self:cancel()
	end)
	self.stopButton.Visible = false
	Widgets.button(buttons, "New chat", function()
		self:newChat()
	end)

	local transcript = Widgets.scrolling(background)
	transcript.Position = UDim2.fromOffset(0, 52)
	self.transcript = transcript
	Widgets.verticalList(transcript, 6)
	local function fit()
		transcript.Size = UDim2.new(1, 0, 1, -(52 + bottom.AbsoluteSize.Y + 8))
	end
	bottom:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	fit()

	self:say("Claude Code runs on the machine with `typetorch serve --claude` and edits its dev branch. When it's done you choose Deploy or Discard.", COLORS.dim)
	return self
end

function Claude:setStatus(text: string, color: Color3)
	self.statusLabel.Text = text
	self.statusDot.BackgroundColor3 = color
end

-- One transcript entry; returns its label.
function Claude:say(text: string, color: Color3?, font: Enum.Font?): TextLabel
	local label = Widgets.line(self.transcript, text, 15, color or COLORS.text, font)
	label.RichText = false
	table.insert(self.lines, label)
	while #self.lines > MAX_LINES do
		local oldest = table.remove(self.lines, 1)
		if oldest then
			oldest:Destroy()
		end
	end
	task.defer(function()
		self.transcript.CanvasPosition = Vector2.new(0, math.max(0, self.transcript.AbsoluteCanvasSize.Y - self.transcript.AbsoluteWindowSize.Y))
	end)
	return label
end

function Claude:request(method: string, path: string, body: any?): (boolean, any)
	local endpoint = self.endpoint()
	if endpoint == nil then
		return false, "Not attached to typetorch serve yet (see the TypeTorch panel)"
	end
	return Control.request(endpoint, method, path, body)
end

function Claude:refreshStatus()
	if self.endpoint() == nil then
		self:setStatus("Waiting for typetorch serve", COLORS.dim)
		return
	end
	local ok, status = self:request("GET", "/tt/claude")
	if not ok then
		self:setStatus(if string.find(tostring(status), "no route") then "This typetorch serve is too old for Claude" else tostring(status), COLORS.bad)
	elseif status.available then
		self.branch = status.branch
		self:setStatus(`Ready, on {status.branch}`, COLORS.good)
	else
		self:setStatus(status.hint or "Claude isn't running", COLORS.warn)
	end
end

function Claude:setBusy(busy: boolean)
	self.busy = busy
	self.sendButton.Visible = not busy
	self.stopButton.Visible = busy
end

function Claude:send(text: string)
	text = string.gsub(text, "^%s+", "")
	text = string.gsub(text, "%s+$", "")
	if text == "" or self.busy then
		return
	end
	self:setBusy(true)
	self.proposalCard.Visible = false
	self:say(text, COLORS.accent, Enum.Font.BuilderSansMedium)
	local ok, started = self:request("POST", "/tt/claude/prompt", { prompt = text, conversationId = self.conversationId, user = userId() })
	if not ok then
		self:say(`Couldn't send: {started}`, COLORS.bad)
		self:setBusy(false)
		return
	end
	self.box.Text = ""
	self.conversationId = started.conversationId or self.conversationId
	local prompt = { id = started.id, since = 0, state = started.state, blocks = {} }
	self.prompt = prompt
	task.spawn(function()
		self:follow(prompt)
	end)
end

-- One event in the transcript. assistant_text chunks of one block go into one label.
function Claude:event(prompt, e)
	local kind = e.kind
	if kind == "assistant_text" then
		local label = e.block ~= nil and prompt.blocks[e.block]
		if label then
			label.Text ..= e.text
		else
			label = self:say(e.text, COLORS.text)
			if e.block ~= nil then
				prompt.blocks[e.block] = label
			end
		end
	elseif kind == "tool_use" then
		self:say(`{e.tool or "tool"}{if e.target then ` {e.target}` else ""}`, COLORS.dim, Enum.Font.RobotoMono)
	elseif kind == "error" then
		self:say(e.text, COLORS.bad)
	elseif kind == "status" and e.state and (e.state == "failed" or e.state == "deployed" or e.state == "discarded" or e.state == "cancelled") then
		self:say(STATE_TEXT[e.state] .. if e.text ~= "" and e.text ~= e.state then `: {e.text}` else "", if e.state == "failed" then COLORS.bad else COLORS.dim)
	elseif kind == "image" or kind == "toolbox_results" then
		self:say(`({kind == "image" and "Claude showed an image" or "Creator Store results"}: open the in-game tab to see it)`, COLORS.dim)
	end
end

function Claude:showProposal(view)
	local proposal = view.proposal
	if not proposal or proposal.status ~= "pending" then
		self.proposalCard.Visible = false
		return
	end
	local files = proposal.files or {}
	local names = {}
	for i, file in files do
		if i > 6 then
			table.insert(names, `and {#files - 6} more`)
			break
		end
		table.insert(names, file.path)
	end
	self.proposalLine.Text = `Deploy {string.sub(proposal.commit or "", 1, 7)} to {self.branch or "dev"}? {#files} file{if #files == 1 then "" else "s"}: {table.concat(names, ", ")}`
	self.proposalCard.Visible = true
end

-- Polls a prompt until it finishes (or the window moves on to another one).
function Claude:follow(prompt)
	local started = os.clock()
	while self.prompt == prompt and os.clock() - started < MAX_POLL_SECONDS do
		local ok, view = self:request("GET", `/tt/claude/prompt?id={prompt.id}&since={prompt.since}&user={userId()}`)
		if not ok then
			self:setStatus(`Lost Claude: {view}`, COLORS.bad)
			task.wait(SLOW_POLL_SECONDS)
		else
			for _, e in view.events or {} do
				self:event(prompt, e)
			end
			prompt.since = view.next or prompt.since
			prompt.state = view.state
			self:setStatus(STATE_TEXT[view.state] or view.state, if view.state == "failed" then COLORS.bad else COLORS.good)
			self:showProposal(view)
			local waitingForYou = view.proposal and view.proposal.status == "pending"
			if FINISHED[view.state] then
				break
			end
			-- Claude is done once the change is committed (or proposed): the box is free again.
			if self.busy and (view.state == "committed" or view.state == "proposed" or waitingForYou) then
				self:setBusy(false)
			end
			if not view.more then
				task.wait(if self.busy then POLL_SECONDS else SLOW_POLL_SECONDS)
			end
		end
	end
	if self.prompt == prompt then
		self:setBusy(false)
	end
end

function Claude:decide(decision: string)
	local prompt = self.prompt
	if not prompt then
		return
	end
	self.proposalCard.Visible = false
	local ok, err = self:request("POST", "/tt/claude/deploy", { id = prompt.id, decision = decision, user = userId() })
	if not ok then
		self:say(`Couldn't {decision}: {err}`, COLORS.bad)
		self.proposalCard.Visible = true
	end
end

function Claude:cancel()
	local prompt = self.prompt
	if not prompt then
		return
	end
	local ok, err = self:request("POST", "/tt/claude/cancel", { id = prompt.id, user = userId() })
	if not ok then
		self:say(`Couldn't stop: {err}`, COLORS.bad)
	end
end

function Claude:newChat()
	if self.busy then
		return
	end
	self.prompt = nil
	self.conversationId = nil
	self.proposalCard.Visible = false
	for _, label in self.lines do
		label:Destroy()
	end
	self.lines = {}
	self:say("New chat.", COLORS.dim)
end

return Claude
