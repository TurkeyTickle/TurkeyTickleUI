local _, ns = ...

local GREY, GOLD = "|cff9d9d9d", "|cffe8a33d"

local function isSecret(v)
	return issecretvalue and issecretvalue(v)
end

function ns:NpcIcon(npcID)
	if self.trainers[npcID] then
		return self.ICON
	end
	local drops = self.mobDrops[npcID]
	if drops then
		local best, bestValue = drops[1][1], -1
		for _, drop in ipairs(drops) do
			local value = self:ReagentValue(drop[1]) * drop[2]
			if value > bestValue then
				best, bestValue = drop[1], value
			end
		end
		return self:ItemIcon(best)
	end
	return "Interface\\Icons\\INV_Misc_Bag_10"
end

-- "Crawler Meat 43% (Crab Cake)" for each cooking drop, coloured by what it's worth to you now.
function ns:DropLines(npcID)
	local lines = {}
	for _, drop in ipairs(self.mobDrops[npcID] or {}) do
		local value, recipe = self:ReagentValue(drop[1])
		local text = format("%s %d%%", self:ItemName(drop[1]), math.floor(drop[2] + 0.5))
		if recipe then
			text = format("|cffffffff%s|r  %s", text, self:ColoredName(recipe))
		else
			text = GREY .. text .. "  (no skill-ups for you now)|r"
		end
		tinsert(lines, { text = text, value = value })
	end
	table.sort(lines, function(a, b)
		return a.value > b.value
	end)
	return lines
end

function ns:FillTooltip(tooltip, npcID, npc, isPin)
	tooltip:SetText(npc.n .. (npc.sub and (" <" .. npc.sub .. ">") or ""), 1, 0.82, 0)
	if npc.lv ~= "" then
		tooltip:AddLine(format("%sLevel %s|r%s", self:LevelColor(npc.lv), npc.lv, npc.elite and " Elite" or ""), 1, 1, 1)
	end
	if self.trainers[npcID] then
		tooltip:AddLine("Cooking Trainer", 1, 1, 1)
	end
	if self.mobDrops[npcID] then
		local score = self:MobValue(npcID)
		if score > 0 then
			tooltip:AddLine(format("About %.2f Cooking skill-ups per kill", score), 0.4, 1, 0.4)
		end
		for _, line in ipairs(self:DropLines(npcID)) do
			tooltip:AddLine(line.text, 1, 1, 1)
		end
	end
	tooltip:AddLine(self:ZoneName(npc), 0.7, 0.7, 0.7)
	local yards = self:NearestSpawn(npcID, npc)
	if yards then
		tooltip:AddLine(format("About %d yards away", yards), 0.7, 0.7, 0.7)
	end
	if isPin then
		tooltip:AddLine(" ")
		tooltip:AddLine(TomTom and "Click: TomTom waypoint" or "Click: print coordinates", 0.5, 0.8, 1)
		tooltip:AddLine(self:IsTracked(npcID) and "Shift-click: unpin" or "Shift-click: pin", 0.5, 0.8, 1)
	end
end

-- What a recipe means for you: known or how to learn it, and its colour.
function ns:RecipeStatus(recipe)
	local color = self:Difficulty(recipe)
	local status
	if self:IsKnown(recipe) then
		status = "known"
	elseif self:CanLearnNow(recipe) then
		status = "learn: " .. self:LearnSourceText(recipe)
	else
		status = format("learn at %d", self:LearnSkill(recipe))
	end
	return format("%s%s|r %s(%s, %s)|r", self.colorCodes[color], recipe.name, GREY, self.colorNames[color], status)
end

-- Item tooltips ------------------------------------------------------------------

local MAX_RECIPES = 4

local function addItemLines(tooltip, itemID)
	if not ns.skill then
		return false
	end
	local scrollRecipe = ns.scrollRecipe[itemID]
	if scrollRecipe then
		local known = ns:IsKnown(scrollRecipe)
		tooltip:AddLine(GOLD .. "Cooking:|r " .. (known and (GREY .. "you already know this|r") or ns:RecipeStatus(scrollRecipe)), 1, 1, 1)
		return true
	end
	local recipes = ns.usedIn[itemID]
	if not recipes then
		return false
	end
	local list = {}
	for _, recipe in ipairs(recipes) do
		if ns:IsKnown(recipe) or ns:Difficulty(recipe) ~= "grey" then
			tinsert(list, recipe)
		end
	end
	table.sort(list, function(a, b)
		local ca, cb = ns:SkillUpChance(a), ns:SkillUpChance(b)
		if ca ~= cb then
			return ca > cb
		end
		return a.t[2] < b.t[2]
	end)
	if #list == 0 then
		tooltip:AddLine(GOLD .. "Cooking:|r " .. GREY .. "only grey recipes use this; sell it or eat it|r", 1, 1, 1)
		return true
	end
	tooltip:AddLine(GOLD .. "Cooking:|r", 1, 1, 1)
	for i, recipe in ipairs(list) do
		if i > MAX_RECIPES then
			tooltip:AddLine(format("  %s...and %d more|r", GREY, #list - MAX_RECIPES))
			break
		end
		tooltip:AddLine("  " .. ns:RecipeStatus(recipe), 1, 1, 1)
	end
	return true
end

local function itemIDFrom(tooltip, data)
	local id = data and data.id
	if type(id) == "number" and not isSecret(id) then
		return id
	end
	if tooltip.GetItem then
		local _, link = tooltip:GetItem()
		if type(link) == "string" and not isSecret(link) then
			return tonumber(link:match("item:(%d+)"))
		end
	end
end

local function onItemTooltip(tooltip, data)
	if not ns.db.tooltips or (tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip) then
		return
	end
	local itemID = itemIDFrom(tooltip, data)
	if itemID and addItemLines(tooltip, itemID) then
		tooltip:Show()
	end
end

-- Unit tooltips ------------------------------------------------------------------

local function npcIDFromGUID(guid)
	if type(guid) ~= "string" or isSecret(guid) then
		return nil
	end
	local kind, _, _, _, _, id = strsplit("-", guid)
	if kind == "Creature" then
		return tonumber(id)
	end
end

local function onUnitTooltip(tooltip, data)
	if not ns.db.unitTooltips or tooltip ~= GameTooltip or not ns.skill then
		return
	end
	local npcID = npcIDFromGUID(data and data.guid)
	if not npcID then
		local _, unit = tooltip:GetUnit()
		if unit and not isSecret(unit) then
			npcID = npcIDFromGUID(UnitGUID(unit))
		end
	end
	if not (npcID and ns.mobDrops[npcID]) then
		return
	end
	local lines = ns:DropLines(npcID)
	if lines[1].value <= 0 then
		return
	end
	tooltip:AddLine(GOLD .. "Cooking:|r " .. lines[1].text, 1, 1, 1)
	for i = 2, #lines do
		if lines[i].value > 0 then
			tooltip:AddLine("  " .. lines[i].text, 1, 1, 1)
		end
	end
	tooltip:Show()
end

function ns:InitTooltip()
	local processor = TooltipDataProcessor
	local types = Enum and Enum.TooltipDataType
	if processor and processor.AddTooltipPostCall and types then
		if types.Unit then
			processor.AddTooltipPostCall(types.Unit, function(tooltip, data)
				xpcall(onUnitTooltip, geterrorhandler(), tooltip, data)
			end)
		end
		if types.Item then
			processor.AddTooltipPostCall(types.Item, function(tooltip, data)
				xpcall(onItemTooltip, geterrorhandler(), tooltip, data)
			end)
		end
	elseif GameTooltip and GameTooltip.HookScript then
		GameTooltip:HookScript("OnTooltipSetUnit", function(tooltip)
			xpcall(onUnitTooltip, geterrorhandler(), tooltip)
		end)
		GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
			xpcall(onItemTooltip, geterrorhandler(), tooltip)
		end)
	end
end
