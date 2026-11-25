-- Loads TurkeyTickleUI_Pets in a stubbed WoW environment and drives every view:
--   luajit tests/harness_pets.lua TurkeyTickleUI_Pets
local function stub()
	local s = {}
	return setmetatable(s, {
		__index = function(t, k)
			-- Only widget methods exist up front; plain fields (row.label etc.) start nil like real frames.
			if type(k) ~= "string" or not k:match("^%u") then return nil end
			local f = function(self, _, _, template)
				if k == "GetFont" then return "font", 10 end
				if k == "GetFrameLevel" or k == "GetWidth" then return 1 end
				if k == "IsShown" or k == "IsPlaying" or k == "IsForbidden" then return false end
				if k == "GetID" then return 1 end
				if k == "CreateFontString" then
					local fs = stub()
					local hasFont = template ~= nil
					fs.SetFont = function() hasFont = true end
					fs.SetFontObject = function() hasFont = true end
					local function check() if not hasFont then error("FontString: Font not set", 2) end end
					fs.SetText = check
					fs.SetFormattedText = check
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
	local text
	f.SetText = function(self, t) text = t if scripts.OnTextChanged then scripts.OnTextChanged(self) end end
	f.GetText = function() return text end
	f.Show = function(self) shown = true if scripts.OnShow then scripts.OnShow(self) end end
	f.Hide = function() shown = false end
	f.IsShown = function() return shown end
	f.scripts = scripts
	return f
end

local rowsRendered, initializer, mapFrames = 0, nil, {}
function CreateFrame(kind, name, parent, template)
	local f = newFrame()
	f.SetParent = function(self, p) if p == WorldMapFrame:GetCanvas() then tinsert(mapFrames, self) end end
	if template == "WowScrollBoxList" then
		f.SetDataProvider = function(self, provider)
			for _, node in ipairs(provider.rows) do
				local row = newFrame()
				initializer(row, node)
				rowsRendered = rowsRendered + 1
				f.lastRows = provider.rows
			end
		end
	end
	if name then _G[name] = f end
	return f
end
function CreateFromMixins(...) local o = {} for _, m in ipairs({...}) do for k, v in pairs(m) do o[k] = v end end return o end
function Mixin(o, ...) for _, m in ipairs({...}) do for k, v in pairs(m) do o[k] = v end end return o end
function geterrorhandler() return function(e) print("LUA ERROR: " .. tostring(e)) print(debug.traceback()) os.exit(1) end end
function issecretvalue() return false end
function strsplit(sep, s) local out = {} for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = part end return unpack(out) end
strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
tinsert = table.insert
format = string.format
SlashCmdList = {}
UISpecialFrames = {}
GameTooltip = stub()
GameTooltip.GetUnit = function() return nil end
GameTooltip_Hide = function() end
C_Timer = { After = function(_, fn) fn() end }
C_AddOns = { GetAddOnMetadata = function() return "0.1.0" end }
Settings = {
	RegisterCanvasLayoutCategory = function() return stub() end,
	RegisterCanvasLayoutSubcategory = function() return stub() end,
	RegisterAddOnCategory = function() end,
	OpenToCategory = function() end,
}
local hunterLevel, pet
function UnitLevel(unit) return unit == "pet" and pet and pet.level or hunterLevel or 20 end
function UnitName(unit) return unit == "pet" and pet and pet.name end
function UnitCreatureFamily(unit) if unit == "pet" and pet then return pet.family, pet.familyID end end
function UnitFactionGroup() return "Alliance" end
function UnitExists(unit) return unit == "pet" and pet ~= nil end
function UnitGUID() return "Creature-0-1-2-3-1132-0000" end
function IsShiftKeyDown() return false end
function CreateVector2D(x, y) return { x = x, y = y, GetXY = function(v) return v.x, v.y end } end
function CreateDataProvider(rows) return { rows = rows } end
function CreateScrollBoxListLinearView()
	local view = stub()
	view.SetElementInitializer = function(_, _, fn) initializer = fn end
	return view
end
ScrollUtil = { InitScrollBoxListWithScrollBar = function() end }
Enum = { UIMapType = { Continent = 2, Zone = 3 }, TrainerType = { Pet = 2 }, TooltipDataType = { Unit = 2 } }
Enum.SpellBookSpellBank = { Pet = 1 }
C_SpellBook = {
	HasPetSpells = function() return pet and #pet.skills end,
	GetSpellBookItemName = function(slot, bank)
		assert(bank == Enum.SpellBookSpellBank.Pet)
		return unpack(pet.skills[slot])
	end,
}

-- Live map geometry modelled as the Era frames the data ships with (true for most Forever zones).
local frames
C_Map = {
	GetMapInfo = function(id) return { name = "Map" .. id, mapType = 3 } end,
	GetWorldPosFromMapPos = function(mapID, v)
		local b = frames[mapID]
		if not b then return nil end
		return b.c, CreateVector2D(b.top + (b.bottom - b.top) * v.y, b.left + (b.right - b.left) * v.x)
	end,
	GetMapPosFromWorldPos = function(c, v, mapID)
		local b = frames[mapID]
		if not b or b.c ~= c then return nil end
		return mapID, CreateVector2D((v.y - b.left) / (b.right - b.left), (v.x - b.top) / (b.bottom - b.top))
	end,
	GetBestMapForUnit = function() return 1429 end,
	GetPlayerMapPosition = function() return CreateVector2D(0.5, 0.5) end,
}

local canvas = newFrame()
canvas.GetWidth = function() return 1000 end
canvas.GetHeight = function() return 660 end
WorldMapFrame = newFrame()
WorldMapFrame:Show()
WorldMapFrame.mapID = 1429
WorldMapFrame.GetMapID = function(self) return self.mapID end
WorldMapFrame.GetCanvas = function() return canvas end
WorldMapFrame.GetCanvasScale = function() return 1.5 end
WorldMapFrame.GetCanvasZoomPercent = function() return 0 end
WorldMapFrame.GetPinFrameLevelsManager = function() return { GetValidFrameLevel = function() return 2000 end } end
C_Map.OpenWorldMap = function(id) WorldMapFrame.mapID = id end
function InCombatLockdown() return false end

local function shownPins()
	local n = 0
	for _, f in ipairs(mapFrames) do
		if rawget(f, "entry") and f:IsShown() then n = n + 1 end
	end
	return n
end

local postCall
TooltipDataProcessor = { AddTooltipPostCall = function(_, fn) postCall = fn end }

C_Trainer = { GetTrainerType = function() return 2 end }
-- Forever's Beast Training: no service names, only spell IDs in the tooltip data.
local spells = {
	[17255] = { "Bite", "Rank 2" }, [23099] = { "Dash", "Rank 1" }, [14916] = { "Growl", "Rank 2" },
	[3009] = { "Claw", "Rank 3" }, [1742] = { "Cower", "Rank 1" }, [24545] = { "Great Stamina", "Rank 4" },
	[99999] = { "Charge", nil },
}
local services = { 17255, 23099, 14916 }
function GetNumTrainerServices() return #services end
function GetTrainerServiceInfo(i) return nil, nil, "available" end
C_TooltipInfo = { GetTrainerService = function(i) return { id = services[i] } end }
C_Spell = {
	GetSpellName = function(id) return spells[id] and spells[id][1] end,
	GetSpellSubtext = function(id) return spells[id] and spells[id][2] end,
	RequestLoadSpellData = function() end,
}
function IsPlayerSpell(id) return id == 5149 end
ERR_LEARN_SPELL_S = "You have learned a new spell: %s."
WT_LearnedPetAbilities = { [1742] = true, [24545] = true, [99999] = true }

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

frames = ns.eraMapFrames
local function fire(event, ...) ns.driver.scripts.OnEvent(ns.driver, event, ...) end
fire("ADDON_LOADED", dir)
fire("PLAYER_LOGIN")
print("imported from WhatsTraining:", ns:KnownRank(ns.abilityByKey.cower), ns:KnownRank(ns.abilityByKey.greatstamina),
	ns:KnownRank(ns.abilityByKey.charge))
spells[99999][2] = "Rank 2"
fire("SPELL_DATA_LOAD_RESULT", 99999, true)
print("charge after spell data loaded:", ns:KnownRank(ns.abilityByKey.charge))

ns:ShowBrowser("families", "cats")
local catRow
for _, node in ipairs(ns.browser.scroll.lastRows) do
	if node.id == "family:cat" then
		catRow = node
		break
	end
end
assert(catRow)
assert(catRow.right == "Physical damage +10%  /  Base armor 0%  /  Health -2%")
assert(ns:FamilyStatsText("unknown") == nil)

local tooltipLines = {}
local function captureLine(_, line) tinsert(tooltipLines, line) end
local statsTooltip = { AddLine = captureLine, SetText = captureLine }
catRow.tooltip(statsTooltip)
assert(table.concat(tooltipLines, "\n"):find("1.0–2.0 sec per swing", 1, true))

ns:ShowBrowser("special", "broken tooth")
local foundBrokenTooth
for _, node in ipairs(ns.browser.scroll.lastRows) do
	if node.npcID == 2850 then
		foundBrokenTooth = true
		assert(node.text:find("1.0s swing", 1, true))
		wipe(tooltipLines)
		node.tooltip(statsTooltip)
		local lines = table.concat(tooltipLines, "\n")
		assert(lines:find("Attack speed: 1.0 sec per swing", 1, true))
		assert(lines:find("Cat family: Physical damage +10%", 1, true))
	end
end
assert(foundBrokenTooth)
assert(ns:PetAttackInterval(-4, ns.npcs[-4]) == 2)

wipe(tooltipLines)
ns:FillTooltip(statsTooltip, -999, { n = "Unknown Beast", f = "cat", lv = "10", z = "" })
assert(not table.concat(tooltipLines, "\n"):find("Attack speed:", 1, true))
ns.browser.search:SetText("")

local function findRow(id)
	for _, row in ipairs(ns.browser.scroll.lastRows) do
		if row.id == id then return row end
	end
end

local function clickRow(id)
	local node = assert(findRow(id), id)
	local row = newFrame()
	initializer(row, node)
	row.scripts.OnClick(row, "LeftButton")
end

hunterLevel = 8
SlashCmdList.TURKEYTICKLEUI_PETS("guide")
assert(ns.browser.tab == "guide" and findRow("guide:no-pet"))
assert(findRow("guide:tames").right == "First tame at hunter level 10")
hunterLevel = 40
fire("PLAYER_LEVEL_UP")
assert(findRow("guide:solo").right == "Mature Paletusk (38-39)")
clickRow("guide:solo")
assert(findRow("guide:solo:255851").npcID == 255851)
pet = { name = "Truffle", level = 39, family = "Eber", familyID = 5, skills = {
	{ "Bite", "Rank 4" }, { "Growl", "Rank 4" },
} }
fire("UNIT_PET", "player")
assert(findRow("guide:pet").right:find("Truffle", 1, true))
assert(findRow("guide:now:charge:4").right == "Tame to learn")
clickRow("guide:now:charge:4")
assert(findRow("guide:now:charge:4:255851").npcID == 255851)
clickRow("guide:later")
assert(findRow("guide:later:bite:6").right == "Learn now, teach at pet 40")
assert(findRow("guide:later:growl:5"))
pet.level = 40
fire("UNIT_LEVEL", "pet")
assert(findRow("guide:now:growl:5").right == "Visit a pet trainer")
assert(findRow("guide:now:bite:6").right == "Tame to learn")
ns:SetKnown(ns.abilityByKey.bite, 6, true)
assert(findRow("guide:now:bite:6").right == "Teach with Beast Training")
pet.skills[1][2] = "Rank 6"
fire("SPELLS_CHANGED")
assert(not findRow("guide:now:bite:6"))
assert(findRow("guide:later:bite:7"))
ns:SetKnown(ns.abilityByKey.bite, 6, false)
pet, hunterLevel = nil, nil

-- Every tab, fully expanded.
local function expandAll(tab)
	ns:ShowBrowser(tab)
	local clicks = 0
	repeat
		local closed
		for _, node in ipairs(ns.browser.scroll.lastRows) do
			if node.children and not node.isOpen then
				closed = node
				break
			end
		end
		if closed then
			local row = newFrame()
			initializer(row, closed)
			row.scripts.OnClick(row, "LeftButton")
			clicks = clicks + 1
		end
	until not closed or clicks > 2000
	local seen = {}
	for _, node in ipairs(ns.browser.scroll.lastRows) do
		assert(not seen[node.id], "duplicate node id " .. node.id)
		seen[node.id] = true
	end
	return #ns.browser.scroll.lastRows
end
for _, tab in ipairs({ "skills", "families", "special", "trainers" }) do
	print(tab, "rows after expanding:", expandAll(tab))
end
ns:ShowBrowser("skills", "timber")
print("search 'timber' rows:", #ns.browser.scroll.lastRows)
ns.browser.search:SetText("")

fire("TRAINER_SHOW")
print("known after Beast Training:", ns:KnownRank(ns.abilityByKey.bite), ns:KnownRank(ns.abilityByKey.dash),
	ns:KnownRank(ns.abilityByKey.growl))
fire("CHAT_MSG_SYSTEM", "You have learned a new spell: |cff71d5ff|Hspell:3009|h[Claw]|h|r.")
print("claw known:", ns:KnownRank(ns.abilityByKey.claw))
assert(ns:ParseAbility("Bite III") == ns.abilityByKey.bite and select(2, ns:ParseAbility("Bite III")) == 3)
assert(select(2, ns:ParseAbility("Bite (Rank 4)")) == 4)

local function mapFrame() ns.mapWatcher.scripts.OnUpdate(ns.mapWatcher, 0.016) end
mapFrame()
print("pins on map 1429 (special + trainers):", shownPins())
ns:ShowOnMap(1132)
mapFrame()
print("after pinning Timber, map is", WorldMapFrame.mapID, "pins", shownPins())
local pin
for _, f in ipairs(mapFrames) do if rawget(f, "entry") and f.entry.id == 1132 and f:IsShown() then pin = f end end
pin.scripts.OnEnter(pin)
fire("GLOBAL_MOUSE_DOWN", "LeftButton")
pin.IsVisible = function() return true end
fire("GLOBAL_MOUSE_UP", "LeftButton")
pin.scripts.OnLeave(pin)
SlashCmdList.TURKEYTICKLEUI_PETS("clear")

postCall(GameTooltip, { guid = "Creature-0-1-2-3-1132-0000" })
ns:FillTooltip(GameTooltip, 1132, ns.npcs[1132], true)
ns:FillTooltip(GameTooltip, 3306, ns.trainers[3306], true)
SlashCmdList.TURKEYTICKLEUI_PETS("known")
print("rows rendered:", rowsRendered)
print("done")
