-- Loads TurkeyTickleUI_Cooking in a stubbed WoW environment and drives every view:
--   luajit tests/harness_cooking.lua TurkeyTickleUI_Cooking
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
				if k == "GetPoint" then return "CENTER", nil, "CENTER", 10, 20 end
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
	local scripts, shown, attributes = {}, false, {}
	f.SetScript = function(self, k, fn) scripts[k] = fn end
	f.HookScript = function(self, k, fn) scripts[k] = fn end
	f.GetScript = function(self, k) return scripts[k] or function() end end
	f.SetAttribute = function(self, k, v) attributes[k] = v end
	f.GetAttribute = function(self, k) return attributes[k] end
	local text
	f.SetText = function(self, t) text = t if scripts.OnTextChanged then scripts.OnTextChanged(self) end end
	f.GetText = function() return text end
	f.Show = function(self) shown = true if scripts.OnShow then scripts.OnShow(self) end end
	f.Hide = function() shown = false end
	f.SetShown = function(self, v) if v then self:Show() else self:Hide() end end
	f.IsShown = function() return shown end
	f.scripts = scripts
	return f
end

local initializer, mapFrames = nil, {}
function CreateFrame(kind, name, parent, template)
	local f = newFrame()
	f.SetParent = function(self, p) if p == WorldMapFrame:GetCanvas() then tinsert(mapFrames, self) end end
	if template == "WowScrollBoxList" then
		f.SetDataProvider = function(self, provider)
			for _, node in ipairs(provider.rows) do
				initializer(newFrame(), node)
			end
			f.lastRows = provider.rows
		end
	end
	if name then _G[name] = f end
	return f
end
function geterrorhandler() return function(e) print("LUA ERROR: " .. tostring(e)) print(debug.traceback()) os.exit(1) end end
function issecretvalue() return false end
function strsplit(sep, s) local out = {} for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = part end return unpack(out) end
strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
tinsert = table.insert
format = string.format
SlashCmdList = {}
UISpecialFrames = {}
local alerts = {}
UIErrorsFrame = { AddMessage = function(_, text) tinsert(alerts, text) end }
GameTooltip = stub()
local tooltipLines = {}
GameTooltip.AddLine = function(_, text) tinsert(tooltipLines, text) end
GameTooltip.SetText = function(_, text) tinsert(tooltipLines, text) end
GameTooltip.GetUnit = function() return nil end
GameTooltip_Hide = function() end
local printed = {}
local realPrint = print
print = function(...) local s = table.concat({ ... }, " ") tinsert(printed, s) realPrint(s) end
C_Timer = { After = function(_, fn) fn() end }
C_AddOns = { GetAddOnMetadata = function() return "0.1.0" end }
Settings = {
	RegisterCanvasLayoutCategory = function() return stub() end,
	RegisterCanvasLayoutSubcategory = function() return stub() end,
	RegisterAddOnCategory = function() end,
	OpenToCategory = function() end,
}
local now = 1000
function GetTime() return now end
function UnitLevel() return 14 end
function UnitFactionGroup() return "Alliance" end
function UnitGUID() return "Creature-0-1-2-3-830-0000" end
function IsShiftKeyDown() return false end
local resting = false
function IsResting() return resting end
function InCombatLockdown() return false end
function IsPlayerSpell() return false end
function CreateVector2D(x, y) return { x = x, y = y, GetXY = function(v) return v.x, v.y end } end
function CreateDataProvider(rows) return { rows = rows } end
function CreateScrollBoxListLinearView()
	local view = stub()
	view.SetElementInitializer = function(_, _, fn) initializer = fn end
	return view
end
ScrollUtil = { InitScrollBoxListWithScrollBar = function() end }
Enum = { UIMapType = { Continent = 2, Zone = 3 }, TooltipDataType = { Item = 0, Unit = 2 } }
ERR_LEARN_RECIPE_S = "You have learned how to create a new item: %s."

-- Cooking 40/75; Forever reports its own profession id, so the name is what matches.
local skill = { rank = 40, max = 75 }
function GetProfessions() return nil, nil, nil, nil, 5 end
function GetProfessionInfo(i) return "Cooking", 133971, skill.rank, skill.max, 0, 0, 8170, 0 end
local bags = { [2672] = 10, [2678] = 3, [2674] = 5, [769] = 4, [723] = 2 }
C_Item = {
	GetItemCount = function(id) return bags[id] or 0 end,
	GetItemNameByID = function() return nil end,
	GetItemIconByID = function() return 134021 end,
}
C_Spell = { GetSpellName = function(id) return id == 2550 and "Cooking" or nil end }
local cookingOpen = false
C_TradeSkillUI = {
	GetBaseProfessionInfo = function() return cookingOpen and { professionID = 8170, professionName = "Cooking" } or nil end,
	GetAllRecipeIDs = function() return { 2538, 2540, 818 } end,
	GetRecipeInfo = function(id) return { learned = true } end,
}

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
	GetBestMapForUnit = function() return 1436 end,
	GetPlayerMapPosition = function() return CreateVector2D(0.5, 0.5) end,
}

local canvas = newFrame()
canvas.GetWidth = function() return 1000 end
canvas.GetHeight = function() return 660 end
WorldMapFrame = newFrame()
WorldMapFrame:Show()
WorldMapFrame.mapID = 1436
WorldMapFrame.GetMapID = function(self) return self.mapID end
WorldMapFrame.GetCanvas = function() return canvas end
WorldMapFrame.GetCanvasScale = function() return 1.5 end
WorldMapFrame.GetCanvasZoomPercent = function() return 0 end
WorldMapFrame.GetPinFrameLevelsManager = function() return { GetValidFrameLevel = function() return 2000 end } end
C_Map.OpenWorldMap = function(id) WorldMapFrame.mapID = id end

local postCalls = {}
TooltipDataProcessor = { AddTooltipPostCall = function(kind, fn) postCalls[kind] = fn end }

local function shownPins()
	local n = 0
	for _, f in ipairs(mapFrames) do
		if rawget(f, "entry") and f:IsShown() then n = n + 1 end
	end
	return n
end

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
assert(ns.skill and ns.skill.rank == 40 and ns.skill.max == 75, "reads Cooking 40/75")
assert(ns.nudge, "cook button made")

-- Nothing known yet: the plan is empty until the Cooking window has been read.
assert(ns:Plan().gain == 0)
cookingOpen = true
fire("TRADE_SKILL_SHOW")
cookingOpen = false
assert(ns.char.known[2538] and ns.char.known[2540], "recorded known recipes from the Cooking window")
fire("CHAT_MSG_SYSTEM", "You have learned how to create a new item: |cffffffff|Hitem:2680|h[Spiced Wolf Meat]|h|r.")
assert(ns.char.known[2539], "learned Spiced Wolf Meat from chat")

local plan = ns:Plan()
print(format("plan: %.1f skill-ups to %.1f", plan.gain, plan.to))
for _, craft in ipairs(plan.crafts) do
	print("  cook", craft.recipe.name, craft.count, craft.color)
end
for _, buy in ipairs(plan.buy) do
	print("  buy for", buy.recipe.name, buy.count)
end
assert(plan.gain >= 10, "wolf and boar meat give skill-ups at 40")
assert(ns.nudge:IsShown(), "cook button shows while skill-ups are carried")
assert(ns.nudge:GetAttribute("spell1") == "Cooking")

-- Goretusk Liver Pie needs Cooking 50; a liver in the bags isn't worth anything yet.
assert(ns:ReagentValue(723) == 0)
assert(ns:ReagentValue(2672) > 0)

local targets = ns:HuntTargets()
print("hunt targets:", #targets)
for i = 1, math.min(5, #targets) do
	local t = targets[i]
	print(format("  %s (%s) %.2f/kill %s yd", t.npc.n, t.npc.lv, t.score, tostring(t.yards and math.floor(t.yards))))
end
assert(#targets > 0, "something to hunt at level 14")
for _, t in ipairs(targets) do
	assert((ns:MinLevel(t.npc.lv) or 0) <= 16, "no mobs far above the player")
	assert(not t.npc.faction, "no friendly NPCs")
end

-- Every tab, fully expanded.
local function expandAll(tab, maxDepth)
	ns:ShowBrowser(tab)
	local clicks = 0
	repeat
		local closed
		for _, node in ipairs(ns.browser.scroll.lastRows) do
			if node.children and not node.isOpen and node.depth < (maxDepth or math.huge) then
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
	until not closed or clicks > 3000
	for _, node in ipairs(ns.browser.scroll.lastRows) do
		if node.tooltip then node.tooltip(GameTooltip) end
	end
	return #ns.browser.scroll.lastRows
end
-- Recipes and their reagents only: every reagent's sources too is thousands of one-click refreshes.
for _, tab in ipairs({ "cook", "hunt", "recipes", "learn" }) do
	print(tab, "rows after expanding:", expandAll(tab, tab == "recipes" and 2 or nil))
end
ns:ShowBrowser("recipes", "crawler")
print("search 'crawler' rows:", #ns.browser.scroll.lastRows)
ns.browser.search:SetText("")

-- Tooltips.
tooltipLines = {}
postCalls[Enum.TooltipDataType.Unit](GameTooltip, { guid = "Creature-0-1-2-3-1133-0000" })
postCalls[Enum.TooltipDataType.Item](GameTooltip, { id = 2672 })
postCalls[Enum.TooltipDataType.Item](GameTooltip, { id = 2697 })
for _, line in ipairs(tooltipLines) do print("  tooltip:", line) end

-- Map: suggested hunting mobs on Westfall, then a pin.
local function mapFrame() ns.mapWatcher.scripts.OnUpdate(ns.mapWatcher, 0.016) end
mapFrame()
print("pins on Westfall (suggested):", shownPins())
ns:ShowOnMap(targets[1].id)
mapFrame()
print("after pinning, pins:", shownPins())
SlashCmdList.TURKEYTICKLEUI_COOKING("clear")

-- Reminders: resting with a pile of meat, then the cap warning.
resting = true
fire("PLAYER_UPDATE_RESTING")
assert(#alerts == 1, "resting reminder flashed")
fire("PLAYER_UPDATE_RESTING")
assert(#alerts == 1, "reminders wait their cooldown")
skill.rank = 72
fire("CHAT_MSG_SKILL", "Your skill in Cooking has increased to 72.")
assert(#alerts == 2, "cap warning at 72/75")
skill.rank = 75
fire("SKILL_LINES_CHANGED")
assert(ns:Plan().capped and not ns.nudge:IsShown(), "capped: nothing to cook")
SlashCmdList.TURKEYTICKLEUI_COOKING("status")

-- New bag contents.
skill.rank, skill.max = 40, 75
fire("SKILL_LINES_CHANGED")
bags[2672] = 30
now = now + 3600
fire("BAG_UPDATE_DELAYED")
print("after looting more wolf meat:", ns:Plan().gain)

-- No Cooking at all.
function GetProfessions() return nil end
GetNumSkillLines, GetSkillLineInfo = function() return 0 end, function() end
fire("SKILL_LINES_CHANGED")
assert(ns:Plan().noSkill)
SlashCmdList.TURKEYTICKLEUI_COOKING("status")
expandAll("cook")
expandAll("hunt")
SlashCmdList.TURKEYTICKLEUI_COOKING("reset")
print("done")
