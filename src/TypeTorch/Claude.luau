--!nonstrict
-- The Claude window: prompts Claude Code on the machine that runs `typetorch serve --claude` (remote-claude from
-- @typetorch/dev-server). A port of the in-game DEV > Claude tab (framework src/devtools/claude-ui.ts): the same status
-- line, bubbles, Markdown, tool lines, working dots, scroll-to-bottom button, composer, Live / Code pill, "+" menu
-- (Dex path = the Studio selection, My logs, Server logs, Toolbox) and deploy card. Live needs a running game, so it
-- works in Play only. Requests go through serve's
-- control API (`/tt/claude/...`), locally or through a paired remote serve. The running prompt's events come over
-- serve's WebSocket stream (`/tt/claude/stream`) as they happen, also in the Play client (which can't make HTTP
-- requests but can open the stream); HTTP polling stands in while there is no stream.

local AssetService = game:GetService("AssetService")
local CaptureService = game:GetService("CaptureService")
local EncodingService = game:GetService("EncodingService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Selection = game:GetService("Selection")
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
	image_gone = "Image expired",
	image_api = "Images need EditableImage (Studio's Mesh / Image APIs)",
	image_data = "Image unreadable",
	capture_failed = "Screenshot failed",
	no_capture = "Screenshot not found on the dev-server PC",
	capture_client = "Screenshots work in the Play client",
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

-- A glyph drawn from Frames for the "+" menu (claude-ui.ts menuIcon; no emojis or font glyphs).
local function menuIcon(parent: Instance, kind: string, color: Color3): Frame
	local box = make("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Size = UDim2.fromOffset(16, 16) }, parent)
	local function bar(x: number, y: number, w: number, h: number)
		make("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h) }, box)
	end
	local function outline(x: number, y: number, w: number, h: number, round: number)
		local frame = make("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h) }, box)
		corner(frame, round)
		make("UIStroke", { Color = color, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, frame)
	end
	if kind == "dex" then
		-- A small tree: a root bar and two indented children.
		bar(0, 1, 10, 3)
		bar(5, 7, 10, 3)
		bar(5, 13, 10, 3)
		bar(2, 4, 2, 11)
	elseif kind == "logs" then
		-- A page of lines.
		bar(1, 2, 14, 2)
		bar(1, 7, 10, 2)
		bar(1, 12, 13, 2)
	elseif kind == "server" then
		-- Two stacked server boxes with a light each.
		for _, y in { 1, 9 } do
			outline(0, y, 16, 6, 2)
			bar(11, y + 2, 2, 2)
		end
	elseif kind == "camera" then
		-- A camera: a stroked body, a bump on top and a round lens.
		bar(4, 2, 6, 3)
		outline(0, 4, 16, 11, 3)
		local lens = make("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(5, 7), Size = UDim2.fromOffset(6, 6) }, box)
		corner(lens, 3)
		make("UIStroke", { Color = color, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, lens)
	elseif kind == "toolbox" then
		-- A toolbox: a stroked body with a handle on top and a latch.
		outline(5, 1, 6, 5, 2)
		outline(0, 5, 16, 10, 2)
		bar(7, 8, 2, 4)
	end
	return box
end

-- A small "x" button drawn from two Frames.
local function removeButton(parent: Instance, order: number, onClick: () -> ())
	local remove = make("TextButton", { AutoButtonColor = true, Text = "", BackgroundTransparency = 1, Size = UDim2.fromOffset(20, 20), LayoutOrder = order }, parent)
	for _, angle in { 45, -45 } do
		make("Frame", { BackgroundColor3 = COLORS.dim, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(10, 2), Rotation = angle }, remove)
	end
	remove.Activated:Connect(onClick)
	return remove
end

local function modeName(mode: string): string
	return if mode == "live" then "Live" else "Code"
end

-- The Studio DataModel this copy runs in, as the "Dex path" realm.
local function realm(): string
	if RunService:IsEdit() then
		return "edit"
	end
	return if RunService:IsServer() then "server" else "client"
end

-- Emojis Claude might still send, as text where the meaning would be lost (claude-ui.ts EMOJI_TEXT).
local EMOJI_TEXT = { [0x2705] = "ok", [0x2714] = "ok", [0x274c] = "failed", [0x2716] = "failed", [0x26a0] = "warning", [0x23ed] = "skipped" }

local function isEmoji(code: number): boolean
	return (code >= 0x1f000 and code <= 0x1faff)
		or (code >= 0x2600 and code <= 0x27bf)
		or (code >= 0x2b00 and code <= 0x2bff)
		or (code >= 0x23e9 and code <= 0x23fa)
		or code == 0xfe0f
		or code == 0x200d
end

-- No emojis in the UI (user rule): drops them, keeping a word for the few that carry meaning.
local function stripEmoji(text: string): string
	if not utf8.len(text) then
		return text
	end
	local plain = true
	for _, code in utf8.codes(text) do
		if isEmoji(code) then
			plain = false
			break
		end
	end
	if plain then
		return text
	end
	local out = {}
	for _, code in utf8.codes(text) do
		local word = EMOJI_TEXT[code]
		if word then
			table.insert(out, word)
		elseif not isEmoji(code) then
			table.insert(out, utf8.char(code))
		end
	end
	return table.concat(out)
end

-- Toolbox --------------------------------------------------------------------------------------------------------------

-- A Creator Store thumbnail (the engine resolves rbxthumb).
local function toolboxThumb(id: number): string
	return `rbxthumb://type=Asset&id={id}&w=150&h=150`
end

-- 7000 -> "7k", 1250000 -> "1.3M".
local function compactNumber(value: number): string
	if value >= 1e6 then
		return `{math.floor(value / 1e5) / 10}M`
	elseif value >= 1e3 then
		return (string.gsub(`{math.floor(value / 100) / 10}k`, "%.0k", "k"))
	end
	return tostring(math.floor(value))
end

-- The verified-creator check: two Frames in a small circle (no glyph characters).
local function verifiedMark(parent: Instance, order: number)
	local badge = make("Frame", { BackgroundColor3 = COLORS.info, BorderSizePixel = 0, Size = UDim2.fromOffset(12, 12), LayoutOrder = order }, parent)
	corner(badge, 6)
	make("Frame", { BackgroundColor3 = COLORS.dark, BorderSizePixel = 0, Position = UDim2.fromOffset(2, 6), Size = UDim2.fromOffset(4, 2), Rotation = 45 }, badge)
	make("Frame", { BackgroundColor3 = COLORS.dark, BorderSizePixel = 0, Position = UDim2.fromOffset(4, 5), Size = UDim2.fromOffset(7, 2), Rotation = -50 }, badge)
	return badge
end

-- One short line of tile facts: "0 scripts" (good) or "2 scripts" (warn), the length, the vote share.
local function toolboxFacts(tile): string
	local parts = {}
	if type(tile.scripts) == "number" then
		table.insert(parts, `<font color="{hex(if tile.scripts == 0 then COLORS.good else COLORS.warn)}">{tile.scripts} scripts</font>`)
	end
	if type(tile.seconds) == "number" then
		table.insert(parts, `{tile.seconds}s`)
	end
	if type(tile.upPercent) == "number" then
		table.insert(parts, `{tile.upPercent}%`)
	end
	return table.concat(parts, "  ")
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
		-- An image (![caption](path)) shows as its own block (the image event), so its Markdown is dropped here.
		formatted = string.gsub(formatted, "!%[[^%]]-%]%([^%)]-%)", "")
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
	elseif tool == "screenshot" then
		return "Screenshot"
	elseif tool == "toolbox_search" then
		return "Searched the Toolbox"
	elseif tool == "toolbox_insert" then
		return "Toolbox insert"
	elseif tool == "toolbox_add" then
		return "Added a Toolbox asset"
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
	-- Live / Code for the next message, remembered per conversation (in this copy).
	self.mode = "code"
	self.modes = {} :: { [string]: string }
	-- The "+" menu's context for the next messages; the Toolbox goes with one message only.
	self.attach = { path = false, myLogs = false, serverLogs = false, toolbox = false }
	-- Screenshots for the next message: { contentId, captureTime } (at most MAX_SHOTS).
	self.shots = {}

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
	-- Testing reconnects: setting the widget's ClaudeDropStream attribute closes the stream as a dropped one would.
	widget:GetAttributeChangedSignal("ClaudeDropStream"):Connect(function()
		local stream = self.stream
		if stream then
			pcall(stream.client.Close, stream.client)
		end
	end)
	-- Testing screenshots: setting ClaudeScreenshot takes one as the "+" menu's Screenshot does.
	widget:GetAttributeChangedSignal("ClaudeScreenshot"):Connect(function()
		self:screenshot()
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
	-- The status line: tap it for the recent chats.
	local statusButton = make("TextButton", { AutoButtonColor = false, Text = "", BackgroundTransparency = 1, Size = UDim2.fromOffset(150, ROUND), LayoutOrder = 1 }, statusRow)
	make("UIFlexItem", { FlexMode = Enum.UIFlexMode.Fill }, statusButton)
	local status = style(make("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -18, 1, 0) }, statusButton), "Checking...", SMALL, COLORS.dim, FONT)
	status.TextWrapped = false
	status.TextTruncate = Enum.TextTruncate.AtEnd
	self.status = status
	local statusChevron = make("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(14, 14) }, statusButton)
	chevron(statusChevron, "down", COLORS.dim, 2)
	local chats = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Visible = false }, top)
	list(chats, 4)
	self.chats = chats
	statusButton.Activated:Connect(function()
		self:toggleChats()
	end)
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
	self.box = box
	-- The height is measured (AutomaticSize doesn't grow a TextBox inside a ScrollingFrame: it stays one line tall).
	local function fitBox()
		local width = box.AbsoluteSize.X
		if width <= 0 then
			return
		end
		local text = box.Text
		if string.sub(text, -1) == "\n" then
			text ..= " "
		end
		local height = TextService:GetTextSize(if text == "" then " " else text, TEXT_SIZE, FONT, Vector2.new(width, 100000)).Y
		local lines = math.max(1, math.ceil((height - 1) / LINE))
		box.Size = UDim2.new(1, 0, 0, lines * LINE + 4)
		inputScroll.Size = UDim2.new(1, 0, 0, math.min(lines, MAX_LINES) * LINE + 4)
		-- Typing at the end keeps the caret in view.
		if box.CursorPosition == -1 or box.CursorPosition >= #box.Text then
			inputScroll.CanvasPosition = Vector2.new(0, math.max(0, inputScroll.AbsoluteCanvasSize.Y - inputScroll.AbsoluteWindowSize.Y))
		end
	end
	box:GetPropertyChangedSignal("Text"):Connect(fitBox)
	box:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		task.defer(fitBox)
	end)
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

	-- Chips for the context that goes with the next message (from the "+" menu).
	local chips = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Visible = false }, composer)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4), Wraps = true }, chips)
	self.chips = chips

	local actions = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, ROUND), LayoutOrder = 3, ZIndex = 5 }, composer)
	local plusButton = roundButton(actions, COLORS.button)
	for _, size in { { 12, 2 }, { 2, 12 } } do
		make("Frame", { BackgroundColor3 = COLORS.text, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(size[1], size[2]) }, plusButton)
	end
	-- Live / Code: which tools Claude gets for the next message. A pill next to "+".
	local modeButton = make("TextButton", {
		AutoButtonColor = true,
		Text = "",
		BackgroundColor3 = COLORS.button,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(ROUND + 6, 0),
		Size = UDim2.fromOffset(0, ROUND),
		AutomaticSize = Enum.AutomaticSize.X,
	}, actions)
	corner(modeButton, ROUND / 2)
	make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 12) }, modeButton)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, modeButton)
	local modeDot = make("Frame", { BorderSizePixel = 0, Size = UDim2.fromOffset(8, 8), LayoutOrder = 1 }, modeButton)
	corner(modeDot, 4)
	local modeText = style(make("TextLabel", { BackgroundTransparency = 1, LayoutOrder = 2 }, modeButton), "", SMALL, COLORS.text, Enum.Font.BuilderSansMedium)
	modeText.TextWrapped = false
	modeText.Size = UDim2.fromOffset(0, ROUND)
	modeText.AutomaticSize = Enum.AutomaticSize.X
	self.paintMode = function()
		local mode = self:currentMode()
		modeText.Text = modeName(mode)
		modeDot.BackgroundColor3 = if mode == "live" then COLORS.good else COLORS.info
	end
	modeButton.Activated:Connect(function()
		local picked = if self:currentMode() == "live" then "code" else "live"
		if picked == "live" and RunService:IsEdit() then
			-- Live acts on a running game server: Edit has none.
			return self:notify("Live works during Play", COLORS.warn)
		end
		self.mode = picked
		if self.conversationId then
			self.modes[self.conversationId] = picked
		end
		self:notify("")
		self.paintMode()
	end)
	self.paintMode()
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

	-- "+" menu: a floating panel just above "+" (claude-ui.ts): toggles with a checkmark when on. A transparent
	-- catcher over the whole window closes it on an outside click (a dock widget's clicks don't reach
	-- UserInputService). Both are the widget's own children, so the window's layout leaves them alone.
	local attach = self.attach
	local items = {
		{ name = "Dex path", icon = "dex", key = "path" },
		{ name = "My logs", icon = "logs", key = "myLogs" },
		{ name = "Server logs", icon = "server", key = "serverLogs", playOnly = true },
		-- An action, not a toggle: takes a screenshot of the playtest view for the next message.
		{ name = "Screenshot", icon = "camera", action = "screenshot", playOnly = true },
		-- The Creator Store for the next message only: without it Claude gets no toolbox tools at all.
		{ name = "Toolbox", icon = "toolbox", key = "toolbox", accent = true },
	}
	local MENU_WIDTH = 210
	local MENU_ROW = 36
	local MENU_PAD = 6
	local MENU_GAP = 2
	local MENU_HEIGHT = #items * MENU_ROW + (#items - 1) * MENU_GAP + MENU_PAD * 2
	local catcher = make("TextButton", { AutoButtonColor = false, Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 10 }, widget)
	local menu = make("Frame", { Name = "PlusMenu", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Size = UDim2.fromOffset(MENU_WIDTH, MENU_HEIGHT), Visible = false, ZIndex = 20 }, widget)
	local shadow = make("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.6, BorderSizePixel = 0, Position = UDim2.fromOffset(2, 3), Size = UDim2.fromScale(1, 1), ZIndex = 19 }, menu)
	corner(shadow, 12)
	local panel = make("Frame", { BackgroundColor3 = COLORS.header, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 20 }, menu)
	corner(panel, 12)
	stroke(panel, COLORS.stroke)
	pad(panel, MENU_PAD, MENU_PAD)
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, MENU_GAP) }, panel)
	local checks = {}
	local paintToggles
	for index, item in items do
		local row = make("TextButton", {
			AutoButtonColor = false,
			Text = "",
			BackgroundColor3 = COLORS.button,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, MENU_ROW),
			LayoutOrder = index,
			ZIndex = 21,
		}, panel)
		corner(row, 8)
		local disabled = item.playOnly and RunService:IsEdit()
		local color = if disabled then DIMMER else COLORS.text
		local icon = menuIcon(row, item.icon, color)
		for _, part in { icon, table.unpack(icon:GetDescendants()) } do
			if part:IsA("GuiObject") then
				part.ZIndex = 22
			end
		end
		local text = style(make("TextLabel", { BackgroundTransparency = 1, ZIndex = 22 }, row), item.name, SMALL, color, FONT)
		text.TextWrapped = false
		text.Position = UDim2.fromOffset(36, 0)
		text.Size = UDim2.new(1, -64, 1, 0)
		-- A checkmark on the right while a toggle is on (two Frames).
		local check = make("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(14, 14), Visible = false, ZIndex = 22 }, row)
		make("Frame", { BackgroundColor3 = COLORS.accent, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 7), Size = UDim2.fromOffset(6, 2), Rotation = 45, ZIndex = 22 }, check)
		make("Frame", { BackgroundColor3 = COLORS.accent, BorderSizePixel = 0, Position = UDim2.fromOffset(3, 5), Size = UDim2.fromOffset(11, 2), Rotation = -50, ZIndex = 22 }, check)
		checks[item] = check
		row.MouseEnter:Connect(function()
			row.BackgroundTransparency = if disabled then 1 else 0
		end)
		row.MouseLeave:Connect(function()
			row.BackgroundTransparency = 1
		end)
		row.Activated:Connect(function()
			if disabled then
				return self:notify(`{item.name} work{if item.action then "s" else ""} during Play`, COLORS.warn)
			end
			if item.action == "screenshot" then
				self.closeMenu()
				return self:screenshot()
			end
			attach[item.key] = not attach[item.key]
			paintToggles()
		end)
	end
	local menuOpen = false
	-- Bottom-left 6 px above "+", kept inside the window horizontally.
	local function placeMenu()
		local at = plusButton.AbsolutePosition - host.AbsolutePosition
		local x = math.clamp(at.X, 4, math.max(4, host.AbsoluteSize.X - MENU_WIDTH - 4))
		menu.Position = UDim2.fromOffset(x, at.Y - 6)
	end
	local function closeMenu()
		if not menuOpen then
			return
		end
		menuOpen = false
		catcher.Visible = false
		popOut(menu)
	end
	self.closeMenu = closeMenu
	plusButton.Activated:Connect(function()
		if menuOpen then
			return closeMenu()
		end
		menuOpen = true
		placeMenu()
		catcher.Visible = true
		popIn(menu)
	end)
	catcher.Activated:Connect(closeMenu)
	host:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if menuOpen then
			placeMenu()
		end
	end)

	paintToggles = function()
		for _, child in chips:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local count = 0
		for index, shot in self.shots do
			-- A screenshot: its thumbnail and an "x".
			count += 1
			local chip = make("Frame", { BackgroundColor3 = COLORS.button, BorderSizePixel = 0, Size = UDim2.fromOffset(0, 40), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 100 + index }, chips)
			corner(chip, 8)
			make("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 2) }, chip)
			make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2) }, chip)
			local thumb = make("ImageLabel", { BackgroundColor3 = CODE_BG, BorderSizePixel = 0, Size = UDim2.fromOffset(math.floor(32 * shot.aspect), 32), Image = shot.contentId, ScaleType = Enum.ScaleType.Crop, LayoutOrder = 1 }, chip)
			corner(thumb, 6)
			removeButton(chip, 2, function()
				local at = table.find(self.shots, shot)
				if at then
					table.remove(self.shots, at)
				end
				paintToggles()
			end)
		end
		for index, item in items do
			if item.action then
				continue
			end
			local on = attach[item.key] == true
			checks[item].Visible = on
			if not on then
				continue
			end
			count += 1
			local chip = make("Frame", { BackgroundColor3 = COLORS.button, BorderSizePixel = 0, Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = index }, chips)
			corner(chip, 12)
			make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 4) }, chip)
			make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }, chip)
			local text = style(make("TextLabel", { BackgroundTransparency = 1, LayoutOrder = 1 }, chip), item.name, SMALL, COLORS.text, FONT)
			text.TextWrapped = false
			text.Size = UDim2.fromOffset(0, 24)
			text.AutomaticSize = Enum.AutomaticSize.X
			if item.accent then
				chip.BackgroundColor3 = COLORS.accent
				text.TextColor3 = COLORS.dark
				-- The item's glyph in front of the text (menuIcon places itself; a holder keeps it in the chip's layout).
				local glyph = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(16, 24), LayoutOrder = 0 }, chip)
				menuIcon(glyph, item.icon, COLORS.dark).Position = UDim2.new(0, 0, 0.5, 0)
			end
			removeButton(chip, 2, function()
				attach[item.key] = false
				paintToggles()
			end)
		end
		chips.Visible = count > 0
	end
	self.paintToggles = paintToggles
	paintToggles()

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

	-- The stream has a loop of its own: a reconnect doesn't wait for the HTTP rounds below.
	task.spawn(function()
		while true do
			local ok, err = pcall(function()
				self:keepStream()
				self:watchActive()
			end)
			if not ok then
				self:notify(`Failed: {err}`, COLORS.bad)
			end
			task.wait(POLL_ACTIVE)
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

-- The mode of the next message: the conversation's, else the last one picked. Edit has no game for Live.
function Claude:currentMode(): string
	local mode = (self.conversationId and self.modes[self.conversationId]) or self.mode
	return if mode == "live" and RunService:IsEdit() then "code" else mode
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

function Claude:buildMessage(id: string, prompt: string, mode: string?)
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
	local modeTag = style(make("TextLabel", { BackgroundTransparency = 1, LayoutOrder = 1 }, userRow), mode or "code", SMALL - 2, DIMMER, FONT)
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
	-- Copy: the whole reply as plain Markdown, pre-selected (a plugin has no clipboard; Ctrl+C copies it).
	local copy = make("TextButton", { AutoButtonColor = true, Text = "", BackgroundTransparency = 1, Size = UDim2.fromOffset(28, 24), LayoutOrder = 100002, Visible = false }, reply)
	for _, at in { { 4, 2 }, { 9, 7 } } do
		local sheet = make("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(at[1], at[2]), Size = UDim2.fromOffset(12, 14) }, copy)
		corner(sheet, 2)
		make("UIStroke", { Color = DIMMER, Thickness = 1.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, sheet)
	end
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
	local message
	copy.Activated:Connect(function()
		self:showCopy(self:replyText(message))
	end)
	message = {
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
		modeTag = modeTag,
		copy = copy,
	}
	return message
end

-- The reply's plain text (for Copy).
function Claude:replyText(message): string
	local parts = {}
	for _, segment in message.segments do
		if segment.kind == "text" then
			table.insert(parts, segment.text)
		end
	end
	return table.concat(parts, "\n\n")
end

-- Text pre-selected in a read-only box over the window (Ctrl+C copies it); a click outside closes it.
function Claude:showCopy(text: string)
	if self.copyLayer then
		self.copyLayer:Destroy()
	end
	local layer = make("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.5, Size = UDim2.fromScale(1, 1), ZIndex = 30 }, self.widget)
	self.copyLayer = layer
	layer.Activated:Connect(function()
		layer:Destroy()
	end)
	local panel = make("Frame", {
		BackgroundColor3 = COLORS.header,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -24, 0.6, 0),
		ZIndex = 31,
		Active = true,
	}, layer)
	corner(panel, 12)
	stroke(panel, COLORS.stroke)
	pad(panel, 8, 10)
	local hint = style(make("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, LINE), ZIndex = 32 }, panel), "Ctrl+C to copy", SMALL, DIMMER, FONT)
	hint.TextWrapped = false
	local scroll = make("ScrollingFrame", {
		BackgroundColor3 = CODE_BG,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, LINE + 6),
		Size = UDim2.new(1, 0, 1, -(LINE + 6)),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = COLORS.dim,
		ZIndex = 32,
	}, panel)
	corner(scroll, 8)
	local box = style(make("TextBox", { BackgroundTransparency = 1, ClearTextOnFocus = false, TextEditable = false, MultiLine = true, ZIndex = 33 }, scroll), text, SMALL, CODE_TEXT, FONT)
	box.TextWrapped = true
	box.TextYAlignment = Enum.TextYAlignment.Top
	box.Size = UDim2.fromScale(1, 0)
	pad(box, 6, 8)
	-- Measured: AutomaticSize doesn't grow a TextBox inside a ScrollingFrame.
	local function fit()
		local width = scroll.AbsoluteSize.X - 16 - scroll.ScrollBarThickness
		if width > 0 then
			box.Size = UDim2.new(1, 0, 0, TextService:GetTextSize(text, SMALL, FONT, Vector2.new(width, 1e6)).Y + 16)
		end
	end
	scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	fit()
	box:CaptureFocus()
	box.SelectionStart = 1
	box.CursorPosition = #text + 1
end

-- Recent chats (tap the status line): up to 6, the current one highlighted; tap one to open it.
function Claude:toggleChats()
	local chats = self.chats
	if chats.Visible then
		chats.Visible = false
		return
	end
	task.spawn(function()
		local ok, reply = self:request("POST", "/tt/claude/v1", { user = userId(), method = "GET", path = "/v1/conversations" })
		if not ok or type(reply) ~= "table" then
			return self:notify(errorText(reply), COLORS.bad)
		end
		for _, child in chats:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local recent = if type(reply.conversations) == "table" then reply.conversations else {}
		if #recent == 0 then
			label("No chats yet", DIMMER, SMALL, false).Parent = chats
		end
		for index = 1, math.min(6, #recent) do
			local conversation = recent[index]
			local row = style(make("TextButton", { AutoButtonColor = true, LayoutOrder = index }), tostring(conversation.title or "chat"), SMALL, COLORS.text, FONT)
			row.TextWrapped = false
			row.TextTruncate = Enum.TextTruncate.AtEnd
			row.BackgroundColor3 = if conversation.id == self.conversationId then COLORS.button else COLORS.row
			row.Size = UDim2.new(1, 0, 0, ROUND)
			corner(row, 8)
			pad(row, 0, 10)
			row.Parent = chats
			row.Activated:Connect(function()
				chats.Visible = false
				task.spawn(function()
					self:openConversation(conversation.id)
				end)
			end)
		end
		popIn(chats)
	end)
end

-- Shows one of the dev's conversations: its prompts go in serve's chat, and the restore round rebuilds the transcript.
function Claude:openConversation(id: string)
	if id == self.conversationId then
		return
	end
	if self:running() or self.sending then
		return self:notify(errorText("busy"), COLORS.warn)
	end
	local ok, reply = self:request("POST", "/tt/claude/v1", { user = userId(), method = "GET", path = `/v1/conversations/{id}` })
	if not ok or type(reply) ~= "table" or type(reply.messages) ~= "table" then
		return self:notify(errorText(if ok then "Failed" else reply), COLORS.bad)
	end
	local ids = {}
	for _, stored in reply.messages do
		if type(stored.id) == "string" then
			table.insert(ids, stored.id)
			if type(stored.prompt) == "string" then
				self.promptTexts[stored.id] = stored.prompt
			end
		end
	end
	self:notify("")
	self.saving += 1
	self:request("POST", "/tt/claude/chat", { user = userId(), conversationId = id, prompts = ids })
	self.saving -= 1
	self.lastChatCheck = -math.huge
	self:restore()
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
					segment.line.Text = `{escapeRich(toolLine(segment.event))}  <font color="{hex(RESULT_DIM)}">{escapeRich(string.sub(stripEmoji(text), 1, 60))}</font>`
				else
					segment.problem.Text = string.sub(stripEmoji((string.gsub(string.sub(text, 7), "^%s+", ""))), 1, 140)
					segment.problem.Visible = true
				end
			end
		elseif kind == "deploy_proposal" then
			self:addProposalCard(message, event)
		elseif kind == "image" and type(event.image) == "table" then
			self:addImageBlock(message, event.image)
		elseif kind == "toolbox_results" and type(event.tiles) == "table" then
			self:addToolboxResults(message, event.tiles)
		elseif kind == "error" then
			self:addNote(message, errorText(event.text), COLORS.bad)
		elseif kind == "status" and event.state == nil then
			self:addNote(message, stripEmoji(event.text or ""), DIMMER)
		end
	end
	for _, segment in message.segments do
		if segment.kind == "text" and segment.dirty then
			segment.dirty = false
			syncBlocks(segment.holder, segment.rendered, parseMarkdown(stripEmoji(segment.text)))
		end
	end
end

-- Images ----------------------------------------------------------------------------------------------------------------

-- The dev-server's limits (framework claude-images.ts): at most 1024 px a side, 2.5 MB of zstd in at most 48 chunks.
local MAX_IMAGE_SIDE = 1024
local MAX_IMAGE_BYTES = 2.5 * 1024 * 1024
local MAX_IMAGE_CHUNKS = 48

local function imageMeta(raw): { id: string, width: number, height: number, bytes: number, chunks: number }?
	if type(raw) ~= "table" or type(raw.id) ~= "string" or not string.match(raw.id, "^[%w_-]+$") or #raw.id > 64 then
		return nil
	end
	for _, key in { "width", "height", "bytes", "chunks" } do
		if type(raw[key]) ~= "number" or raw[key] < 1 then
			return nil
		end
	end
	if raw.width > MAX_IMAGE_SIDE or raw.height > MAX_IMAGE_SIDE or raw.bytes > MAX_IMAGE_BYTES or raw.chunks > MAX_IMAGE_CHUNKS then
		return nil
	end
	return { id = raw.id, width = math.floor(raw.width), height = math.floor(raw.height), bytes = math.floor(raw.bytes), chunks = math.floor(raw.chunks) }
end

-- Fetches an image Claude showed (GET /v1/images/:id?chunk=n through serve, base64 chunks of zstd RGBA8) and draws it
-- into an EditableImage. Returns (true, image) or (false, error code). Pixels and base64 are never printed.
function Claude:fetchImage(meta): (boolean, any)
	local parts = {}
	local total = 0
	for index = 0, meta.chunks - 1 do
		local ok, reply = self:request("POST", "/tt/claude/v1", { user = userId(), method = "GET", path = `/v1/images/{meta.id}?chunk={index}` })
		if not ok then
			return false, if isNotFound(reply) then "image_gone" else reply
		end
		if type(reply) ~= "table" or reply.id ~= meta.id or reply.chunk ~= index or type(reply.data) ~= "string" or #reply.data > 120 * 1024 then
			return false, "image_data"
		end
		local decoded, bytes = pcall(EncodingService.Base64Decode, EncodingService, buffer.fromstring(reply.data))
		if not decoded then
			return false, "image_data"
		end
		total += buffer.len(bytes)
		if total > MAX_IMAGE_BYTES then
			return false, "image_data"
		end
		table.insert(parts, bytes)
	end
	local joined = buffer.create(total)
	local at = 0
	for _, part in parts do
		buffer.copy(joined, at, part)
		at += buffer.len(part)
	end
	local unpacked, pixels = pcall(EncodingService.DecompressBuffer, EncodingService, joined, Enum.CompressionAlgorithm.Zstd)
	if not unpacked or buffer.len(pixels) ~= meta.width * meta.height * 4 then
		return false, "image_data"
	end
	local created, image = pcall(AssetService.CreateEditableImage, AssetService, { Size = Vector2.new(meta.width, meta.height) })
	if not created or image == nil then
		return false, "image_api"
	end
	local written = pcall(image.WritePixelsBuffer, image, Vector2.zero, Vector2.new(meta.width, meta.height), pixels)
	if not written then
		image:Destroy()
		return false, "image_api"
	end
	return true, image
end

-- An image Claude showed: fetched and drawn, tap to see it large. When that isn't possible: one short dim line.
function Claude:addImageBlock(message, raw)
	local frame = autoFrame(message.reply, #message.segments + 1)
	table.insert(message.segments, { kind = "image", frame = frame })
	local meta = imageMeta(raw)
	if not meta then
		return self:addNote(message, errorText("image_data"), DIMMER)
	end
	local width = math.min(260, meta.width)
	local button = make("ImageButton", {
		AutoButtonColor = false,
		BackgroundColor3 = CODE_BG,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(width, math.max(1, math.floor(width * meta.height / meta.width))),
		ScaleType = Enum.ScaleType.Stretch,
	}, frame)
	corner(button, 8)
	local myView = self.view
	-- One image at a time (each is several requests).
	task.spawn(function()
		while self.fetchingImage do
			task.wait(0.2)
		end
		self.fetchingImage = true
		local ok, fetched, image = pcall(self.fetchImage, self, meta)
		self.fetchingImage = false
		fetched = ok and fetched
		if myView ~= self.view or button.Parent == nil then
			if fetched then
				image:Destroy()
			end
			return
		end
		local shown = fetched and pcall(function()
			button.ImageContent = Content.fromObject(image)
		end)
		if not shown then
			if fetched then
				image:Destroy()
			end
			button:Destroy()
			local line = label(errorText(if fetched then "image_api" elseif ok and type(image) == "string" then image else "image_gone"), DIMMER, SMALL, false)
			line.Parent = frame
			return
		end
		frame.Destroying:Connect(function()
			image:Destroy()
		end)
		button.Activated:Connect(function()
			self:showImage(image, meta.width / meta.height)
		end)
	end)
end

-- Big picture: the image fitted over the whole window; a tap anywhere closes it.
function Claude:showImage(image: EditableImage, aspect: number)
	local layer = make("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.15, Size = UDim2.fromScale(1, 1), ZIndex = 30 }, self.widget)
	layer.Activated:Connect(function()
		layer:Destroy()
	end)
	local picture = make("ImageLabel", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -24, 1, -24),
		ScaleType = Enum.ScaleType.Fit,
		ZIndex = 31,
	}, layer)
	make("UIAspectRatioConstraint", { AspectRatio = aspect }, picture)
	pcall(function()
		picture.ImageContent = Content.fromObject(image)
	end)
end

-- Toolbox search results (toolbox_results): a grid of up to 6 tiles, 2 columns in a narrow window, else 3. Tapping a
-- tile shows its type, id and numbers on a line below the grid (the id can be selected).
function Claude:addToolboxResults(message, tiles)
	if #tiles == 0 then
		return self:addNote(message, "No Toolbox results", DIMMER)
	end
	local frame = autoFrame(message.reply, #message.segments + 1)
	table.insert(message.segments, { kind = "toolbox", frame = frame })
	list(frame, 6)
	local grid = autoFrame(frame, 1)
	local layout = make("UIGridLayout", { SortOrder = Enum.SortOrder.LayoutOrder, CellPadding = UDim2.fromOffset(6, 6), CellSize = UDim2.new(1 / 3, -4, 0, 200) }, grid)
	make("UIAspectRatioConstraint", { AspectRatio = 0.66, DominantAxis = Enum.DominantAxis.Width }, layout)
	local columns = 0
	local function fitColumns()
		local wanted = if grid.AbsoluteSize.X > 0 and grid.AbsoluteSize.X < 380 then 2 else 3
		if wanted == columns then
			return
		end
		columns = wanted
		layout.CellSize = UDim2.new(1 / wanted, -math.ceil(6 * (wanted - 1) / wanted), 0, 200)
	end
	fitColumns()
	grid:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitColumns)
	-- A read-only box: the id can be selected and copied.
	local detail = style(make("TextBox", { BackgroundTransparency = 1, ClearTextOnFocus = false, TextEditable = false, LayoutOrder = 2, Visible = false }, frame), "", SMALL, DIMMER, FONT)
	detail.TextWrapped = true
	detail.Size = UDim2.fromScale(1, 0)
	detail.AutomaticSize = Enum.AutomaticSize.Y
	for index = 1, math.min(6, #tiles) do
		local tile = tiles[index]
		if type(tile) ~= "table" or type(tile.id) ~= "number" then
			continue
		end
		local cell = make("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = COLORS.row, BorderSizePixel = 0, ClipsDescendants = true, LayoutOrder = index }, grid)
		corner(cell, 8)
		pad(cell, 4, 4)
		list(cell, 2)
		local thumb = make("ImageLabel", { BackgroundColor3 = CODE_BG, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Image = toolboxThumb(tile.id), ScaleType = Enum.ScaleType.Fit, LayoutOrder = 1 }, cell)
		make("UIAspectRatioConstraint", { AspectRatio = 1, DominantAxis = Enum.DominantAxis.Width }, thumb)
		corner(thumb, 6)
		local function line(text: string, color: Color3, order: number, rich: boolean?)
			local result = style(make("TextLabel", { BackgroundTransparency = 1, RichText = rich == true, LayoutOrder = order }, cell), text, 13, color, FONT)
			result.TextWrapped = false
			result.TextTruncate = Enum.TextTruncate.AtEnd
			result.Size = UDim2.new(1, 0, 0, 15)
			return result
		end
		line(stripEmoji(tostring(tile.name or "")), COLORS.text, 2)
		local creator = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 15), LayoutOrder = 3 }, cell)
		make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 3) }, creator)
		if tile.verified then
			verifiedMark(creator, 1)
		end
		local who = style(make("TextLabel", { BackgroundTransparency = 1, LayoutOrder = 2 }, creator), stripEmoji(tostring(tile.creator or "")), 13, if tile.verified then COLORS.dim else COLORS.warn, FONT)
		who.TextWrapped = false
		who.TextTruncate = Enum.TextTruncate.AtEnd
		who.Size = UDim2.new(1, if tile.verified then -15 else 0, 1, 0)
		line(toolboxFacts(tile), DIMMER, 4, true)
		cell.Activated:Connect(function()
			local parts = { `{tile.type or "Asset"} {tile.id}` }
			if type(tile.triangles) == "number" then
				table.insert(parts, `{compactNumber(tile.triangles)} tris`)
			end
			if type(tile.voteCount) == "number" then
				table.insert(parts, `{compactNumber(tile.voteCount)} votes`)
			end
			if not tile.verified then
				table.insert(parts, "unverified")
			end
			detail.Text = table.concat(parts, " · ")
			detail.Visible = true
		end)
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
	message.copy.Visible = message.finished and self:replyText(message) ~= ""
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
	if reply.mode == "live" or reply.mode == "code" then
		message.modeTag.Text = reply.mode
	end
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
	-- The stream's state on the widget (attributes ClaudeStream, ClaudePushes), for checking it from Studio.
	self.widget:SetAttribute("ClaudeStream", "opening")
	local function lost()
		if stream.closed then
			return
		end
		stream.closed = true
		self.widget:SetAttribute("ClaudeStream", "closed")
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
		self.widget:SetAttribute("ClaudeStream", "ready")
		self.streamFailures = 0
		self:watchActive()
	elseif data.type == "prompt" then
		if not message or message.id ~= data.id then
			return
		end
		self.lastPush = os.clock()
		self.widget:SetAttribute("ClaudePushes", (self.widget:GetAttribute("ClaudePushes") or 0) + 1)
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
	self.paintMode()
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
	self.closeMenu()
	self.box.Text = ""
	local mode = self:currentMode()
	local attach = self.attach
	local toolbox = attach.toolbox
	-- The bubble and the working dots show at once; the message gets its id when serve answers.
	local message = self:addPending(prompt, mode)
	task.spawn(function()
		local body = { prompt = prompt, mode = mode, conversationId = self.conversationId, user = userId(), toolbox = if toolbox then true else nil }
		local context, logs = {}, {}
		if attach.path then
			-- "Dex path": the Studio selection, as "<realm> <full name>".
			local selected = Selection:Get()[1]
			if selected and selected ~= game then
				context.path = string.sub(`{realm()} {selected:GetFullName()}`, 1, 1024)
			end
		end
		if attach.myLogs then
			logs.client = Control.logHistory()
		end
		if attach.serverLogs and not RunService:IsEdit() then
			if Control.viaBridge then
				local ok, text = Control.serverLogs()
				logs.server = if ok and type(text) == "string" then text else nil
			else
				logs.server = Control.logHistory()
			end
		end
		if next(logs) then
			context.logs = logs
		end
		if next(context) then
			body.context = context
		end
		-- Screenshots: the dev-server picks each one up from the file Roblox wrote on its PC (by capture time).
		local shots = table.clone(self.shots)
		if #shots > 0 then
			local ids = {}
			for _, shot in shots do
				local attached, answer = self:request("POST", "/tt/claude/v1", { user = userId(), method = "POST", path = "/v1/attachments/capture", body = { captureTime = shot.captureTime, placeId = game.PlaceId } })
				if not attached or type(answer) ~= "table" or type(answer.id) ~= "string" then
					self.sending = false
					self:dropPending(message, prompt)
					return self:notify(errorText(if attached or isNotFound(answer) then "no_capture" else answer), COLORS.bad)
				end
				table.insert(ids, answer.id)
			end
			body.attachments = ids
		end
		local ok, reply = self:request("POST", "/tt/claude/prompt", body)
		local restarted = false
		if not ok and self.conversationId ~= nil and isNotFound(reply) then
			-- The dev machine forgot the chat (it restarted): start a new one with the same message.
			restarted = true
			self.conversationId = nil
			self:clearTranscript()
			message = self:addPending(prompt, mode)
			body.conversationId = nil
			ok, reply = self:request("POST", "/tt/claude/prompt", body)
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
		if self.conversationId then
			self.modes[self.conversationId] = mode
		end
		-- The Toolbox and the screenshots go with one message only.
		if toolbox and attach.toolbox then
			attach.toolbox = false
		end
		for _, shot in shots do
			local at = table.find(self.shots, shot)
			if at then
				table.remove(self.shots, at)
			end
		end
		self.paintToggles()
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

-- Screenshots ------------------------------------------------------------------------------------------------------

local MAX_SHOTS = 4

-- Takes a screenshot of the playtest view (the Play client only: the engine captures the game's viewport) for the next
-- message. The classic capture gives a temporary content id for the chip and this PC's clock for the dev-server.
function Claude:screenshot()
	if not RunService:IsClient() or RunService:IsEdit() then
		return self:notify(errorText("capture_client"), COLORS.warn)
	end
	if #self.shots >= MAX_SHOTS then
		return self:notify(`At most {MAX_SHOTS} screenshots`, COLORS.warn)
	end
	local camera = workspace.CurrentCamera
	local view = if camera then camera.ViewportSize else Vector2.new(16, 9)
	local aspect = if view.Y > 0 then math.clamp(view.X / view.Y, 0.5, 3) else 16 / 9
	task.spawn(function()
		local contentId
		local started = pcall(CaptureService.CaptureScreenshot, CaptureService, function(id)
			contentId = id
		end)
		local deadline = os.clock() + 6
		while started and contentId == nil and os.clock() < deadline do
			task.wait(0.05)
		end
		if type(contentId) ~= "string" then
			return self:notify(errorText("capture_failed"), COLORS.bad)
		end
		table.insert(self.shots, { contentId = contentId, captureTime = DateTime.now().UnixTimestampMillis, aspect = aspect })
		self:notify("")
		self.paintToggles()
	end)
end

-- A message being sent: shown at once, without an id until serve answers.
function Claude:addPending(prompt: string, mode: string)
	local message = self:buildMessage("", prompt, mode)
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
	self.chats.Visible = false
	self.conversationId = nil
	self.paintMode()
	self:clearTranscript()
	self:save()
	self:notify("")
end

return Claude
