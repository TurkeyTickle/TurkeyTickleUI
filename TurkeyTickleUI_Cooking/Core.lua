local ADDON, ns = ...

ns.COOKING = 185
ns.COOKING_SPELL = 2550
ns.ICON = "Interface\\Icons\\INV_Misc_Food_15"

ns.defaults = {
	remind = true,
	remindAlert = true,
	remindMinutes = 20,
	remindThreshold = 3,
	nudge = true,
	nudgePoint = {},
	tooltips = true,
	unitTooltips = true,
	showTracked = true,
	showSuggested = true,
	suggestedCount = 5,
	pinSize = 18,
	levelsAbove = 2,
	includeGreen = true,
	onlyKnown = false,
}

ns.charDefaults = {
	known = {}, -- [recipe spell] = true
	tracked = {}, -- [npcID] = true
	scanned = false,
}

local function copyDefaults(dst, src)
	for k, v in pairs(src) do
		if dst[k] == nil then
			dst[k] = type(v) == "table" and {} or v
		end
	end
end

function ns:Print(msg)
	print("|cffe8a33dTurkey Tickle UI|r Cooking: " .. msg)
end

-- Lookup tables -------------------------------------------------------------

ns.recipeByID, ns.recipeByName = {}, {}
ns.usedIn = {} -- [reagent item] = { recipe, ... }
ns.scrollRecipe = {} -- [recipe item] = recipe
ns.mobDrops = {} -- [npcID] = { { item, chance }, ... }
ns.trainers = {} -- [npcID] = highest cap

local function buildLookups()
	for _, recipe in ipairs(ns.recipes) do
		ns.recipeByID[recipe.id] = recipe
		ns.recipeByName[recipe.name:lower()] = recipe
		if recipe.item and ns.items[recipe.item] then
			ns.recipeByName[ns.items[recipe.item].n:lower()] = ns.recipeByName[ns.items[recipe.item].n:lower()] or recipe
		end
		for _, reagent in ipairs(recipe.r) do
			ns.usedIn[reagent[1]] = ns.usedIn[reagent[1]] or {}
			tinsert(ns.usedIn[reagent[1]], recipe)
		end
		if recipe.scroll then
			ns.scrollRecipe[recipe.scroll] = recipe
		end
	end
	for itemID in pairs(ns.usedIn) do
		local item = ns.items[itemID]
		for _, drop in ipairs(item and item.drops or {}) do
			ns.mobDrops[drop[1]] = ns.mobDrops[drop[1]] or {}
			tinsert(ns.mobDrops[drop[1]], { itemID, drop[2] })
		end
	end
	for _, row in ipairs(ns.trainerList) do
		ns.trainers[row[1]] = row[2]
	end
end
buildLookups()

function ns:ItemName(itemID)
	local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
	return name or (self.items[itemID] and self.items[itemID].n) or ("item " .. itemID)
end

function ns:ItemIcon(itemID)
	local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
	return icon or self.ICON
end

function ns:RecipeIcon(recipe)
	return recipe.item and self:ItemIcon(recipe.item) or "Interface\\Icons\\Spell_Fire_Fire"
end

function ns:MinLevel(levels)
	return tonumber(tostring(levels or ""):match("%d+"))
end

function ns:PlayerLevel()
	return UnitLevel("player") or 1
end

function ns:PlayerFaction()
	local faction = UnitFactionGroup and UnitFactionGroup("player")
	return faction == "Alliance" and "A" or faction == "Horde" and "H" or nil
end

function ns:LevelColor(levels)
	local level = self:MinLevel(levels)
	if not level then
		return "|cffffffff"
	end
	local diff = level - self:PlayerLevel()
	if diff > 2 then
		return "|cffff4040"
	elseif diff >= -2 then
		return "|cffffff00"
	elseif diff >= -8 then
		return "|cff40ff40"
	end
	return "|cff9d9d9d"
end

function ns:ZoneName(npc)
	local spawn = npc.s and npc.s[1]
	if spawn and C_Map and C_Map.GetMapInfo then
		local info = C_Map.GetMapInfo(spawn[1])
		if info and info.name then
			return info.name
		end
	end
	return ""
end

function ns:Money(copper)
	copper = copper or 0
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	local parts = {}
	if g > 0 then
		tinsert(parts, g .. "|cffffd700g|r")
	end
	if s > 0 then
		tinsert(parts, s .. "|cffc7c7cfs|r")
	end
	if c > 0 or #parts == 0 then
		tinsert(parts, c .. "|cffeda55fc|r")
	end
	return table.concat(parts, " ")
end

-- Cooking skill ----------------------------------------------------------------

local cookingNames = { cooking = true }

function ns:IsCookingName(name)
	if type(name) ~= "string" then
		return false
	end
	if not cookingNames.localized then
		local spell = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(self.COOKING_SPELL)
		if spell then
			cookingNames[spell:lower()] = true
			cookingNames.localized = true
		end
	end
	return cookingNames[name:lower()] == true
end

local function fromProfessions(...)
	for i = 1, select("#", ...) do
		local index = select(i, ...)
		if index then
			local name, _, rank, maxRank, _, _, skillLine, modifier = GetProfessionInfo(index)
			if skillLine == ns.COOKING or ns:IsCookingName(name) then
				return rank, maxRank, modifier
			end
		end
	end
end

local function fromSkillLines()
	for i = 1, GetNumSkillLines() do
		local name, isHeader, _, rank, _, modifier, maxRank = GetSkillLineInfo(i)
		if not isHeader and ns:IsCookingName(name) then
			return rank, maxRank, modifier
		end
	end
end

-- ns.skill = { rank, max, effective } or nil when the character hasn't learned Cooking.
function ns:ReadSkill()
	local rank, maxRank, modifier
	if GetProfessions and GetProfessionInfo then
		rank, maxRank, modifier = fromProfessions(GetProfessions())
	end
	if not rank and GetNumSkillLines and GetSkillLineInfo then
		rank, maxRank, modifier = fromSkillLines()
	end
	if rank and rank > 0 then
		self.skill = { rank = rank, max = maxRank or rank, effective = rank + (modifier or 0) }
	else
		self.skill = nil
	end
	return self.skill
end

function ns:Skill()
	return self.skill and self.skill.effective or 0
end

function ns:IsCapped()
	return self.skill and self.skill.max > 0 and self.skill.rank >= self.skill.max
end

-- Recipe colours ---------------------------------------------------------------

ns.colorCodes = {
	red = "|cffff2020",
	orange = "|cffff8040",
	yellow = "|cffffff00",
	green = "|cff40c040",
	grey = "|cff808080",
}
ns.colorNames = { red = "not yet", orange = "orange", yellow = "yellow", green = "green", grey = "grey" }

function ns:LearnSkill(recipe)
	if recipe.trainer then
		return recipe.trainer[2]
	end
	return recipe.scrollSkill or recipe.t[1]
end

function ns:Difficulty(recipe, skill)
	skill = skill or self:Skill()
	local t = recipe.t
	if skill < math.max(t[1], self:LearnSkill(recipe)) then
		return "red"
	elseif skill < t[2] then
		return "orange"
	elseif skill < t[3] then
		return "yellow"
	elseif skill < t[4] then
		return "green"
	end
	return "grey"
end

-- Chance one craft gives a point: certain while orange, falling to nothing at grey.
function ns:SkillUpChance(recipe, skill)
	skill = skill or self:Skill()
	local t = recipe.t
	if skill < math.max(t[1], self:LearnSkill(recipe)) or skill >= t[4] then
		return 0
	elseif skill < t[2] then
		return 1
	end
	return (t[4] - skill) / (t[4] - t[2])
end

function ns:ColoredName(recipe, skill)
	return self.colorCodes[self:Difficulty(recipe, skill)] .. recipe.name .. "|r"
end

-- Known recipes ------------------------------------------------------------------

function ns:IsKnown(recipe)
	if self.char.known[recipe.id] then
		return true
	end
	return IsPlayerSpell and IsPlayerSpell(recipe.id) or false
end

function ns:CanLearnNow(recipe)
	return self.skill and not self:IsKnown(recipe) and self.skill.rank >= self:LearnSkill(recipe)
end

local function isCookingWindow()
	local api = C_TradeSkillUI
	if not (api and api.GetBaseProfessionInfo and api.GetAllRecipeIDs and api.GetRecipeInfo) then
		return false
	end
	if (api.IsTradeSkillLinked and api.IsTradeSkillLinked()) or (api.IsTradeSkillGuild and api.IsTradeSkillGuild()) then
		return false
	end
	local base = api.GetBaseProfessionInfo()
	return base and (base.professionID == ns.COOKING or ns:IsCookingName(base.professionName)), base
end

function ns:ScanTradeSkill()
	local isCooking = isCookingWindow()
	if not isCooking then
		return
	end
	local found = 0
	for _, recipeID in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
		local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
		if info and info.learned and self.recipeByID[recipeID] then
			self.char.known[recipeID] = true
			found = found + 1
		end
	end
	if found > 0 then
		self.char.scanned = true
		self.cookingOpen = true
		self:Changed()
	end
end

function ns:SetKnown(recipe, known)
	self.char.known[recipe.id] = known or nil
	self:Changed()
end

-- Bags ---------------------------------------------------------------------------------

ns.bag = {}

local getItemCount = C_Item and C_Item.GetItemCount or GetItemCount

function ns:Count(itemID)
	return self.bag[itemID] or 0
end

function ns:ReadBags()
	local changed, gained = false, false
	for itemID in pairs(self.items) do
		local count = getItemCount and getItemCount(itemID) or 0
		if count ~= (self.bag[itemID] or 0) then
			changed = true
			if count > (self.bag[itemID] or 0) and self.usedIn[itemID] then
				gained = true
			end
			self.bag[itemID] = count > 0 and count or nil
		end
	end
	return changed, gained
end

-- Tracking ---------------------------------------------------------------------------

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

-- Everything that depends on skill, recipes or bags reads from one cached plan.
function ns:Changed()
	self.plan = nil
	self:RefreshMap()
	self:RefreshBrowser()
	self:RefreshNudge()
end

function ns:RefreshBrowser()
	if self.browser and self.browser:IsShown() then
		self.browser:Refresh()
	end
end

-- Events ---------------------------------------------------------------------------------

local driver = CreateFrame("Frame")
ns.driver = driver
ns.handlers = {}

function ns.handlers.ADDON_LOADED(name)
	if name ~= ADDON then
		return
	end
	TurkeyTickleUI_CookingDB = TurkeyTickleUI_CookingDB or {}
	copyDefaults(TurkeyTickleUI_CookingDB, ns.defaults)
	ns.db = TurkeyTickleUI_CookingDB
	TurkeyTickleUI_CookingCharDB = TurkeyTickleUI_CookingCharDB or {}
	copyDefaults(TurkeyTickleUI_CookingCharDB, ns.charDefaults)
	ns.char = TurkeyTickleUI_CookingCharDB
	ns:CreateOptions()
	ns:InitMap()
	ns:InitTooltip()
	driver:UnregisterEvent("ADDON_LOADED")
	ns:RegisterEvents()
end

function ns.handlers.PLAYER_LOGIN()
	ns:ReadSkill()
	ns:ReadBags()
	ns:CreateNudge()
	ns:Changed()
	C_Timer.After(8, function()
		ns:LoginReminder()
	end)
end

local function skillChanged()
	local before = ns.skill and ns.skill.rank
	local beforeMax = ns.skill and ns.skill.max
	ns:ReadSkill()
	if (ns.skill and ns.skill.rank) ~= before or (ns.skill and ns.skill.max) ~= beforeMax then
		ns:Changed()
		ns:CheckCap()
	end
end

ns.handlers.SKILL_LINES_CHANGED = skillChanged
ns.handlers.CHAT_MSG_SKILL = skillChanged

function ns.handlers.TRADE_SKILL_SHOW()
	ns:ScanTradeSkill()
end

function ns.handlers.TRADE_SKILL_LIST_UPDATE()
	ns:ScanTradeSkill()
end

function ns.handlers.TRADE_SKILL_CLOSE()
	ns.cookingOpen = nil
end

local learnPattern
function ns.handlers.CHAT_MSG_SYSTEM(msg)
	if type(msg) ~= "string" or (issecretvalue and issecretvalue(msg)) then
		return
	end
	if not learnPattern then
		local template = ERR_LEARN_RECIPE_S or "You have learned how to create a new item: %s."
		learnPattern = "^" .. template:gsub("([%(%)%.%-%+%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)") .. "$"
	end
	local what = msg:match(learnPattern)
	if not what then
		return
	end
	local name = what:match("%[(.-)%]") or what
	local recipe = ns.recipeByName[name:lower()]
	if recipe then
		ns:SetKnown(recipe, true)
	end
end

local bagPending
function ns.handlers.BAG_UPDATE_DELAYED()
	if bagPending then
		return
	end
	bagPending = true
	C_Timer.After(0.5, function()
		bagPending = nil
		local changed, gained = ns:ReadBags()
		if changed then
			ns:Changed()
		end
		if gained then
			ns:BagReminder()
		end
	end)
end

function ns.handlers.PLAYER_LEVEL_UP()
	ns:Changed()
	ns:CheckCap()
end

function ns.handlers.ZONE_CHANGED_NEW_AREA()
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

SLASH_TURKEYTICKLEUI_COOKING1 = "/ttcook"
SLASH_TURKEYTICKLEUI_COOKING2 = "/cookhelp"
SlashCmdList.TURKEYTICKLEUI_COOKING = function(msg)
	msg = strtrim(msg or ""):lower()
	if msg == "options" or msg == "config" then
		ns:OpenOptions()
	elseif msg == "clear" then
		ns:ClearTracked()
		ns:Print("Cleared hunting pins from the map.")
	elseif msg == "reset" then
		local point = TurkeyTickleUI_CookingDB.nudgePoint
		wipe(TurkeyTickleUI_CookingDB)
		copyDefaults(TurkeyTickleUI_CookingDB, ns.defaults)
		TurkeyTickleUI_CookingDB.nudgePoint = point
		ns:Changed()
		ns:Print("Settings reset.")
	elseif msg == "status" or msg == "remind" then
		ns:Remind()
	elseif msg == "hunt" then
		ns:ShowBrowser("hunt")
	elseif msg == "learn" then
		ns:ShowBrowser("learn")
	elseif msg ~= "" then
		ns:ShowBrowser("recipes", msg)
	else
		ns:ToggleBrowser()
	end
end

function TurkeyTickleUI_Cooking_OnAddonCompartmentClick()
	ns:ToggleBrowser()
end
