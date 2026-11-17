local ADDON, ns = ...

ns.defaults = {
	shown = true,
	locked = false,
	scale = 100,
	windowMinutes = 10,
	point = {},
}

ns.charDefaults = {
	session = false,
}

BINDING_HEADER_TURKEYTICKLEUI = BINDING_HEADER_TURKEYTICKLEUI or "Turkey Tickle UI"
BINDING_NAME_TURKEYTICKLEUI_XP_TOGGLE = "Toggle XP/hour window"

local function copyDefaults(dst, src)
	for k, v in pairs(src) do
		if dst[k] == nil then
			dst[k] = type(v) == "table" and {} or v
		end
	end
end

function ns:Print(msg)
	print("|cffe8a33dTurkey Tickle UI|r XP: " .. msg)
end

function ns:Changed()
	self:ApplySettings()
	self:Refresh()
end

function ns:Toggle()
	self.db.shown = not self.db.shown
	if self.db.shown and self:AtMaxLevel() then
		self:Print("You're at max level, so there's no XP to track.")
	end
	self:Refresh()
end

function ns:ResetSettings()
	local point = self.db.point
	wipe(self.db)
	copyDefaults(self.db, self.defaults)
	self.db.point = point
	self:Changed()
end

-- Events ---------------------------------------------------------------------------------

local driver = CreateFrame("Frame")
ns.driver = driver
ns.handlers = {}

function ns.handlers.ADDON_LOADED(name)
	if name ~= ADDON then
		return
	end
	TurkeyTickleUI_XPDB = TurkeyTickleUI_XPDB or {}
	copyDefaults(TurkeyTickleUI_XPDB, ns.defaults)
	ns.db = TurkeyTickleUI_XPDB
	TurkeyTickleUI_XPCharDB = TurkeyTickleUI_XPCharDB or {}
	copyDefaults(TurkeyTickleUI_XPCharDB, ns.charDefaults)
	ns.char = TurkeyTickleUI_XPCharDB
	ns:CreateOptions()
	driver:UnregisterEvent("ADDON_LOADED")
	ns:RegisterEvents()
end

function ns.handlers.PLAYER_ENTERING_WORLD(_, isReloadingUi)
	if ns.started then
		return
	end
	ns.started = true
	ns:StartSession(isReloadingUi)
	ns:CreateDisplay()
	ns:Changed()
	C_Timer.NewTicker(ns.SAMPLE_SECONDS, function()
		ns:Tick()
	end)
end

-- UnitLevel can lag behind these events, so read XP on the next frame.
local function xpChanged()
	C_Timer.After(0, function()
		ns:RecordXP()
		ns:Refresh()
	end)
end

function ns.handlers.PLAYER_XP_UPDATE(unit)
	if unit == nil or unit == "player" then
		xpChanged()
	end
end

ns.handlers.PLAYER_LEVEL_UP = xpChanged

driver:SetScript("OnEvent", function(_, event, ...)
	xpcall(ns.handlers[event], geterrorhandler(), ...)
end)

-- Every file has added its handlers by the time ADDON_LOADED fires.
function ns:RegisterEvents()
	for event in pairs(self.handlers) do
		if event ~= "ADDON_LOADED" then
			pcall(driver.RegisterEvent, driver, event)
		end
	end
end
driver:RegisterEvent("ADDON_LOADED")

SLASH_TURKEYTICKLEUI_XP1 = "/ttxp"
SlashCmdList.TURKEYTICKLEUI_XP = function(msg)
	msg = strtrim(msg or ""):lower()
	if msg == "options" or msg == "config" then
		ns:OpenOptions()
	elseif msg == "reset" then
		ns:ResetSession()
		ns:Print("Session reset.")
	elseif msg == "help" then
		ns:Print("/ttxp: show or hide the window. /ttxp reset: start a new session. /ttxp options: settings.")
	else
		ns:Toggle()
	end
end

function TurkeyTickleUI_XP_Toggle()
	ns:Toggle()
end

function TurkeyTickleUI_XP_OnAddonCompartmentClick()
	ns:Toggle()
end
