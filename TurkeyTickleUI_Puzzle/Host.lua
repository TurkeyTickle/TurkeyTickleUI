local ADDON, ns = ...

local CHANNEL_LABELS = { GUILD = "Guild", GROUP = "Party / raid" }

local dialog

local function cleanCode(text)
	return (text or ""):gsub("%s", "")
end

local function refresh()
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
	if dialog.SetTitle then
		dialog:SetTitle("Host a Jigsaw Puzzle")
	end
	if dialog.SetPortraitToAsset then
		dialog:SetPortraitToAsset(ns.ICON)
	elseif dialog.GetPortrait and dialog:GetPortrait() then
		dialog:GetPortrait():SetTexture(ns.ICON)
	end

	local nameLabel = dialog:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	nameLabel:SetPoint("TOPLEFT", 66, -36)
	nameLabel:SetText("Puzzle name")
	local name = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
	name:SetSize(240, 20)
	name:SetPoint("LEFT", nameLabel, "RIGHT", 12, 0)
	name:SetAutoFocus(false)
	name:SetMaxLetters(40)
	dialog.name = name

	local help = dialog:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	help:SetPoint("TOPLEFT", 20, -70)
	help:SetWidth(420)
	help:SetJustifyH("LEFT")
	help:SetText("Turn an image into a code with |cffffd100ttpz <url or file>|r (it copies the "
		.. "code to your clipboard), then paste it below with Ctrl+V.")

	-- Codes run to tens of thousands of characters, which a WoW edit box is slow to hold, so the
	-- box only catches the paste and hands it over on the next frame.
	local code = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
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
				refresh()
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

	local sample = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
	sample:SetSize(160, 22)
	sample:SetPoint("TOPLEFT", code, "BOTTOMLEFT", -6, -10)
	sample:SetText("Use sample picture")
	sample:SetScript("OnClick", function()
		dialog.pasted = ns:SampleCode()
		if name:GetText() == "" then
			name:SetText("Sunset Meadow")
		end
		refresh()
	end)
	local clear = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
	clear:SetSize(80, 22)
	clear:SetPoint("LEFT", sample, "RIGHT", 4, 0)
	clear:SetText("Clear")
	clear:SetScript("OnClick", function()
		dialog.pasted = ""
		refresh()
	end)

	local pieces = CreateFrame("Slider", nil, dialog, "BackdropTemplate")
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
			refresh()
		end
	end)
	dialog.pieces = pieces

	local channel = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
	channel:SetSize(170, 22)
	channel:SetPoint("LEFT", pieces, "RIGHT", 30, 0)
	channel:SetScript("OnClick", function()
		ns.db.channel = ns.db.channel == "GUILD" and "GROUP" or "GUILD"
		refresh()
	end)
	dialog.channel = channel

	local info = dialog:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	info:SetPoint("TOPLEFT", pieces, "BOTTOMLEFT", 0, -18)
	info:SetWidth(410)
	info:SetJustifyH("LEFT")
	dialog.info = info

	local ghost = CreateFrame("CheckButton", nil, dialog, "UICheckButtonTemplate")
	ghost:SetSize(24, 24)
	ghost:SetPoint("BOTTOMLEFT", 16, 16)
	ghost.label = ghost:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	ghost.label:SetPoint("LEFT", ghost, "RIGHT", 2, 1)
	ghost.label:SetText("Show the picture under the pieces")
	ghost:SetScript("OnClick", function(self)
		ns.db.hostGhost = self:GetChecked() and true or false
	end)
	dialog.ghost = ghost

	local rotate = CreateFrame("CheckButton", nil, dialog, "UICheckButtonTemplate")
	rotate:SetSize(24, 24)
	rotate:SetPoint("BOTTOMLEFT", ghost, "TOPLEFT", 0, 0)
	rotate.label = rotate:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	rotate.label:SetPoint("LEFT", rotate, "RIGHT", 2, 1)
	rotate.label:SetText("Pieces start turned (scroll while dragging to turn one)")
	rotate:SetScript("OnClick", function(self)
		ns.db.hostRotate = self:GetChecked() and true or false
	end)
	dialog.rotate = rotate

	local start = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
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

function ns:ShowHost()
	if not dialog then
		createDialog()
	end
	dialog.pieces:SetValue(self.db.pieces)
	dialog.ghost:SetChecked(self.db.hostGhost)
	dialog.rotate:SetChecked(self.db.hostRotate)
	refresh()
	dialog:Show()
end
