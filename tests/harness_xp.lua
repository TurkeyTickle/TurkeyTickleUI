-- Loads TurkeyTickleUI_XP in a stubbed WoW environment and drives a levelling session:
--   luajit tests/harness_xp.lua TurkeyTickleUI_XP
local function stub()
	local s = {}
	return setmetatable(s, {
		__index = function(t, k)
			if type(k) ~= "string" or not k:match("^%u") then return nil end
			local f = function(self, _, _, template)
				if k == "GetFont" then return "font", 10 end
				if k == "GetFrameLevel" or k == "GetWidth" or k == "GetHeight" then return 100 end
				if k == "IsShown" then return false end
				if k == "GetID" then return 1 end
				if k == "GetPoint" then return "CENTER", nil, "CENTER", 10, 20 end
				if k == "CreateFontString" then
					local fs = stub()
					local hasFont = template ~= nil
					local text
					fs.SetFont = function() hasFont = true end
					fs.SetFontObject = function() hasFont = true end
					fs.SetText = function(_, t) if not hasFont then error("FontString: Font not set", 2) end text = t end
					fs.SetFormattedText = function(_, f, ...) if not hasFont then error("FontString: Font not set", 2) end text = format(f, ...) end
					fs.GetText = function() return text end
					return fs
				end
				return stub()
			end
			rawset(t, k, f)
			return f
		end,
	})
end

local function newFrame()
	local f = stub()
	local scripts, shown = {}, false
	f.SetScript = function(self, k, fn) scripts[k] = fn end
	f.HookScript = function(self, k, fn) scripts[k] = fn end
	f.GetScript = function(self, k) return scripts[k] or function() end end
	f.Show = function(self) shown = true if scripts.OnShow then scripts.OnShow(self) end end
	f.Hide = function() shown = false end
	f.SetShown = function(self, v) if v then self:Show() else self:Hide() end end
	f.IsShown = function() return shown end
	f.scripts = scripts
	return f
end

function CreateFrame(kind, name)
	local f = newFrame()
	if name then _G[name] = f end
	return f
end
function geterrorhandler() return function(e) print("LUA ERROR: " .. tostring(e)) print(debug.traceback()) os.exit(1) end end
strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
tinsert = table.insert
tremove = table.remove
format = string.format
SlashCmdList = {}
GameTooltip = stub()
GameTooltip_Hide = function() end
local tickers = {}
C_Timer = {
	After = function(_, fn) fn() end,
	NewTicker = function(_, fn) tinsert(tickers, fn) return stub() end,
}
C_AddOns = { GetAddOnMetadata = function() return "0.1.0" end }
Settings = {
	RegisterCanvasLayoutCategory = function() return stub() end,
	RegisterCanvasLayoutSubcategory = function() return stub() end,
	RegisterAddOnCategory = function() end,
	OpenToCategory = function() end,
}
UIParent = newFrame()

local now = 5000
function GetTime() return now end
local player = { xp = 1000, max = 100000, level = 14, maxLevel = false }
function UnitXP() return player.xp end
function UnitXPMax() return player.max end
function UnitLevel() return player.level end
function IsPlayerAtEffectiveMaxLevel() return player.maxLevel end

-- Load the addon in TOC order.
local dir = arg[1]
local ns = {}
for line in io.lines(dir .. "/" .. dir .. ".toc") do
	local file = line:match("^([^#%s].-)%s*$")
	if file and file:match("%.lua$") then
		local chunk = assert(loadfile(dir .. "/" .. file:gsub("\\", "/")))
		chunk(dir, ns)
	end
end

local function fire(event, ...) ns.driver.scripts.OnEvent(ns.driver, event, ...) end
local function near(a, b, what)
	assert(a and math.abs(a - b) <= math.abs(b) * 0.02 + 1, format("%s: got %s, want about %s", what, tostring(a), tostring(b)))
end

fire("ADDON_LOADED", dir)
fire("PLAYER_ENTERING_WORLD", true, false)
assert(ns.frame and ns.frame:IsShown(), "window shown at login")
assert(#tickers == 1, "sample ticker started")
assert(ns:RecentRate() == nil and ns:AverageRate() == nil, "no rate in the first minute")

-- Earn `perMinute` XP for `minutes`, an XP event and a sample every 30 seconds.
local function play(minutes, perMinute)
	for _ = 1, minutes * 2 do
		now = now + 30
		player.xp = player.xp + perMinute / 2
		fire("PLAYER_XP_UPDATE", "player")
		tickers[1]()
	end
end

play(20, 1000)
near(ns:RecentRate(), 60000, "steady recent rate")
near(ns:AverageRate(), 60000, "steady average")
assert(ns:Trend() == "flat", "steady pace is flat, got " .. tostring(ns:Trend()))
print("steady:", ns.frame.rate:GetText(), "|", ns.frame.detail:GetText())

play(10, 2000)
near(ns:RecentRate(), 120000, "faster recent rate")
near(ns:AverageRate(), 80000, "average over 30 minutes")
assert(ns:Trend() == "up", "faster pace trends up, got " .. tostring(ns:Trend()))

play(10, 500)
near(ns:RecentRate(), 30000, "slower recent rate")
assert(ns:Trend() == "down", "slower pace trends down, got " .. tostring(ns:Trend()))
print("slower:", ns.frame.rate:GetText(), "|", ns.frame.detail:GetText())

-- Time to level comes from the recent rate.
local remaining = player.max - player.xp
near(ns:TimeToLevel(), remaining / 30000 * 3600, "time to level")

local points = ns:SparkPoints()
assert(#points >= 60, "about an hour of sparkline points, got " .. #points)

-- Level up: the rest of the old level plus XP into the new one.
player.xp = 99000
fire("PLAYER_XP_UPDATE", "player")
local before = ns.session.gained
player.level, player.xp, player.max = 15, 1500, 110000
fire("PLAYER_LEVEL_UP", 15)
assert(ns.session.gained == before + 1000 + 1500, "level-up counted, got " .. (ns.session.gained - before))

-- XP wraps before UnitLevel catches up: counted once, not again when the level updates.
before = ns.session.gained
player.xp = 109000
fire("PLAYER_XP_UPDATE", "player")
before = ns.session.gained
player.xp, player.max = 500, 120000
fire("PLAYER_XP_UPDATE", "player")
assert(ns.session.gained == before + 1000 + 500, "wrap counted")
player.level = 16
fire("PLAYER_LEVEL_UP", 16)
assert(ns.session.gained == before + 1000 + 500, "late level update not counted twice")

-- A /reload keeps the session; a fresh login starts over.
local gained = ns.session.gained
ns:StartSession(true)
assert(ns.session.gained == gained, "reload keeps the session")
ns:StartSession(false)
assert(ns.session.gained == 0, "login starts a new session")

-- Hide/show and reset.
SlashCmdList.TURKEYTICKLEUI_XP("")
assert(not ns.frame:IsShown() and not ns.db.shown, "/ttxp hides")
TurkeyTickleUI_XP_Toggle()
assert(ns.frame:IsShown() and ns.db.shown, "binding shows")
TurkeyTickleUI_XP_OnAddonCompartmentClick()
assert(not ns.frame:IsShown(), "compartment hides")
TurkeyTickleUI_XP_OnAddonCompartmentClick()
play(5, 1000)
SlashCmdList.TURKEYTICKLEUI_XP("reset")
assert(ns.session.gained == 0, "/ttxp reset")
ns.frame.scripts.OnMouseUp(ns.frame, "RightButton")
ns.frame.scripts.OnEnter(ns.frame)
SlashCmdList.TURKEYTICKLEUI_XP("help")
SlashCmdList.TURKEYTICKLEUI_XP("options")

-- Options page.
ns.optionsPanel.scripts.OnShow()
ns.db.windowMinutes = 5
ns:Changed()

-- Max level hides the window.
player.maxLevel = true
fire("PLAYER_XP_UPDATE", "player")
assert(not ns.frame:IsShown(), "hidden at max level")
print("done")
