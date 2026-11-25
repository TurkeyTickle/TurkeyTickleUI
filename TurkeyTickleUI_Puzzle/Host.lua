local ADDON, ns = ...

local CHANNEL_LABELS = { GUILD = "Guild", GROUP = "Party / raid" }
local LIST_ROWS = 6
local ROW_HEIGHT = 36
local LIST_REFRESH = 0.5 -- seconds between list updates while it's open
local LOOK_SECONDS = 6

local dialog

local function cleanCode(text)
	return (text or ""):gsub("%s", "")
end

local function refreshHost()
	local code = dialog.pasted or ""
	dialog.channel:SetText("Play with: " .. CHANNEL_LABELS[ns.db.channel])
	dialog.pieces.label:SetFormattedText("Pieces: |cffffffff%d|r", ns.db.pieces)
	dialog.start:Disable()
	if code == "" then
		dialog.info:SetText("Paste an image code, or use the sample picture.")
		return
	end
	local decoder = ns:NewDecoder()
	local ok, err = decoder:Feed(code)
	if not ok then
		dialog.info:SetText("|cffff5050" .. err .. "|r")
		return
	elseif not decoder:IsComplete() then
		dialog.info:SetText("|cffff5050The code is cut off. Copy the whole thing.|r")
		return
	end
	local cols, rows = ns:PiecesGrid(decoder.w, decoder.h, ns.db.pieces)
	dialog.info:SetFormattedText("%d x %d picture, %d colors. %d pieces (%d x %d). Sends in about %s.",
		decoder.w, decoder.h, decoder.colors, cols * rows, cols, rows, ns:FormatDuration(ns:EstimateSendSeconds(#code)))
	dialog.start:Enable()
end

-- Puzzle list ---------------------------------------------------------------------

-- Puzzles we can play, newest first, then ones that need a newer addon.
local function listEntries()
	local entries = {}
	for _, session in pairs(ns.sessions) do
		entries[#entries + 1] = session
	end
	table.sort(entries, function(a, b)
		return a.created > b.created
	end)
	for _, info in pairs(ns.blocked) do
		entries[#entries + 1] = { blocked = info }
	end
	return entries
end

local function fillRow(row, entry)
	local info = entry.blocked
	if info then
		row.session = nil
		row.title:SetText(info.title)
		row.detail:SetText(ns:ShortName(info.master))
		row.state:SetFormattedText("|cffff5050needs version %s|r", info.release)
		row.join:SetText("Join")
		row.join:Disable()
		return
	end
	local session = entry
	row.session = session
	row.title:SetText(session.title or "?")
	local pieces = session.pieces and #session.pieces or 0
	row.detail:SetFormattedText("%s |cff9d9d9d- %s, %d pieces%s|r", ns:ShortName(session.master),
		session.channel == "G" and "guild" or "party", pieces, session.rotate and ", piece rotation" or "")
	row.state:SetText(ns:SessionState(session))
	row.join:SetText((session == ns.active or session.isMaster) and "Open" or "Join")
	row.join:Enable()
end

local function refreshList()
	local entries = listEntries()
	for i, row in ipairs(dialog.rows) do
		local entry = entries[i]
		row:SetShown(entry ~= nil)
		if entry then
			fillRow(row, entry)
		end
	end
	dialog.more:SetShown(#entries > LIST_ROWS)
	dialog.more:SetFormattedText("And %d more. Type /ttpz status to see them all.", #entries - LIST_ROWS)
	dialog.empty:SetShown(#entries == 0)
	if not dialog.canLook then
		dialog.empty:SetText("You're not in a guild or party.\n\nHost a puzzle to play alone; anyone who joins your party "
			.. "can play along.")
	elseif GetTime() < dialog.lookingUntil then
		dialog.empty:SetText("Looking for puzzles in your guild and party...")
	else
		dialog.empty:SetText("No puzzles in your guild or party right now.\n\nHost one and everyone can play along!")
	end
end

local function lookForPuzzles()
	dialog.canLook = ns:LookForPuzzles()
	dialog.lookingUntil = GetTime() + LOOK_SECONDS
end

local function createRow(parent, index)
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(420, ROW_HEIGHT - 2)
	row:SetPoint("TOPLEFT", 20, -66 - (index - 1) * ROW_HEIGHT)
	local bg = row:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, index % 2 == 1 and 0.06 or 0.03)

	row.join = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.join:SetSize(70, 22)
	row.join:SetPoint("RIGHT", -6, 0)
	row.join:SetScript("OnClick", function()
		if row.session then
			ns:JoinSession(row.session)
			dialog:Hide()
		end
	end)

	row.title = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	row.title:SetPoint("TOPLEFT", 8, -4)
	row.title:SetWidth(210)
	row.title:SetJustifyH("LEFT")
	row.title:SetWordWrap(false)
	row.detail = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.detail:SetPoint("BOTTOMLEFT", 8, 4)
	row.detail:SetWidth(240)
	row.detail:SetJustifyH("LEFT")
	row.detail:SetWordWrap(false)
	row.state = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.state:SetPoint("RIGHT", row.join, "LEFT", -8, 0)
	row.state:SetJustifyH("RIGHT")
	return row
end

local function createListView()
	local view = CreateFrame("Frame", nil, dialog)
	view:SetAllPoints()
	dialog.listView = view

	local heading = view:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	heading:SetPoint("TOPLEFT", 66, -36)
	heading:SetText("Puzzles in your guild and party")

	dialog.rows = {}
	for i = 1, LIST_ROWS do
		dialog.rows[i] = createRow(view, i)
	end
	local more = view:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	more:SetPoint("TOPLEFT", dialog.rows[LIST_ROWS], "BOTTOMLEFT", 8, -4)
	dialog.more = more

	local empty = view:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	empty:SetPoint("TOP", 0, -120)
	empty:SetWidth(360)
	dialog.empty = empty

	local refresh = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
	refresh:SetSize(100, 24)
	refresh:SetPoint("BOTTOMLEFT", 16, 16)
	refresh:SetText("Refresh")
	refresh:SetScript("OnClick", function()
		lookForPuzzles()
		refreshList()
	end)

	local host = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
	host:SetSize(140, 24)
	host:SetPoint("BOTTOMRIGHT", -16, 16)
	host:SetText("Host a puzzle")
	host:SetScript("OnClick", function()
		ns:ShowHost()
	end)

	-- Nothing reports every change worth showing (send progress, for one), so check back while open.
	local elapsed = 0
	view:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed >= LIST_REFRESH then
			elapsed = 0
			refreshList()
		end
	end)
end

-- Host form -----------------------------------------------------------------------

local function createHostView()
	local view = CreateFrame("Frame", nil, dialog)
	view:SetAllPoints()
	dialog.hostView = view

	local nameLabel = view:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	nameLabel:SetPoint("TOPLEFT", 66, -36)
	nameLabel:SetText("Puzzle name")
	local name = CreateFrame("EditBox", nil, view, "InputBoxTemplate")
	name:SetSize(240, 20)
	name:SetPoint("LEFT", nameLabel, "RIGHT", 12, 0)
	name:SetAutoFocus(false)
	name:SetMaxLetters(40)
	dialog.name = name

	local help = view:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	help:SetPoint("TOPLEFT", 20, -70)
	help:SetWidth(420)
	help:SetJustifyH("LEFT")
	help:SetText("Turn an image into a code with |cffffd100ttpz <url or file>|r (it copies the "
		.. "code to your clipboard), then paste it below with Ctrl+V.")

	-- Codes run to tens of thousands of characters, which a WoW edit box is slow to hold, so the
	-- box only catches the paste and hands it over on the next frame.
	local code = CreateFrame("EditBox", nil, view, "InputBoxTemplate")
	code:SetSize(400, 22)
	code:SetPoint("TOPLEFT", 28, -112)
	code:SetAutoFocus(false)
	code:SetMaxLetters(0)
	code:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			self:SetScript("OnUpdate", function()
				self:SetScript("OnUpdate", nil)
				dialog.pasted = cleanCode(self:GetText())
				self:SetText("")
				self:ClearFocus()
				refreshHost()
			end)
		end
	end)
	code.hint = code:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	code.hint:SetPoint("LEFT", 2, 0)
	code.hint:SetText("Click here and press Ctrl+V")
	code:SetScript("OnEditFocusGained", function()
		code.hint:Hide()
	end)
	code:SetScript("OnEditFocusLost", function()
		code.hint:Show()
	end)
	dialog.code = code

	local sample = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
	sample:SetSize(160, 22)
	sample:SetPoint("TOPLEFT", code, "BOTTOMLEFT", -6, -10)
	sample:SetText("Use sample picture")
	sample:SetScript("OnClick", function()
		dialog.pasted = ns:SampleCode()
		if name:GetText() == "" then
			name:SetText("Sunset Meadow")
		end
		refreshHost()
	end)
	local clear = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
	clear:SetSize(80, 22)
	clear:SetPoint("LEFT", sample, "RIGHT", 4, 0)
	clear:SetText("Clear")
	clear:SetScript("OnClick", function()
		dialog.pasted = ""
		refreshHost()
	end)

	local pieces = CreateFrame("Slider", nil, view, "BackdropTemplate")
	pieces:SetOrientation("HORIZONTAL")
	pieces:SetSize(200, 16)
	pieces:SetPoint("TOPLEFT", sample, "BOTTOMLEFT", 4, -34)
	pieces:SetBackdrop({
		bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
		edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
		tile = true,
		tileSize = 8,
		edgeSize = 8,
		insets = { left = 3, right = 3, top = 6, bottom = 6 },
	})
	pieces:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	pieces:SetMinMaxValues(4, 100)
	pieces:SetValueStep(2)
	pieces:SetObeyStepOnDrag(true)
	pieces.label = pieces:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	pieces.label:SetPoint("BOTTOMLEFT", pieces, "TOPLEFT", 0, 4)
	pieces:SetScript("OnValueChanged", function(_, value, userInput)
		if userInput then
			ns.db.pieces = math.floor(value / 2 + 0.5) * 2
			refreshHost()
		end
	end)
	dialog.pieces = pieces

	local channel = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
	channel:SetSize(170, 22)
	channel:SetPoint("LEFT", pieces, "RIGHT", 30, 0)
	channel:SetScript("OnClick", function()
		ns.db.channel = ns.db.channel == "GUILD" and "GROUP" or "GUILD"
		refreshHost()
	end)
	dialog.channel = channel

	local info = view:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	info:SetPoint("TOPLEFT", pieces, "BOTTOMLEFT", 0, -18)
	info:SetWidth(410)
	info:SetJustifyH("LEFT")
	dialog.info = info

	local ghost = CreateFrame("CheckButton", nil, view, "UICheckButtonTemplate")
	ghost:SetSize(24, 24)
	ghost:SetPoint("BOTTOMLEFT", 16, 16)
	ghost.label = ghost:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	ghost.label:SetPoint("LEFT", ghost, "RIGHT", 2, 1)
	ghost.label:SetText("Show the picture under the pieces")
	ghost:SetScript("OnClick", function(self)
		ns.db.hostGhost = self:GetChecked() and true or false
	end)
	dialog.ghost = ghost

	local rotate = CreateFrame("CheckButton", nil, view, "UICheckButtonTemplate")
	rotate:SetSize(24, 24)
	rotate:SetPoint("BOTTOMLEFT", ghost, "TOPLEFT", 0, 0)
	rotate:SetHitRectInsets(0, -90, 0, 0)
	rotate.label = rotate:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	rotate.label:SetPoint("LEFT", rotate, "RIGHT", 2, 1)
	rotate.label:SetText("Piece rotation")
	rotate:SetScript("OnClick", function(self)
		ns.db.hostRotate = self:GetChecked() and true or false
	end)
	rotate:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Piece rotation")
		GameTooltip:AddLine("Pieces start turned at random. Scroll the mouse wheel while dragging a piece to turn "
			.. "it upright.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	rotate:SetScript("OnLeave", GameTooltip_Hide)
	dialog.rotate = rotate

	local start = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
	start:SetSize(140, 24)
	start:SetPoint("BOTTOMRIGHT", -16, 16)
	start:SetText("Start puzzle")
	function dialog.Start(alone)
		local ok, err, reason = ns:HostSession(dialog.pasted, strtrim(name:GetText()), ns.db.pieces, ns.db.channel,
			ns.db.hostGhost, ns.db.hostRotate, alone)
		if ok then
			dialog.pasted = ""
			name:SetText("")
			dialog:Hide()
		elseif reason == "noGroup" then
			StaticPopup_Show("TURKEYTICKLEUI_PUZZLE_ALONE")
		else
			info:SetText("|cffff5050" .. err .. "|r")
		end
	end
	start:SetScript("OnClick", function()
		dialog.Start(false)
	end)
	dialog.start = start

	local back = CreateFrame("Button", nil, view, "UIPanelButtonTemplate")
	back:SetSize(80, 24)
	back:SetPoint("RIGHT", start, "LEFT", -4, 0)
	back:SetText("Back")
	back:SetScript("OnClick", function()
		ns:ShowPuzzles()
	end)
end

local function createDialog()
	dialog = CreateFrame("Frame", "TurkeyTickleUIPuzzleHost", UIParent, "PortraitFrameTemplate")
	if not ns:GamepadUI() then
		tinsert(UISpecialFrames, "TurkeyTickleUIPuzzleHost")
	end
	dialog:SetSize(460, 344)
	dialog:SetPoint("CENTER")
	dialog:SetFrameStrata("DIALOG")
	dialog:SetToplevel(true)
	dialog:SetClampedToScreen(true)
	dialog:SetMovable(true)
	dialog:EnableMouse(true)
	dialog:RegisterForDrag("LeftButton")
	dialog:SetScript("OnDragStart", dialog.StartMoving)
	dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
	if dialog.SetPortraitToAsset then
		dialog:SetPortraitToAsset(ns.ICON)
	elseif dialog.GetPortrait and dialog:GetPortrait() then
		dialog:GetPortrait():SetTexture(ns.ICON)
	end
	dialog.lookingUntil = 0
	createListView()
	createHostView()
end

local function showView(view, title)
	dialog.listView:SetShown(view == dialog.listView)
	dialog.hostView:SetShown(view == dialog.hostView)
	if dialog.SetTitle then
		dialog:SetTitle(title)
	end
	dialog:Show()
end

StaticPopupDialogs.TURKEYTICKLEUI_PUZZLE_ALONE = {
	text = "You're not in a party or raid.\n\nPuzzle alone? Anyone who joins your party later can play along.",
	button1 = "Puzzle alone",
	button2 = "Cancel",
	OnAccept = function()
		if dialog and dialog:IsShown() then
			dialog.Start(true)
		end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- Lists the puzzles in progress, asking around for any we haven't heard about; they show up as
-- hosts answer.
function ns:ShowPuzzles()
	if not dialog then
		createDialog()
	end
	lookForPuzzles()
	refreshList()
	showView(dialog.listView, "Jigsaw Puzzles")
end

function ns:ShowHost()
	if not dialog then
		createDialog()
	end
	dialog.pieces:SetValue(self.db.pieces)
	dialog.ghost:SetChecked(self.db.hostGhost)
	dialog.rotate:SetChecked(self.db.hostRotate)
	refreshHost()
	showView(dialog.hostView, "Host a Jigsaw Puzzle")
end
