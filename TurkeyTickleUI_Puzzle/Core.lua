local ADDON, ns = ...

ns.defaults = {
	scale = 100,
	prompt = true,
	hostGhost = false, -- the picture under the pieces, for puzzles we host
	hostRotate = false, -- pieces start turned, for puzzles we host
	sounds = true,
	pieces = 24,
	channel = "GUILD", -- "GUILD" or "GROUP"
	minimap = true,
	minimapAngle = 200,
}

ns.ICON = "Interface\\AddOns\\" .. ADDON .. "\\Media\\Icon"
-- The minimap draws the icon at 17px, too small to shrink the 128px one cleanly.
ns.ICON_SMALL = "Interface\\AddOns\\" .. ADDON .. "\\Media\\IconSmall"

-- Releases get their version stamped into the TOC; a copy straight from the repository is "dev".
local version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")
ns.VERSION = version and not version:find("@", 1, true) and version:gsub("[:|]", "") or "dev"

function ns:VersionName(v)
	return v == "dev" and "a development copy" or v
end

local function copyDefaults(dst, src)
	for k, v in pairs(src) do
		if dst[k] == nil then
			dst[k] = v
		end
	end
end

function ns:Print(msg)
	print("|cffe8a33dTurkey Tickle UI|r Puzzle: " .. msg)
end

function ns:PlaySound(kit)
	if self.db.sounds and SOUNDKIT and SOUNDKIT[kit] then
		PlaySound(SOUNDKIT[kit])
	end
end

-- Forever characters can have a surname, which UnitFullName returns where the realm usually goes.
-- Addon messages name same-realm senders "First Last", and others "First Last-Realm".
function ns:PlayerName()
	if self.playerName then
		return self.playerName
	end
	local name, surname = UnitFullName("player")
	local realm = GetNormalizedRealmName()
	if not (name and realm) then
		return UnitName("player")
	end
	if surname and surname ~= "" and surname ~= realm then
		name = name .. " " .. surname
	end
	self.playerName = name
	return name
end

-- Drops our own realm so one player always has one name.
function ns:Canonical(sender)
	local realm = GetNormalizedRealmName()
	if realm and sender:sub(-#realm - 1) == "-" .. realm then
		return sender:sub(1, -#realm - 2)
	end
	return sender
end

function ns:ShortName(name)
	return (name:gsub("%-.*", ""))
end

function ns:IsMe(sender)
	return self:Canonical(sender) == self:PlayerName()
end

-- Events --------------------------------------------------------------------

local driver = CreateFrame("Frame")
ns.driver = driver
ns.handlers = {}

function ns.handlers.ADDON_LOADED(name)
	if name ~= ADDON then
		return
	end
	TurkeyTickleUI_PuzzleDB = TurkeyTickleUI_PuzzleDB or {}
	copyDefaults(TurkeyTickleUI_PuzzleDB, ns.defaults)
	ns.db = TurkeyTickleUI_PuzzleDB
	ns.db.debugLog = nil
	ns.db.ghost = nil
	ns:InitComm()
	ns:CreateOptions()
	ns:UpdateMinimap()
	driver:UnregisterEvent("ADDON_LOADED")
	ns:RegisterEvents()
end

driver:SetScript("OnEvent", function(_, event, ...)
	xpcall(ns.handlers[event], geterrorhandler(), ...)
end)

-- Every file has added its handlers by the time ADDON_LOADED fires.
function ns:RegisterEvents()
	for event in pairs(self.handlers) do
		if event ~= "ADDON_LOADED" then
			-- Some events don't exist on every client; skip the ones that error.
			pcall(driver.RegisterEvent, driver, event)
		end
	end
end
driver:RegisterEvent("ADDON_LOADED")

SLASH_TURKEYTICKLEUI_PUZZLE1 = "/ttpz"
SLASH_TURKEYTICKLEUI_PUZZLE2 = "/ttpuzzle"
SlashCmdList.TURKEYTICKLEUI_PUZZLE = function(msg)
	msg = strtrim(msg or "")
	local cmd, rest = msg:match("^(%S*)%s*(.-)$")
	cmd = cmd:lower()
	if cmd == "options" or cmd == "config" then
		ns:OpenOptions()
	elseif cmd == "host" or cmd == "new" then
		ns:ShowHost()
	elseif cmd == "join" then
		ns:JoinSession(ns:FindSession(rest), rest)
	elseif cmd == "leave" then
		ns:LeaveSession()
	elseif cmd == "end" then
		ns:EndSession()
	elseif cmd == "status" then
		ns:PrintStatus()
	elseif cmd == "version" then
		ns:Print(format("version %s (puzzle protocol %d)", ns.VERSION, ns.PROTOCOL))
	elseif cmd == "reset" then
		wipe(TurkeyTickleUI_PuzzleDB)
		copyDefaults(TurkeyTickleUI_PuzzleDB, ns.defaults)
		ns:RefreshBoard()
		ns:Print("Settings reset.")
	elseif cmd == "" then
		ns:Toggle()
	else
		ns:Print("/ttpz [host | join [name] | leave | end | status | version | options | reset]")
	end
end

function TurkeyTickleUI_Puzzle_OnAddonCompartmentClick()
	ns:Toggle()
end
