local ADDON, ns = ...

ns.defaults = {
	showTrainers = true,
	showSpecial = true,
	showTracked = true,
	myFactionOnly = true,
	tooltips = true,
	pinSize = 18,
	onlyNeeded = false,
}

ns.charDefaults = {
	known = {}, -- [abilityKey] = { [rank] = true }
	tracked = {}, -- [npcID] = true
}

ns.listNames = {
	collector = "Unique Rare Pets",
	rare = "Rare Pets",
	looks = "Unusual Looks",
	elite = "Elite Pets",
	spawned = "Spawned Pets",
}
ns.listOrder = { "collector", "rare", "looks", "elite", "spawned" }

ns.roleNames = {
	offensive = "|cffff7060Offense|r",
	general = "|cffffd060General|r",
	defensive = "|cff60a0ffDefense|r",
}

local function copyDefaults(dst, src)
	for k, v in pairs(src) do
		if dst[k] == nil then
			dst[k] = type(v) == "table" and {} or v
		end
	end
end

function ns:Print(msg)
	print("|cffe8a33dTurkey Tickle UI|r Pets: " .. msg)
end

-- Lookup tables -------------------------------------------------------------

ns.abilityByKey, ns.abilityByName, ns.familyByKey = {}, {}, {}
ns.teaches = {} -- [npcID] = { { ability, rank }, ... }

local function buildLookups()
	for _, ability in ipairs(ns.abilities) do
		ns.abilityByKey[ability.key] = ability
		ns.abilityByName[ability.name:lower()] = ability
		for _, rank in ipairs(ability.ranks) do
			for _, npcID in ipairs(rank.npcs) do
				ns.teaches[npcID] = ns.teaches[npcID] or {}
				tinsert(ns.teaches[npcID], { ability = ability, rank = rank })
			end
		end
	end
	for _, family in ipairs(ns.families) do
		ns.familyByKey[family.key] = family
	end
end
buildLookups()

function ns:MinLevel(levels)
	return tonumber(tostring(levels or ""):match("%d+"))
end

function ns:PlayerLevel()
	return UnitLevel("player") or 1
end

function ns:IsTameable(npc)
	if npc.untameable then
		return false
	end
	local level = self:MinLevel(npc.lv)
	return not level or level <= self:PlayerLevel()
end

function ns:LevelColor(levels)
	local level = self:MinLevel(levels)
	if not level then
		return "|cffffffff"
	end
	local diff = level - self:PlayerLevel()
	if diff > 0 then
		return "|cffff4040"
	elseif diff >= -2 then
		return "|cffffff00"
	elseif diff >= -8 then
		return "|cff40ff40"
	end
	return "|cff9d9d9d"
end

function ns:FamilyName(key, plural)
	local family = self.familyByKey[key]
	if not family then
		return key or ""
	end
	return plural and family.name or family.single
end

function ns:FamilyIcon(key)
	local family = self.familyByKey[key]
	return "Interface\\Icons\\" .. (family and family.icon or "Ability_Hunter_BeastTaming")
end

function ns:AbilityIcon(ability)
	return "Interface\\Icons\\" .. ability.icon
end

function ns:CanFamilyLearn(familyKey, ability)
	if ability.families == true then
		return true
	end
	for _, key in ipairs(ability.families) do
		if key == familyKey then
			return true
		end
	end
	return false
end

function ns:ZoneName(npc)
	local spawn = npc.s and npc.s[1]
	if spawn and C_Map and C_Map.GetMapInfo then
		local info = C_Map.GetMapInfo(spawn[1])
		if info and info.name then
			return info.name
		end
	end
	return npc.z or ""
end

function ns:PlayerFaction()
	local faction = UnitFactionGroup and UnitFactionGroup("player")
	return faction == "Alliance" and "A" or faction == "Horde" and "H" or nil
end

-- Tracking ------------------------------------------------------------------

function ns:IsTracked(npcID)
	return self.char.tracked[npcID] == true
end

function ns:SetTracked(npcID, tracked)
	self.char.tracked[npcID] = tracked or nil
	self:RefreshMap()
	self:RefreshBrowser()
end

function ns:ClearTracked()
	wipe(self.char.tracked)
	self:RefreshMap()
	self:RefreshBrowser()
end

function ns:RefreshBrowser()
	if self.browser and self.browser:IsShown() then
		self.browser:Refresh()
	end
end

-- Events --------------------------------------------------------------------

local driver = CreateFrame("Frame")
ns.driver = driver
ns.handlers = {}

function ns.handlers.ADDON_LOADED(name)
	if name ~= ADDON then
		return
	end
	TurkeyTickleUI_PetsDB = TurkeyTickleUI_PetsDB or {}
	copyDefaults(TurkeyTickleUI_PetsDB, ns.defaults)
	ns.db = TurkeyTickleUI_PetsDB
	TurkeyTickleUI_PetsCharDB = TurkeyTickleUI_PetsCharDB or {}
	copyDefaults(TurkeyTickleUI_PetsCharDB, ns.charDefaults)
	ns.char = TurkeyTickleUI_PetsCharDB
	ns:CreateOptions()
	ns:InitMap()
	ns:InitTooltip()
	driver:UnregisterEvent("ADDON_LOADED")
	ns:RegisterEvents()
end

function ns.handlers.PLAYER_LEVEL_UP()
	ns:RefreshMap()
	ns:RefreshBrowser()
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

SLASH_TURKEYTICKLEUI_PETS1 = "/ttpets"
SLASH_TURKEYTICKLEUI_PETS2 = "/hunterpets"
SlashCmdList.TURKEYTICKLEUI_PETS = function(msg)
	msg = strtrim(msg or ""):lower()
	if msg == "options" or msg == "config" then
		ns:OpenOptions()
	elseif msg == "clear" then
		ns:ClearTracked()
		ns:Print("Cleared tracked pets from the map.")
	elseif msg == "reset" then
		wipe(TurkeyTickleUI_PetsDB)
		copyDefaults(TurkeyTickleUI_PetsDB, ns.defaults)
		ns:RefreshMap()
		ns:Print("Settings reset.")
	elseif msg == "known" then
		ns:PrintKnown()
	elseif msg == "guide" then
		ns:ShowBrowser("guide")
	elseif msg ~= "" then
		ns:ShowBrowser("skills", msg)
	else
		ns:ToggleBrowser()
	end
end

function TurkeyTickleUI_Pets_OnAddonCompartmentClick()
	ns:ToggleBrowser()
end
