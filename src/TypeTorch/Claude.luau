--!nonstrict
-- The Claude window: prompts Claude Code on the machine that runs `typetorch serve --claude` (remote-claude from
-- @typetorch/dev-server). A port of the in-game DEV > Claude tab (framework src/devtools/claude-ui.ts), Code mode only:
-- the same status line, bubbles, Markdown, tool lines, working dots, scroll-to-bottom button, composer and deploy card.
-- Studio has no screenshots, images, Toolbox grid or Live mode, so those are left out. Requests go through serve's
-- control API (`/tt/claude/...`), locally or through a paired remote serve. The running prompt's events come over
-- serve's WebSocket stream (`/tt/claude/stream`) as they happen, also in the Play client (which can't make HTTP
-- requests but can open the stream); HTTP polling stands in while there is no stream.

local HttpService = game:GetService("HttpService")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Control = require(script.Parent.Control)
local Widgets = require(script.Parent.Widgets)
local COLORS = Widgets.COLORS
local make = Widgets.make
local corner = Widgets.corner
local pad = Widgets.pad
local style = Widgets.style

local Claude = {}
Claude.__index = Claude

local FONT = Enum.Font.Code
local TEXT_SIZE = 15
local SMALL = 14
local LINE = 18
local MAX_LINES = 5
local ROUND = 32
local MAX_PROMPT = 4000
local BUBBLE_SHARE = 0.8
local BUBBLE_BG = COLORS.header
local CODE_BG = Color3.fromRGB(13, 14, 18)
local CODE_TEXT = Color3.fromRGB(205, 210, 222)
local DIMMER = Color3.fromRGB(118, 124, 138)
local RESULT_DIM = Color3.fromRGB(88, 94, 106)
local POLL_ACTIVE = 0.25
-- Waits before opening the stream again after it failed (seconds, by failures in a row).
local STREAM_RETRY = { 1, 2, 5, 10, 20 }
-- While streaming: one HTTP check after this long without a push (the stream itself may have stalled).
local STREAM_QUIET = 5
local POLL_IDLE = 2
local STATUS_REFRESH = 10
-- Must match FINISHED_STATES in dev-server src/prompts.ts.
local FINISHED = { deployed = true, discarded = true, answered = true, failed = true, cancelled = true }

-- Short text for error codes (claude-ui.ts ERRORS); serve's own messages pass through.
local ERRORS = {
	not_connected = "Not connected: start the dev server on this branch",
	needs_pairing = "Pair first",
	bad_code = "Wrong, used or expired code",
	already_decided = "Already decided",
	not_allowed = "Not on the session's user list",
	busy = "Wait for the running prompt",
	rate_limited = "Too many tries, wait a bit",
	empty = "Write a message first",
	too_long = "Message too long",
	unreachable = "Can't reach the dev machine",
	unauthorized = "Rejected by the dev machine",
	forbidden = "Rejected by the dev machine",
	remote_rate_limited = "Dev machine busy, try again",
	not_yours = "Only the requester can stop it",
	not_found = "Not found on the dev machine",
	conversation_gone = "That chat is gone (the dev machine restarted)",
	api_billing_refused = "Refused: Claude Code must use a subscription login",
	cancelled = "Stopped",
	["claude timed out"] = "Claude timed out",
}

local function errorText(code: any): string
	if type(code) == "string" then
		return ERRORS[code] or code
	end
	return "Failed"
end

-- serve answers a remote-claude 404 with this text (cli src/serve/claude.ts STATUS_TEXT).
local function isNotFound(err: any): boolean
	return type(err) == "string" and (err == "not_found" or string.sub(err, 1, 9) == "not found")
end

local function userId(): number
	local ok, id = pcall(function()
		return game:GetService("StudioService"):GetUserId()
	end)
	return if ok and type(id) == "number" then id else 0
end

local function trim(text: string): string
	return (string.gsub(string.gsub(text, "^%s+", ""), "%s+$", ""))
end

local function escapeRich(text: string): string
	text = string.gsub(text, "&", "&amp;")
	text = string.gsub(text, "<", "&lt;")
	return (string.gsub(text, ">", "&gt;"))
end

local function hex(color: Color3): string
	return "#" .. color:ToHex()
end

-- Pop in/out through a UIScale (never a Size tween), like framework src/ui popIn/popOut.
local function scaleOf(gui: GuiObject): UIScale
	return gui:FindFirstChildOfClass("UIScale") or make("UIScale", {}, gui)
end

local function popIn(gui: GuiObject)
	local scale = scaleOf(gui)
	scale.Scale = 0.6
	gui.Visible = true
	TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function popOut(gui: GuiObject)
	local scale = scaleOf(gui)
	local tween = TweenService:Create(scale, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Scale = 0.6 })
	tween.Completed:Once(function(state)
		if state ~= Enum.PlaybackState.Completed then
			return
		end
		gui.Visible = false
		scale.Scale = 1
	end)
	tween:Play()
end

-- A chevron drawn from two rotated Frames (widgets.ts chevron), filling `parent`.
local function chevron(parent: Instance, direction: string, color: Color3, thickness: number): Frame
	local holder = make("Frame", { Name = "Chevron", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, parent)
	for _, side in { -1, 1 } do
		local arm = make("Frame", {
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5 + side * 0.09, 0, 0.5, 0),
			Size = UDim2.new(0.3, 0, 0, thickness),
			Rotation = if direction == "up" then side * 45 else -side * 45,
		}, holder)
		corner(arm, 2)
	end
	return holder
end

local function label(text: string, color: Color3, size: number?, rich: boolean?): TextLabel
	local result = style(make("TextLabel", { BackgroundTransparency = 1, RichText = rich ~= false }), text, size or TEXT_SIZE, color, FONT)
	result.Size = UDim2.fromScale(1, 0)
	result.AutomaticSize = Enum.AutomaticSize.Y
	result.TextWrapped = true
	return result
end

local function roundButton(parent: Instance, color: Color3): TextButton
	local button = make("TextButton", {
		AutoButtonColor = true,
		Text = "",
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(ROUND, ROUND),
	}, parent)
	corner(button, ROUND / 2)
	return button
end

local function stroke(parent: Instance, color: Color3)
	make("UIStroke", { Color = color, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, parent)
end

local function list(parent: Instance, gap: number)
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, gap) }, parent)
end

local function autoFrame(parent: Instance?, order: number?): Frame
	return make("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order or 0,
	}, parent)
end

-- Markdown ---------------------------------------------------------------------------------------------------------

-- A GFM table as monospace text: columns padded to the widest cell, a rule under the header.
local function tableText(rows: { string }): string
	local cells = {}
	for _, row in rows do
		local inner = string.gsub(string.gsub(row, "^%s*|", ""), "|%s*$", "")
		if not string.match(inner, "^[%s%-:|]+$") then
			local parts = {}
			for _, cell in string.split(inner, "|") do
				cell = string.match(cell, "^%s*(.-)%s*$")
				cell = string.gsub(string.gsub(cell, "%*%*", ""), "`", "")
				table.insert(parts, cell)
			end
			table.insert(cells, parts)
		end
	end
	local function width(cell: string): number
		return utf8.len(cell) or #cell
	end
	local widths = {}
	for _, row in cells do
		for index, cell in row do
			widths[index] = math.max(widths[index] or 0, width(cell))
		end
	end
	local lines = {}
	for rowIndex, row in cells do
		local padded = {}
		for index, cell in row do
			table.insert(padded, cell .. string.rep(" ", (widths[index] or 0) - width(cell)))
		end
		table.insert(lines, table.concat(padded, "  "))
		if rowIndex == 1 then
			local rules = {}
			for _, w in widths do
				table.insert(rules, string.rep("-", w))
			end
			table.insert(lines, table.concat(rules, "  "))
		end
	end
	return table.concat(lines, "\n")
end

-- Splits Markdown into blocks: paragraphs (p), headings (h), list items (li), fenced code, rules.
local function parseMarkdown(text: string)
	local blocks = {}
	local paragraph = {}
	local code: { string }? = nil
	local tableRows: { string }? = nil
	local function flush()
		if #paragraph > 0 then
			table.insert(blocks, { kind = "p", text = table.concat(paragraph, "\n") })
		end
		paragraph = {}
	end
	local function flushTable()
		if tableRows then
			table.insert(blocks, { kind = "code", text = tableText(tableRows) })
		end
		tableRows = nil
	end
	for _, raw in string.split(text, "\n") do
		local line = string.gsub(raw, "\r$", "")
		local fence = string.match(line, "^%s*```") ~= nil
		if code == nil and string.match(line, "^%s*|.*|%s*$") then
			flush()
			tableRows = tableRows or {}
			table.insert(tableRows, line)
			continue
		end
		flushTable()
		if code ~= nil then
			if fence then
				table.insert(blocks, { kind = "code", text = table.concat(code, "\n") })
				code = nil
			else
				table.insert(code, line)
			end
			continue
		end
		if fence then
			flush()
			code = {}
			continue
		end
		if string.match(line, "^%s*$") then
			flush()
			continue
		end
		if string.match(line, "^%s*[%-%*_][%-%*_][%-%*_]+%s*$") then
			flush()
			table.insert(blocks, { kind = "rule" })
			continue
		end
		local hashes, heading = string.match(line, "^(#+)%s+(.+)$")
		if hashes and heading then
			flush()
			table.insert(blocks, { kind = "h", text = heading, level = #hashes })
			continue
		end
		local indent, bulletText = string.match(line, "^(%s*)[%-%*%+]%s+(.*)$")
		if indent and bulletText then
			flush()
			table.insert(blocks, { kind = "li", text = bulletText, marker = "•", indent = math.min(math.floor(#indent / 2), 4) })
			continue
		end
		local numberIndent, digits, item = string.match(line, "^(%s*)(%d+)[%.%)]%s+(.*)$")
		if numberIndent and digits and item then
			flush()
			table.insert(blocks, { kind = "li", text = item, marker = `{digits}.`, indent = math.min(math.floor(#numberIndent / 2), 4) })
			continue
		end
		table.insert(paragraph, line)
	end
	flushTable()
	flush()
	-- Still streaming: an open fence shows as a code block already.
	if code ~= nil then
		table.insert(blocks, { kind = "code", text = table.concat(code, "\n") })
	end
	return blocks
end

-- Inline Markdown -> RichText: escapes &, < and > first, then `code`, links, **bold** and *italic*.
local function inline(text: string): string
	local parts = string.split(text, "`")
	local out = {}
	for index, part in parts do
		local safe = escapeRich(part)
		if index % 2 == 0 and index < #parts then
			table.insert(out, `<font color="{hex(COLORS.info)}"><mark color="{hex(CODE_BG)}" transparency="0.2">{safe}</mark></font>`)
			continue
		end
		if index % 2 == 0 then
			table.insert(out, "`")
		end
		local formatted = string.gsub(safe, "(https?://[^%s<%)]+)", `<font color="{hex(COLORS.info)}">%1</font>`)
		formatted = string.gsub(formatted, "%[([^%]]-)%]%(([^%)]-)%)", `<font color="{hex(COLORS.info)}"><u>%1</u></font>`)
		formatted = string.gsub(formatted, "%*%*(.-)%*%*", "<b>%1</b>")
		formatted = string.gsub(formatted, "%*([^%*%s][^%*]-)%*", "<i>%1</i>")
		table.insert(out, formatted)
	end
	return table.concat(out)
end

local function blockKey(block): string
	if block.kind == "li" then
		return `li:{block.indent}`
	elseif block.kind == "h" then
		return `h:{math.min(block.level, 3)}`
	end
	return block.kind
end

local function createBlock(block)
	if block.kind == "code" then
		local box = make("Frame", { BackgroundColor3 = CODE_BG, BorderSizePixel = 0, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y })
		corner(box, 8)
		pad(box, 8, 10)
		-- A read-only TextBox: code can be selected and copied.
		local text = style(make("TextBox", { BackgroundTransparency = 1, ClearTextOnFocus = false, TextEditable = false, MultiLine = true }, box), "", SMALL, CODE_TEXT, FONT)
		text.TextWrapped = true
		text.TextYAlignment = Enum.TextYAlignment.Top
		text.Size = UDim2.fromScale(1, 0)
		text.AutomaticSize = Enum.AutomaticSize.Y
		return { key = blockKey(block), gui = box, text = text }
	elseif block.kind == "rule" then
		local line = make("Frame", { BackgroundColor3 = COLORS.stroke, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1) })
		return { key = "rule", gui = line, text = label("", COLORS.text) }
	elseif block.kind == "li" then
		-- A marker column and a hanging indent: wrapped lines line up under the text, not under the marker.
		local left = block.indent * 16
		local row = autoFrame(nil)
		local marker = style(make("TextLabel", { BackgroundTransparency = 1 }, row), "", TEXT_SIZE, COLORS.dim, FONT)
		marker.TextWrapped = false
		marker.TextXAlignment = Enum.TextXAlignment.Right
		marker.Position = UDim2.fromOffset(left, 0)
		marker.Size = UDim2.fromOffset(22, LINE)
		local text = label("", COLORS.text)
		text.Position = UDim2.fromOffset(left + 28, 0)
		text.Size = UDim2.new(1, -(left + 28), 0, 0)
		text.Parent = row
		return { key = blockKey(block), gui = row, text = text, marker = marker }
	end
	local text = label("", COLORS.text)
	return { key = blockKey(block), gui = text, text = text }
end

local function blockText(block): string
	if block.kind == "h" then
		local size = if block.level <= 1 then 19 elseif block.level == 2 then 17 else 16
		return `<font size="{size}"><b>{inline(block.text)}</b></font>`
	elseif block.kind == "code" then
		return block.text
	elseif block.kind == "rule" then
		return ""
	end
	return inline(block.text)
end

-- Brings `rendered` (the GUI of a text segment) in line with `blocks`, reusing every block whose kind is unchanged.
local function syncBlocks(holder: Frame, rendered, blocks)
	for index, block in blocks do
		local current = rendered[index]
		if current and current.key ~= blockKey(block) then
			for rest = #rendered, index, -1 do
				rendered[rest].gui:Destroy()
				table.remove(rendered, rest)
			end
			current = nil
		end
		if not current then
			current = createBlock(block)
			current.gui.LayoutOrder = index
			current.gui.Parent = holder
			table.insert(rendered, current)
		end
		local text = blockText(block)
		if current.text.Text ~= text then
			current.text.Text = text
		end
		if current.marker and block.kind == "li" and current.marker.Text ~= block.marker then
			current.marker.Text = block.marker
		end
	end
	for rest = #rendered, #blocks + 1, -1 do
		rendered[rest].gui:Destroy()
		table.remove(rendered, rest)
	end
end

-- "run_luau" from "mcp__typetorch-game__run_luau".
local function shortTool(tool: string?): string
	if tool == nil then
		return ""
	end
	return string.match(tool, "^mcp__.-__(.+)$") or tool
end

-- "Read src/foo.ts", "Edited ...", "Ran bun run build".
local function toolLine(event): string
	local target = event.target or ""
	local tool = shortTool(event.tool)
	if tool == "Read" then
		return `Read {target}`
	elseif tool == "Edit" then
		return `Edited {target}`
	elseif tool == "Write" then
		return `Wrote {target}`
	elseif tool == "Glob" or tool == "Grep" then
		return `Searched {target}`
	elseif tool == "Bash" then
		return `Ran {target}`
	elseif tool == "run_luau" then
		return "Ran luau on server"
	elseif tool == "game_logs" then
		return if target == "client" then "Read client logs" else "Read server logs"
	elseif tool == "inspect" then
		return `Inspected {target}`
	elseif tool == "find" then
		return "Searched the game"
	elseif tool == "game_status" then
		return "Checked server status"
	end
	return if tool ~= "" then tool else (event.text or "")
end

-- The chat (its conversation and prompt ids) is kept on serve (`/tt/claude/chat`), so every DataModel shows the same
-- one: the Play copy picks it up, and Edit after Stop. Plugin settings can't: a playtest's copy doesn't see Edit's.
local KEEP_MESSAGES = 100
local CATCH_UP_PAGES = 50
local CHAT_CHECK = 2

-- The window ---------------------------------------------------------------------------------------------------------

-- `toolbar`: the TypeTorch toolbar (Panel). `endpoint()`: the serve this Studio is attached to, or nil.
function Claude.new(plugin: Plugin, toolbar: PluginToolbar, endpoint: () -> Control.Endpoint?)
	local self = setmetatable({}, Claude)
	self.endpoint = endpoint
	self.chatKey = "" -- conversation and prompt ids of the chat shown, to spot another copy's change
	self.promptTexts = {} :: { [string]: string } -- prompts this copy sent, if serve lacks their text
	self.lastChatCheck = -math.huge
	self.saving = 0
	self.conversationId = nil :: string?
	self.messages = {}
	self.bubbles = {}
	self.active = nil
	self.view = 0
	self.order = 0
	self.sending = false
	self.failures = 0
	self.lastStatus = -math.huge
	self.stream = nil
	self.streamFailures = 0
	self.streamRetryAt = -math.huge
	self.lastPush = -math.huge

	local button = toolbar:CreateButton("TypeTorchClaude", "Prompt Claude Code on the typetorch serve machine", "", "Claude")
	button.ClickableWhenViewportHidden = true
	local widget = Widgets.dock(plugin, "TypeTorchClaude", 360, 520, 280, 300)
	widget.Title = "TypeTorch Claude"
	widget.Name = "TypeTorchClaude"
	self.widget = widget
	button.Click:Connect(function()
		widget.Enabled = not widget.Enabled
	end)
	widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		button:SetActive(widget.Enabled)
		if widget.Enabled then
			self.lastStatus = -math.huge
		end
	end)
	Widgets.keepOpen(plugin, widget)
	button:SetActive(widget.Enabled)

	local host = make("Frame", { BackgroundColor3 = COLORS.window, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) }, widget)
	list(host, 0)

	-- Top: status line, New chat.
	local top = autoFrame(host, 1)
	pad(top, 6, 10)
	list(top, 6)
	local statusRow = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, ROUND), LayoutOrder = 1 }, top)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
	}, statusRow)
	local status = style(make("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromOffset(150, ROUND), LayoutOrder = 1 }, statusRow), "Checking...", SMALL, COLORS.dim, FONT)
	status.TextWrapped = false
	status.TextTruncate = Enum.TextTruncate.AtEnd
	make("UIFlexItem", { FlexMode = Enum.UIFlexMode.Fill }, status)
	self.status = status
	local newButton = style(make("TextButton", { AutoButtonColor = true, LayoutOrder = 2 }), "New chat", SMALL, COLORS.text, Enum.Font.BuilderSansMedium)
	newButton.TextXAlignment = Enum.TextXAlignment.Center
	newButton.TextWrapped = false
	newButton.BackgroundColor3 = COLORS.button
	newButton.Size = UDim2.fromOffset(0, ROUND)
	newButton.AutomaticSize = Enum.AutomaticSize.X
	corner(newButton, 8)
	pad(newButton, 0, 10)
	newButton.Parent = statusRow
	newButton.Activated:Connect(function()
		self:newChat()
	end)

	-- Middle: messages.
	local middle = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), LayoutOrder = 2, ZIndex = 2 }, host)
	make("UIFlexItem", { FlexMode = Enum.UIFlexMode.Fill }, middle)
	local scroller = make("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = COLORS.dim,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
	}, middle)
	self.scroller = scroller
	-- Padding lives on a plain inner Frame (a UIPadding on a ScrollingFrame doesn't inset scale-width children).
	local messages = make("Frame", { Name = "Messages", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y }, scroller)
	make("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 12), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 14) }, messages)
	list(messages, 14)
	self.list = messages
	local emptyHint = label("Ask Claude about this game", DIMMER, SMALL, false)
	emptyHint.TextXAlignment = Enum.TextXAlignment.Center
	emptyHint.LayoutOrder = -1
	emptyHint.Parent = messages
	self.emptyHint = emptyHint
	messages:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		for _, bubble in self.bubbles do
			self:fitBubble(bubble)
		end
	end)

	local downButton = roundButton(middle, COLORS.button)
	downButton.AnchorPoint = Vector2.new(0.5, 1)
	downButton.Position = UDim2.new(0.5, 0, 1, -8)
	downButton.ZIndex = 5
	downButton.Visible = false
	stroke(downButton, COLORS.stroke)
	local downIcon = make("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(18, 18), ZIndex = 5 }, downButton)
	chevron(downIcon, "down", COLORS.text, 2)

	-- Stick to the bottom while output streams, unless the dev scrolled up; the round button scrolls back down.
	self.follow = true
	local downShown = false
	local function bottom()
		return math.max(0, scroller.AbsoluteCanvasSize.Y - scroller.AbsoluteWindowSize.Y)
	end
	local function setDownVisible(visible: boolean)
		if visible == downShown then
			return
		end
		downShown = visible
		if visible then
			popIn(downButton)
		else
			popOut(downButton)
		end
	end
	self.scrollToEnd = function()
		self.follow = true
		scroller.CanvasPosition = Vector2.new(0, bottom())
	end
	scroller:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		self.follow = scroller.CanvasPosition.Y >= bottom() - 24
		setDownVisible(not self.follow)
	end)
	local function onResize()
		if self.follow then
			self.scrollToEnd()
		else
			setDownVisible(true)
		end
	end
	scroller:GetPropertyChangedSignal("AbsoluteCanvasSize"):Connect(onResize)
	scroller:GetPropertyChangedSignal("AbsoluteWindowSize"):Connect(onResize)
	downButton.Activated:Connect(self.scrollToEnd)

	-- Bottom: the composer.
	local composerArea = autoFrame(host, 3)
	make("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, composerArea)
	list(composerArea, 4)
	local notice = label("", COLORS.dim, SMALL, false)
	notice.LayoutOrder = 1
	notice.Visible = false
	notice.Parent = composerArea
	self.notice = notice

	local composer = make("Frame", { BackgroundColor3 = COLORS.row, BorderSizePixel = 0, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2 }, composerArea)
	corner(composer, 14)
	stroke(composer, COLORS.stroke)
	pad(composer, 8, 10)
	list(composer, 6)

	-- The message box grows from 1 to 5 lines, then scrolls (its height follows TextBounds; the canvas is automatic).
	local inputScroll = make("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, LINE + 4),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = COLORS.dim,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		LayoutOrder = 2,
	}, composer)
	local box = style(make("TextBox", { ClearTextOnFocus = false, MultiLine = true }, inputScroll), "", TEXT_SIZE, COLORS.text, FONT)
	box.PlaceholderText = "Ask Claude"
	box.PlaceholderColor3 = DIMMER
	box.BackgroundTransparency = 1
	box.TextWrapped = true
	box.TextYAlignment = Enum.TextYAlignment.Top
	box.Size = UDim2.new(1, 0, 0, LINE + 4)
	box.AutomaticSize = Enum.AutomaticSize.Y
	self.box = box
	local function fitBox()
		local lines = math.max(1, math.ceil((box.TextBounds.Y - 1) / LINE))
		inputScroll.Size = UDim2.new(1, 0, 0, math.min(lines, MAX_LINES) * LINE + 4)
		-- Typing at the end keeps the caret in view.
		if box.CursorPosition == -1 or box.CursorPosition >= #box.Text then
			inputScroll.CanvasPosition = Vector2.new(0, math.max(0, inputScroll.AbsoluteCanvasSize.Y - inputScroll.AbsoluteWindowSize.Y))
		end
	end
	box:GetPropertyChangedSignal("TextBounds"):Connect(fitBox)
	-- Shift as the box sees it (a dock widget's keys don't always reach UserInputService).
	local shiftHeld = false
	local function trackShift(input: InputObject, down: boolean)
		if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
			shiftHeld = down
		end
	end
	box.InputBegan:Connect(function(input)
		trackShift(input, true)
	end)
	box.InputEnded:Connect(function(input)
		trackShift(input, false)
	end)
	box.FocusLost:Connect(function()
		shiftHeld = false
	end)
	local previousText = box.Text
	box:GetPropertyChangedSignal("Text"):Connect(function()
		local text = box.Text
		-- Enter inserts "\n" in a multi-line box: without Shift held, take it back out and send instead.
		local at = box.CursorPosition - 1
		local typedNewline = #text == #previousText + 1 and at >= 1 and string.sub(text, at, at) == "\n"
		local shift = shiftHeld or UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		if typedNewline and not shift then
			local restored = string.sub(text, 1, at - 1) .. string.sub(text, at + 1)
			previousText = restored
			box.Text = restored
			task.defer(function()
				self:send()
			end)
			return
		end
		previousText = text
	end)
	fitBox()

	local actions = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, ROUND), LayoutOrder = 3, ZIndex = 5 }, composer)
	local modeTag = style(make("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -(ROUND + 8), 1, 0) }, actions), "Code: edits the dev branch", SMALL, DIMMER, FONT)
	modeTag.TextWrapped = false
	modeTag.TextTruncate = Enum.TextTruncate.AtEnd
	local sendButton = roundButton(actions, COLORS.accent)
	sendButton.AnchorPoint = Vector2.new(1, 0)
	sendButton.Position = UDim2.fromScale(1, 0)
	self.sendButton = sendButton
	local sendIcon = make("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -1), Size = UDim2.fromOffset(18, 18) }, sendButton)
	chevron(sendIcon, "up", COLORS.dark, 3)
	self.sendIcon = sendIcon
	local stopIcon = make("Frame", {
		BackgroundColor3 = COLORS.dark,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(11, 11),
		Visible = false,
	}, sendButton)
	corner(stopIcon, 2)
	self.stopIcon = stopIcon
	sendButton.Activated:Connect(function()
		if self:running() then
			self:cancel()
		else
			self:send()
		end
	end)

	self:paintComposer()
	self:paintEmpty()

	-- Working dots: a slow wave, only while something runs.
	task.spawn(function()
		local phase = 0
		while true do
			task.wait(0.25)
			local message = self.active
			if message and not message.finished and message.dots.Visible then
				phase = (phase + 1) % 3
				for index, child in message.dots:GetChildren() do
					if child:IsA("Frame") then
						child.BackgroundTransparency = if index - 1 == phase then 0 else 0.6
					end
				end
			end
		end
	end)

	-- Loop: the running message about twice a second, the status every 10 s while the window is open (and as soon as it
	-- attaches to a serve or loses it).
	task.spawn(function()
		while true do
			local ok, err = pcall(function()
				if widget.Enabled and (os.clock() - self.lastStatus >= STATUS_REFRESH or self.endpoint() ~= self.statusEndpoint) then
					self:refreshStatus()
				end
				self:keepStream()
				self:watchActive()
				self:restore()
				if not self:streaming() or os.clock() - self.lastPush >= STREAM_QUIET then
					self.lastPush = os.clock()
					self:poll()
				end
			end)
			if not ok then
				self:notify(`Failed: {err}`, COLORS.bad)
			end
			task.wait(if self:running() then POLL_ACTIVE else POLL_IDLE)
		end
	end)
	return self
end

function Claude:request(method: string, path: string, body: any?): (boolean, any)
	local endpoint = self.endpoint()
	if endpoint == nil then
		return false, "not_connected"
	end
	return Control.request(endpoint, method, path, body)
end

function Claude:notify(text: string, color: Color3?)
	self.notice.Text = text
	self.notice.TextColor3 = color or COLORS.dim
	self.notice.Visible = text ~= ""
end

function Claude:refreshStatus()
	self.lastStatus = os.clock()
	self.statusEndpoint = self.endpoint()
	local status = self.status
	if self.endpoint() == nil then
		status.Text = "Not connected · waiting for typetorch serve"
		status.TextColor3 = COLORS.warn
		return
	end
	local ok, reply = self:request("GET", "/tt/claude")
	if not ok then
		status.Text = if string.find(tostring(reply), "no route") then "This typetorch serve is too old for Claude" else errorText(reply)
		status.TextColor3 = COLORS.bad
	elseif reply.available then
		status.Text = `Connected · {reply.branch or "?"}`
		status.TextColor3 = COLORS.good
	else
		status.Text = reply.hint or "Claude isn't running"
		status.TextColor3 = COLORS.warn
	end
end

function Claude:running(): boolean
	return self.active ~= nil and not self.active.finished
end

function Claude:paintComposer()
	local busy = self:running()
	self.sendIcon.Visible = not busy
	self.stopIcon.Visible = busy
	self.sendButton.BackgroundColor3 = if busy then COLORS.text else COLORS.accent
end

function Claude:paintEmpty()
	self.emptyHint.Visible = #self.messages == 0
end

-- User bubbles: right-aligned, as wide as their text up to 80% of the panel (TextService measures the text).
function Claude:fitBubble(bubble)
	local max = math.max(80, math.floor((self.list.AbsoluteSize.X - 26) * BUBBLE_SHARE))
	local size = TextService:GetTextSize(bubble.text, TEXT_SIZE, FONT, Vector2.new(max - 24, 100000))
	bubble.frame.Size = UDim2.fromOffset(math.min(max, math.ceil(size.X) + 26), 0)
end

function Claude:buildMessage(id: string, prompt: string)
	self.order += 1
	local frame = autoFrame(self.list, self.order)
	list(frame, 8)
	local userRow = autoFrame(frame, 1)
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 6),
	}, userRow)
	-- The mode the message was sent in: a tiny dim tag at the bubble's bottom-left.
	local modeTag = style(make("TextLabel", { BackgroundTransparency = 1, LayoutOrder = 1 }, userRow), "code", SMALL - 2, DIMMER, FONT)
	modeTag.TextWrapped = false
	modeTag.Size = UDim2.fromOffset(0, LINE)
	modeTag.AutomaticSize = Enum.AutomaticSize.X
	local bubble = make("Frame", { BackgroundColor3 = BUBBLE_BG, BorderSizePixel = 0, AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2 }, userRow)
	corner(bubble, 14)
	pad(bubble, 8, 12)
	label(escapeRich(prompt), COLORS.text, TEXT_SIZE, true).Parent = bubble
	local fit = { frame = bubble, text = prompt }
	table.insert(self.bubbles, fit)
	self:fitBubble(fit)
	local reply = autoFrame(frame, 2)
	list(reply, 8)
	local outcome = label("", DIMMER, SMALL, false)
	outcome.LayoutOrder = 100000
	outcome.Visible = false
	outcome.Parent = reply
	-- Working indicator: three dots, no text.
	local dots = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(44, 14), LayoutOrder = 100001, Visible = false }, reply)
	for index = 0, 2 do
		local dot = make("Frame", { BackgroundColor3 = COLORS.dim, BorderSizePixel = 0, Position = UDim2.fromOffset(index * 14, 3), Size = UDim2.fromOffset(8, 8) }, dots)
		corner(dot, 4)
	end
	return {
		id = id,
		prompt = prompt,
		state = "queued",
		finished = false,
		cursor = 0,
		seen = {},
		frame = frame,
		reply = reply,
		segments = {},
		tools = {},
		outcome = outcome,
		dots = dots,
	}
end

function Claude:addNote(message, text: string, color: Color3)
	local line = label(text, color, SMALL, false)
	line.LayoutOrder = #message.segments + 1
	line.Parent = message.reply
	table.insert(message.segments, { kind = "note", line = line })
end

local function proposalCard(message)
	for _, segment in message.segments do
		if segment.kind == "proposal" then
			return segment
		end
	end
	return nil
end

-- Unix seconds (an older field may be ms).
local function seconds(at: number): number
	return if at > 1e11 then at / 1000 else at
end

-- The deploy card's status line and buttons, from the message state and the proposal.
function Claude:paintProposal(message)
	local card = proposalCard(message)
	if not card then
		return
	end
	local proposal = message.proposal
	local expiresAt = seconds((proposal and proposal.expiresAt) or card.expiresAt)
	local text = ""
	local color = DIMMER
	local state = message.state
	local pending = state == "proposed" and (proposal == nil or proposal.status == "pending")
	if pending then
		text = `Deploy within {math.max(1, math.ceil((expiresAt - os.time()) / 60))} min, or it is discarded`
	elseif state == "building" and proposal and proposal.status == "awaiting_approval" then
		text = `Waiting for approval on your PC{if proposal.approvalId then `  ({proposal.approvalId})` else ""}`
	elseif state == "building" then
		text = "Deploying..."
	elseif state == "deployed" then
		text = `Deployed{if message.artifactId then ` {message.artifactId}` else ""}`
		color = COLORS.good
	elseif state == "discarded" then
		text = if proposal and proposal.status == "expired" then "Expired after 15 min: discarded" else "Discarded"
	elseif state == "failed" and proposal and proposal.status == "rejected" then
		text = "Rejected on your PC: not deployed"
	elseif state == "failed" and proposal and proposal.status == "approval_expired" then
		text = "Approval expired after 24 h: not deployed"
	elseif state == "failed" then
		text = errorText((proposal and proposal.error) or message.error or "deploy failed")
		color = COLORS.bad
	elseif state == "lost" then
		text = "Lost (the dev machine restarted)"
	end
	card.status.Text = text
	card.status.TextColor3 = color
	card.status.Visible = text ~= ""
	card.buttons.Visible = pending and not card.busy
end

-- A code change waiting for the dev: summary, changed files with +/- lines, Deploy and Discard.
function Claude:addProposalCard(message, event)
	if proposalCard(message) then
		return
	end
	local frame = make("Frame", {
		BackgroundColor3 = COLORS.header,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = #message.segments + 1,
	}, message.reply)
	corner(frame, 12)
	stroke(frame, COLORS.accent)
	pad(frame, 10, 12)
	list(frame, 6)
	local title = label(`<b>Deploy this change?</b>  {escapeRich(event.text or "")}`, COLORS.text, SMALL, true)
	title.LayoutOrder = 1
	title.Parent = frame
	local files = event.files or {}
	local lines = {}
	for index, file in files do
		if index > 6 then
			break
		end
		local counts = if (file.added or 0) < 0
			then "binary"
			else `<font color="{hex(COLORS.good)}">+{file.added or 0}</font> <font color="{hex(COLORS.bad)}">-{file.removed or 0}</font>`
		table.insert(lines, `{escapeRich(file.path or "")}  {counts}`)
	end
	if #files > 6 then
		table.insert(lines, `+{#files - 6} more files`)
	end
	if #lines > 0 then
		local fileList = label(table.concat(lines, "\n"), DIMMER, SMALL, true)
		fileList.LayoutOrder = 2
		fileList.Parent = frame
	end
	local buttons = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, ROUND), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3 }, frame)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6), Wraps = true }, buttons)
	local status = label("", DIMMER, SMALL, false)
	status.LayoutOrder = 4
	status.Parent = frame
	local card = { kind = "proposal", frame = frame, status = status, buttons = buttons, expiresAt = event.expiresAt or os.time() + 900, busy = false }
	table.insert(message.segments, card)
	local function decide(decision: string)
		task.spawn(function()
			card.busy = true
			self:paintProposal(message)
			local ok, reply = self:request("POST", "/tt/claude/deploy", { id = message.id, decision = decision, user = userId() })
			card.busy = false
			if not ok then
				self:notify(errorText(reply), COLORS.bad)
			elseif decision == "deploy" and message.state == "proposed" then
				message.state = "building"
			end
			self:paintProposal(message)
		end)
	end
	local function button(text: string, color: Color3, textColor: Color3, decision: string, index: number)
		local b = style(make("TextButton", { AutoButtonColor = true, LayoutOrder = index }), text, SMALL, textColor, Enum.Font.BuilderSansMedium)
		b.TextXAlignment = Enum.TextXAlignment.Center
		b.TextWrapped = false
		b.BackgroundColor3 = color
		b.Size = UDim2.fromOffset(0, ROUND)
		b.AutomaticSize = Enum.AutomaticSize.X
		corner(b, 8)
		pad(b, 0, 14)
		b.Parent = buttons
		b.Activated:Connect(function()
			decide(decision)
		end)
	end
	button("Deploy", COLORS.accent, COLORS.dark, "deploy", 1)
	button("Discard", COLORS.button, COLORS.bad, "discard", 2)
	self:paintProposal(message)
end

-- Applies new events to a message: text streams into its block, tools become one line, errors one red line.
function Claude:applyEvents(message, events)
	for _, event in events do
		if event.i ~= nil and event.i >= 0 then
			if message.seen[event.i] then
				continue
			end
			message.seen[event.i] = true
		end
		local last = message.segments[#message.segments]
		local kind = event.kind
		if kind == "assistant_text" then
			if last and last.kind == "text" and last.block == event.block then
				last.text ..= event.text
				last.dirty = true
			else
				local holder = autoFrame(message.reply, #message.segments + 1)
				list(holder, 6)
				table.insert(message.segments, { kind = "text", block = event.block, text = event.text, holder = holder, rendered = {}, dirty = true })
			end
		elseif kind == "tool_use" then
			local row = autoFrame(message.reply, #message.segments + 1)
			list(row, 2)
			-- Only the line is the button: clicks in the opened details (to select text) don't close them.
			local lineRow = make("TextButton", {
				AutoButtonColor = false,
				Text = "",
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = 1,
			}, row)
			local dot = make("Frame", { BackgroundColor3 = COLORS.info, BorderSizePixel = 0, Position = UDim2.fromOffset(1, 6), Size = UDim2.fromOffset(6, 6) }, lineRow)
			corner(dot, 3)
			local line = label(escapeRich(toolLine(event)), DIMMER, SMALL, true)
			line.TextWrapped = false
			line.TextTruncate = Enum.TextTruncate.AtEnd
			line.AutomaticSize = Enum.AutomaticSize.None
			line.Size = UDim2.new(1, -14, 0, LINE)
			line.Position = UDim2.fromOffset(14, 0)
			line.Parent = lineRow
			local problem = label("", COLORS.bad, SMALL, false)
			problem.TextWrapped = false
			problem.TextTruncate = Enum.TextTruncate.AtEnd
			problem.AutomaticSize = Enum.AutomaticSize.None
			problem.Size = UDim2.new(1, -14, 0, LINE)
			problem.Position = UDim2.fromOffset(14, LINE)
			problem.Visible = false
			problem.Parent = lineRow
			local segment = { kind = "tool", event = event, failed = false, dot = dot, line = line, problem = problem }
			table.insert(message.segments, segment)
			if event.ref ~= nil then
				message.tools[event.ref] = segment
			end
			-- Collapsed by default: one line. A tap builds (once) and toggles the input and output.
			lineRow.Activated:Connect(function()
				if segment.details then
					segment.details.Visible = not segment.details.Visible
					return
				end
				local parts = {}
				local input = event.detail or event.target
				if input ~= nil and input ~= "" then
					table.insert(parts, string.sub(input, 1, 4000))
				end
				local output = segment.resultDetail or segment.result
				if output ~= nil then
					table.insert(parts, `-> {string.sub(output, 1, 4000)}`)
				end
				if #parts == 0 then
					return
				end
				local details = style(make("TextBox", { BackgroundColor3 = CODE_BG, ClearTextOnFocus = false, TextEditable = false, MultiLine = true, LayoutOrder = 2 }), table.concat(parts, "\n"), SMALL, CODE_TEXT, FONT)
				details.TextYAlignment = Enum.TextYAlignment.Top
				details.Size = UDim2.fromScale(1, 0)
				details.AutomaticSize = Enum.AutomaticSize.Y
				corner(details, 6)
				pad(details, 6, 8)
				details.Parent = row
				segment.details = details
			end)
		elseif kind == "tool_result" then
			-- Paired by tool_use id (several tools can run at once); without one: the oldest open call.
			local segment = if event.ref ~= nil then message.tools[event.ref] else nil
			if not segment and event.ref == nil then
				for _, candidate in message.segments do
					if candidate.kind == "tool" and candidate.result == nil then
						segment = candidate
						break
					end
				end
			end
			if segment and segment.result == nil then
				local text = event.text or ""
				segment.result = text
				segment.resultDetail = event.detail
				segment.failed = string.sub(text, 1, 6) == "error:"
				segment.dot.BackgroundColor3 = if segment.failed then COLORS.bad else DIMMER
				-- The short result after the call, darker.
				if not segment.failed then
					segment.line.Text = `{escapeRich(toolLine(segment.event))}  <font color="{hex(RESULT_DIM)}">{escapeRich(string.sub(text, 1, 60))}</font>`
				else
					segment.problem.Text = string.sub((string.gsub(string.sub(text, 7), "^%s+", "")), 1, 140)
					segment.problem.Visible = true
				end
			end
		elseif kind == "deploy_proposal" then
			self:addProposalCard(message, event)
		elseif kind == "error" then
			self:addNote(message, errorText(event.text), COLORS.bad)
		elseif kind == "status" and event.state == nil then
			self:addNote(message, event.text, DIMMER)
		end
	end
	for _, segment in message.segments do
		if segment.kind == "text" and segment.dirty then
			segment.dirty = false
			syncBlocks(segment.holder, segment.rendered, parseMarkdown(segment.text))
		end
	end
end

-- The end of a message: dots while it runs, one short line when it finished with something to say.
function Claude:paintOutcome(message)
	-- A proposal waits for the dev, not for Claude: no dots then.
	message.dots.Visible = not message.finished
		and message.state ~= "proposed"
		and not (message.proposal and message.proposal.status == "awaiting_approval")
	self:paintProposal(message)
	local text = ""
	local color = DIMMER
	if message.finished and not proposalCard(message) then
		local state = message.state
		if state == "deployed" then
			text = `Deployed{if message.artifactId then ` {message.artifactId}` else ""}`
		elseif state == "cancelled" then
			text = "Stopped"
		elseif state == "lost" then
			text = "Lost (the dev machine restarted)"
		elseif state == "failed" then
			local noted = false
			for _, segment in message.segments do
				if segment.kind == "note" then
					noted = true
				end
			end
			if not noted then
				text = errorText(message.error or "Failed")
				color = COLORS.bad
			end
		end
	end
	message.outcome.Text = text
	message.outcome.TextColor3 = color
	message.outcome.Visible = text ~= ""
end

function Claude:finish(message, state: string)
	message.finished = true
	message.state = state
	self:paintOutcome(message)
	self:paintComposer()
end

-- A prompt's view from serve (GET /tt/claude/prompt, or pushed by the stream): its new events, state and cursor.
function Claude:applyView(message, reply)
	self:applyEvents(message, reply.events or {})
	message.cursor = math.max(message.cursor, reply.next or message.cursor)
	message.state = reply.state or message.state
	message.commit = reply.commit or message.commit
	message.artifactId = reply.artifactId or message.artifactId
	message.error = reply.error or message.error
	message.proposal = reply.proposal or message.proposal
	message.finished = FINISHED[message.state] == true
	self:paintOutcome(message)
	if message.finished then
		self:paintComposer()
	end
end

-- The stream ---------------------------------------------------------------------------------------------------------

-- Opens the event stream to serve, or keeps the open one.
function Claude:keepStream()
	local endpoint = self.endpoint()
	local stream = self.stream
	if stream and (stream.closed or stream.endpoint ~= endpoint) then
		self:closeStream()
		stream = nil
	end
	if stream or endpoint == nil or os.clock() < self.streamRetryAt then
		return
	end
	local url, headers = Control.streamTarget(endpoint, userId())
	local ok, client = pcall(HttpService.CreateWebStreamClient, HttpService, Enum.WebStreamClientType.WebSocket, { Url = url, Headers = headers })
	if not ok then
		return self:streamFailed()
	end
	stream = { client = client, endpoint = endpoint, ready = false, closed = false, watching = nil, refused = {}, connections = {} }
	self.stream = stream
	local function lost()
		if stream.closed then
			return
		end
		stream.closed = true
		if not stream.ready then
			self:streamFailed()
		end
	end
	table.insert(stream.connections, client.MessageReceived:Connect(function(text)
		self:onStream(stream, text)
	end))
	table.insert(stream.connections, client.Closed:Connect(lost))
	table.insert(stream.connections, client.Error:Connect(lost))
end

function Claude:streamFailed()
	self.streamFailures += 1
	self.streamRetryAt = os.clock() + STREAM_RETRY[math.min(self.streamFailures, #STREAM_RETRY)]
end

function Claude:closeStream()
	local stream = self.stream
	if not stream then
		return
	end
	self.stream = nil
	stream.closed = true
	for _, connection in stream.connections do
		connection:Disconnect()
	end
	pcall(stream.client.Close, stream.client)
end

-- The running prompt's events come over the stream.
function Claude:streaming(): boolean
	local stream = self.stream
	return stream ~= nil and stream.ready and not stream.closed and self.active ~= nil and stream.watching == self.active.id
end

-- Asks the stream for the running prompt's events from its cursor on (again after a reconnect).
function Claude:watchActive()
	local stream = self.stream
	local message = self.active
	if not stream or not stream.ready or stream.closed or not message or message.finished or message.pending then
		return
	end
	if stream.watching == message.id or stream.refused[message.id] then
		return
	end
	if stream.watching then
		pcall(stream.client.Send, stream.client, HttpService:JSONEncode({ unwatch = stream.watching }))
	end
	local sent = pcall(stream.client.Send, stream.client, HttpService:JSONEncode({ watch = message.id, since = message.cursor }))
	stream.watching = if sent then message.id else nil
	self.lastPush = os.clock()
end

function Claude:onStream(stream, text: string)
	if self.stream ~= stream then
		return
	end
	local ok, data = pcall(HttpService.JSONDecode, HttpService, text)
	if not ok or type(data) ~= "table" then
		return
	end
	local message = self.active
	if data.type == "ready" then
		stream.ready = true
		self.streamFailures = 0
		self:watchActive()
	elseif data.type == "prompt" then
		if not message or message.id ~= data.id then
			return
		end
		self.lastPush = os.clock()
		if type(data.since) == "number" and data.since > message.cursor then
			-- Events between the cursor and this push never arrived: HTTP fetches them on the next round.
			self.lastPush = -math.huge
			return
		end
		self:applyView(message, data)
	elseif data.type == "error" and message and data.id == message.id then
		-- The stream gave up on this prompt: HTTP polling takes over (or it is gone).
		stream.refused[message.id] = true
		stream.watching = nil
		if data.status == 404 then
			self:finish(message, "lost")
		end
	end
end

-- One round of polling for the running message (more pages right away when the dev machine has them).
function Claude:poll()
	local message = self.active
	if not message or message.finished or message.pending then
		return
	end
	self:fetch(message, 5)
end

-- Up to `pages` pages of a message's new events.
function Claude:fetch(message, pages: number)
	local myView = self.view
	for _ = 1, pages do
		local ok, reply = self:request("GET", `/tt/claude/prompt?id={message.id}&since={message.cursor}&user={userId()}`)
		if myView ~= self.view then
			return
		end
		if not ok or type(reply) ~= "table" then
			self.failures += 1
			-- The dev machine forgot the prompt (serve or remote-claude restarted), or it is gone: stop waiting.
			if isNotFound(reply) or self.failures >= 15 then
				self:finish(message, "lost")
			end
			return
		end
		self.failures = 0
		self:applyView(message, reply)
		if message.finished or reply.more ~= true then
			return
		end
	end
end

-- Sends the chat (its id and the last prompts) to serve.
local function chatKey(conversationId: string?, ids: { string }): string
	return `{conversationId or ""}|{table.concat(ids, ",")}`
end

function Claude:save()
	local ids = {}
	for index = math.max(1, #self.messages - KEEP_MESSAGES + 1), #self.messages do
		local message = self.messages[index]
		if message.pending then
			continue
		end
		self.promptTexts[message.id] = message.prompt
		table.insert(ids, message.id)
	end
	self.chatKey = chatKey(self.conversationId, ids)
	local body = { user = userId(), conversationId = self.conversationId, prompts = ids }
	self.saving += 1
	task.spawn(function()
		self:request("POST", "/tt/claude/chat", body)
		self.saving -= 1
	end)
end

-- Rebuilds the chat when another DataModel's copy changed it (or on load): each prompt and its replies from serve.
function Claude:restore()
	if self.endpoint() == nil or self.sending or self.saving > 0 or os.clock() - self.lastChatCheck < CHAT_CHECK then
		return
	end
	self.lastChatCheck = os.clock()
	local ok, saved = self:request("GET", `/tt/claude/chat?user={userId()}`)
	if not ok or type(saved) ~= "table" or type(saved.prompts) ~= "table" or self.sending or self.saving > 0 then
		return
	end
	local key = chatKey(saved.conversationId, saved.prompts)
	if key == self.chatKey then
		return
	end
	self:clearTranscript()
	self.chatKey = key
	self.conversationId = saved.conversationId
	local texts = if type(saved.texts) == "table" then saved.texts else {}
	local myView = self.view
	for _, id in saved.prompts do
		local message = self:buildMessage(id, texts[id] or self.promptTexts[id] or "Earlier prompt")
		table.insert(self.messages, message)
		self.failures = 0
		self:fetch(message, CATCH_UP_PAGES)
		if myView ~= self.view then
			return
		end
		self:paintOutcome(message)
	end
	local last = self.messages[#self.messages]
	self.active = if last and not last.finished then last else nil
	self.failures = 0
	self:paintEmpty()
	self:paintComposer()
	self.scrollToEnd()
end

function Claude:clearTranscript()
	self.view += 1
	for _, message in self.messages do
		message.frame:Destroy()
	end
	self.messages = {}
	self.bubbles = {}
	self.active = nil
	self:paintComposer()
	self:paintEmpty()
end

function Claude:send()
	if self.sending then
		return
	end
	if self:running() then
		return self:notify(errorText("busy"), COLORS.warn)
	end
	local prompt = trim(self.box.Text)
	if prompt == "" then
		return self:notify(errorText("empty"), COLORS.warn)
	end
	if #prompt > MAX_PROMPT then
		return self:notify(errorText("too_long"), COLORS.warn)
	end
	self.sending = true
	self.box.Text = ""
	-- The bubble and the working dots show at once; the message gets its id when serve answers.
	local message = self:addPending(prompt)
	task.spawn(function()
		local ok, reply = self:request("POST", "/tt/claude/prompt", { prompt = prompt, conversationId = self.conversationId, user = userId() })
		local restarted = false
		if not ok and self.conversationId ~= nil and isNotFound(reply) then
			-- The dev machine forgot the chat (it restarted): start a new one with the same message.
			restarted = true
			self.conversationId = nil
			self:clearTranscript()
			message = self:addPending(prompt)
			ok, reply = self:request("POST", "/tt/claude/prompt", { prompt = prompt, user = userId() })
		end
		self.sending = false
		if not ok or type(reply) ~= "table" or type(reply.id) ~= "string" then
			if reply == "not_connected" or self.endpoint() == nil then
				self.lastStatus = -math.huge
			end
			self:dropPending(message, prompt)
			return self:notify(errorText(if ok then "Failed" else reply), COLORS.bad)
		end
		self:notify(if restarted then "The old chat was gone: started a new one" else "")
		self.conversationId = reply.conversationId or self.conversationId
		message.id = reply.id
		message.pending = nil
		message.state = reply.state or message.state
		self:save()
		self:watchActive()
		if not self:streaming() then
			self:poll()
		end
	end)
end

-- A message being sent: shown at once, without an id until serve answers.
function Claude:addPending(prompt: string)
	local message = self:buildMessage("", prompt)
	message.pending = true
	table.insert(self.messages, message)
	self.active = message
	self.failures = 0
	self:paintOutcome(message)
	self:paintEmpty()
	self:paintComposer()
	self.scrollToEnd()
	return message
end

-- The send failed: the bubble goes and the text is back in the box.
function Claude:dropPending(message, prompt: string)
	message.frame:Destroy()
	local index = table.find(self.messages, message)
	if index then
		table.remove(self.messages, index)
	end
	if self.active == message then
		self.active = nil
	end
	if self.box.Text == "" then
		self.box.Text = prompt
	end
	self:paintEmpty()
	self:paintComposer()
end

-- Stop. If the dev machine can't be told (gone, or the run already ended), the run ends here anyway.
function Claude:cancel()
	local message = self.active
	if not message or message.finished or message.pending then
		return
	end
	task.spawn(function()
		local ok, reply = self:request("POST", "/tt/claude/cancel", { id = message.id, user = userId() })
		if ok then
			return
		end
		if isNotFound(reply) or reply == "not_connected" or string.find(tostring(reply), "HttpError", 1, true) then
			self:finish(message, "cancelled")
		else
			self:notify(errorText(reply), COLORS.bad)
		end
	end)
end

function Claude:newChat()
	self.conversationId = nil
	self:clearTranscript()
	self:save()
	self:notify("")
end

return Claude
