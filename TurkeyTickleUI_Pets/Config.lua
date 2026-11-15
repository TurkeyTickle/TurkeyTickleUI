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
	ns:RefreshMap()
	ns:RefreshBrowser()
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

function ns:CreateOptions()
	local panel = CreateFrame("Frame")
	panel.name = "Pets"
	panel.parent = SUITE_NAME
	panel:Hide()

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText(SUITE_NAME .. ": Pets")

	local version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")
	local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	subtitle:SetText((version and ("v" .. version .. "  ") or "") .. "Type /ttpets to open the pet browser, /ttpets <name> to search.")

	local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	open:SetSize(160, 22)
	open:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -12)
	open:SetText("Open pet browser")
	open:SetScript("OnClick", function()
		ns:ShowBrowser()
	end)

	local checks = {
		createCheckbox(panel, "showTracked", "Show pinned beasts on the world map",
			"Beasts you pin from the browser (or shift-click on the map) get a green marker."),
		createCheckbox(panel, "showSpecial", "Show rare and special pets on the world map",
			"Petopia's unique rares, rares, unusual looks, elites and spawned pets, in purple."),
		createCheckbox(panel, "showTrainers", "Show pet trainers on the world map", "Gold markers."),
		createCheckbox(panel, "myFactionOnly", "Only my faction's pet trainers"),
		createCheckbox(panel, "tooltips", "Add pet info to beast tooltips",
			"Mouse over a beast to see which pet skill ranks it teaches and whether it's a rare look."),
	}
	local prev = open
	for i, cb in ipairs(checks) do
		cb:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", i == 1 and -2 or 0, i == 1 and -12 or -4)
		prev = cb
	end

	local size = createSlider(panel, "pinSize", "Map marker size", 10, 32, 1)
	size:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 4, -16)

	local credit = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	credit:SetPoint("TOPLEFT", size, "BOTTOMLEFT", 0, -20)
	credit:SetWidth(560)
	credit:SetJustifyH("LEFT")
	credit:SetText("Pet abilities, ranks, teachers, families and special pets: Petopia (wow-petopia.com/forever). "
		.. "Spawn coordinates and pet trainers: the Polestar addon's NPC data.")

	local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetSize(140, 22)
	reset:SetPoint("BOTTOMLEFT", 16, 16)
	reset:SetText(RESET_TO_DEFAULT or "Reset to defaults")
	reset:SetScript("OnClick", function()
		SlashCmdList.TURKEYTICKLEUI_PETS("reset")
		panel:GetScript("OnShow")()
	end)

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
