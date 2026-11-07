local ADDON, ns = ...

local HEALTH_TEXT_MODES = { "percent", "value", "both", "none" }
local HEALTH_TEXT_LABELS = {
	percent = "Percent",
	value = "Value",
	both = "Value + Percent",
	none = "Hidden",
}

local widgets = {}

local function onChanged()
	ns:RefreshAll()
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

local function createSlider(parent, key, label, minValue, maxValue, step)
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
		holder.label:SetFormattedText("%s: |cffffffff%d|r", label, value)
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

local function createHealthTextButton(parent)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(220, 44)

	holder.label = holder:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	holder.label:SetPoint("TOPLEFT")
	holder.label:SetText("Health text")

	local button = CreateFrame("Button", nil, holder, "UIPanelButtonTemplate")
	button:SetSize(160, 22)
	button:SetPoint("TOPLEFT", 0, -16)
	button:SetScript("OnClick", function()
		local current = 1
		for i, mode in ipairs(HEALTH_TEXT_MODES) do
			if mode == ns.db.healthText then
				current = i
			end
		end
		ns.db.healthText = HEALTH_TEXT_MODES[current % #HEALTH_TEXT_MODES + 1]
		holder:Refresh()
		onChanged()
	end)

	holder.Refresh = function()
		button:SetText(HEALTH_TEXT_LABELS[ns.db.healthText] or ns.db.healthText)
	end
	tinsert(widgets, holder)
	return holder
end

function ns:CreateOptions()
	local panel = CreateFrame("Frame")
	panel.name = "ForeverPlates"
	panel:Hide()

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("ForeverPlates")

	local version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")
	local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	subtitle:SetText((version and ("v" .. version .. "  ") or "") .. "Type /fp to open this panel, /fp tank to toggle tank mode.")

	local left = {
		createCheckbox(panel, "styleFriendly", "Style friendly nameplates",
			"Turn off to keep Blizzard's default look on friendly units."),
		createCheckbox(panel, "classColors", "Class colors for players"),
		createCheckbox(panel, "showLevel", "Show level and elite/rare tag"),
		createCheckbox(panel, "threatColors", "Threat colors",
			"Color enemy health bars by your threat: orange when you're close to pulling aggro, pink when you have it."),
		createCheckbox(panel, "tankMode", "Tank mode",
			"Invert threat colors: blue when you're holding aggro, orange when losing it, pink when something is on someone else."),
		createCheckbox(panel, "executeHighlight", "Execute range highlight",
			"Color enemies purple below the execute threshold. Disabled in tank mode."),
		createCheckbox(panel, "castBar", "Show cast bars"),
		createCheckbox(panel, "showDebuffs", "Show my debuffs on enemies"),
	}
	local prev
	for _, cb in ipairs(left) do
		if prev then
			cb:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -4)
		else
			cb:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", -2, -16)
		end
		prev = cb
	end

	local right = {
		createSlider(panel, "width", "Width", 60, 220, 2),
		createSlider(panel, "height", "Health height", 4, 30, 1),
		createSlider(panel, "castHeight", "Cast bar height", 4, 24, 1),
		createSlider(panel, "fontSize", "Font size", 7, 18, 1),
		createSlider(panel, "debuffSize", "Debuff icon size", 12, 36, 1),
		createSlider(panel, "maxDebuffs", "Max debuffs", 0, 10, 1),
		createSlider(panel, "executePercent", "Execute threshold %", 5, 50, 1),
		createHealthTextButton(panel),
	}
	prev = nil
	for _, widget in ipairs(right) do
		if prev then
			widget:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -6)
		else
			widget:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 300, -16)
		end
		prev = widget
	end

	local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetSize(140, 22)
	reset:SetPoint("BOTTOMLEFT", 16, 16)
	reset:SetText(RESET_TO_DEFAULT or "Reset to defaults")
	reset:SetScript("OnClick", function()
		SlashCmdList.FOREVERPLATES("reset")
		panel:GetScript("OnShow")()
	end)

	panel:SetScript("OnShow", function()
		for _, widget in ipairs(widgets) do
			widget:Refresh()
		end
	end)

	if Settings and Settings.RegisterCanvasLayoutCategory then
		local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
		Settings.RegisterAddOnCategory(category)
		self.optionsCategory = category
	elseif InterfaceOptions_AddCategory then
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
