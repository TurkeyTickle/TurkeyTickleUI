local ADDON, ns = ...

local widgets = {}

local SUITE_NAME = "Turkey Tickle UI"

-- Every Turkey Tickle UI addon hangs its options page under one shared settings category.
TurkeyTickleUI = TurkeyTickleUI or {}

local function getSuiteCategory()
	local suite = TurkeyTickleUI
	if suite.settingsCategory or suite.settingsPanel then
		return suite.settingsCategory
	end

	local panel = CreateFrame("Frame")
	panel.name = SUITE_NAME
	panel:Hide()
	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText(SUITE_NAME)
	local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	hint:SetText("Pick a module from the list on the left.")
	suite.settingsPanel = panel

	if Settings and Settings.RegisterCanvasLayoutCategory then
		suite.settingsCategory = Settings.RegisterCanvasLayoutCategory(panel, SUITE_NAME)
		Settings.RegisterAddOnCategory(suite.settingsCategory)
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(panel)
	end
	return suite.settingsCategory
end

local function onChanged()
	ns:Changed()
end

local function createCheckbox(parent, key, label, tooltip)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetSize(26, 26)
	cb.label = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	cb.label:SetPoint("LEFT", cb, "RIGHT", 4, 1)
	cb.label:SetText(label)
	cb:SetScript("OnClick", function(self)
		ns.db[key] = self:GetChecked() and true or false
		onChanged()
	end)
	if tooltip then
		cb:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(label, 1, 1, 1)
			GameTooltip:AddLine(tooltip, nil, nil, nil, true)
			GameTooltip:Show()
		end)
		cb:SetScript("OnLeave", GameTooltip_Hide)
	end
	cb.Refresh = function(self)
		self:SetChecked(ns.db[key])
	end
	tinsert(widgets, cb)
	return cb
end

local function createSlider(parent, key, label, minValue, maxValue, step, suffix)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(220, 40)

	holder.label = holder:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	holder.label:SetPoint("TOPLEFT")

	local slider = CreateFrame("Slider", nil, holder, "BackdropTemplate")
	slider:SetOrientation("HORIZONTAL")
	slider:SetSize(200, 16)
	slider:SetPoint("TOPLEFT", 0, -18)
	slider:SetBackdrop({
		bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
		edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
		tile = true,
		tileSize = 8,
		edgeSize = 8,
		insets = { left = 3, right = 3, top = 6, bottom = 6 },
	})
	slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	slider:SetMinMaxValues(minValue, maxValue)
	slider:SetValueStep(step)
	slider:SetObeyStepOnDrag(true)

	local function setLabel(value)
		holder.label:SetFormattedText("%s: |cffffffff%d%s|r", label, value, suffix or "")
	end

	slider:SetScript("OnValueChanged", function(_, value, userInput)
		value = math.floor(value / step + 0.5) * step
		setLabel(value)
		if userInput and ns.db[key] ~= value then
			ns.db[key] = value
			onChanged()
		end
	end)

	holder.Refresh = function()
		slider:SetValue(ns.db[key])
		setLabel(ns.db[key])
	end
	tinsert(widgets, holder)
	return holder
end

local function createButton(parent, width, text, onClick)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width, 22)
	button:SetText(text)
	button:SetScript("OnClick", onClick)
	return button
end

function ns:CreateOptions()
	local panel = CreateFrame("Frame")
	panel.name = "XP"
	panel.parent = SUITE_NAME
	panel:Hide()

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText(SUITE_NAME .. ": XP")

	local version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")
	if version and version:find("@", 1, true) then
		version = "dev" -- releases stamp the TOC's version; a copy from the repository has the placeholder
	end
	local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	subtitle:SetText((version and ("v" .. version .. "  ") or "")
		.. "Type /ttxp to show or hide the window, or set a key under Key Bindings > AddOns.")

	local resetSession = createButton(panel, 140, "Reset session", function()
		ns:ResetSession()
	end)
	resetSession:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -12)
	local resetPosition = createButton(panel, 160, "Reset window position", function()
		ns:ResetPosition()
	end)
	resetPosition:SetPoint("LEFT", resetSession, "RIGHT", 8, 0)

	local checks = {
		createCheckbox(panel, "shown", "Show the XP/hour window"),
		createCheckbox(panel, "locked", "Lock window position", "Stops the window moving when you drag it."),
	}
	local prev = resetSession
	for i, cb in ipairs(checks) do
		cb:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", i == 1 and -2 or 0, i == 1 and -12 or -4)
		prev = cb
	end

	local scale = createSlider(panel, "scale", "Window scale", 50, 200, 10, "%")
	scale:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 4, -16)
	local window = createSlider(panel, "windowMinutes", "Rate over the last", 5, 30, 5, " min")
	window:SetPoint("LEFT", scale, "RIGHT", 60, 0)

	local reset = createButton(panel, 140, RESET_TO_DEFAULT or "Reset to defaults", function()
		ns:ResetSettings()
		panel:GetScript("OnShow")()
	end)
	reset:SetPoint("BOTTOMLEFT", 16, 16)

	panel:SetScript("OnShow", function()
		for _, widget in ipairs(widgets) do
			widget:Refresh()
		end
	end)

	if Settings and Settings.RegisterCanvasLayoutSubcategory then
		self.optionsCategory = Settings.RegisterCanvasLayoutSubcategory(getSuiteCategory(), panel, panel.name)
	elseif InterfaceOptions_AddCategory then
		getSuiteCategory()
		InterfaceOptions_AddCategory(panel)
	end
	self.optionsPanel = panel
end

function ns:OpenOptions()
	if self.optionsCategory then
		Settings.OpenToCategory(self.optionsCategory:GetID())
	elseif InterfaceOptionsFrame_OpenToCategory then
		InterfaceOptionsFrame_OpenToCategory(self.optionsPanel)
		InterfaceOptionsFrame_OpenToCategory(self.optionsPanel)
	end
end
