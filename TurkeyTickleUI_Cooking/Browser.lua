local _, ns = ...

local ROW_HEIGHT = 20
local INDENT = 14
local TABS = {
	{ key = "cook", label = "Cook now" },
	{ key = "hunt", label = "Hunt" },
	{ key = "recipes", label = "Recipes" },
	{ key = "learn", label = "Learn" },
}
local HUNT_LIMIT = 30
local VENDOR_LIMIT = 8

local GREEN, GREY, GOLD = "|cff40ff40", "|cff9d9d9d", "|cffffd100"

local expanded = { crafts = true, buy = true, carry = true, best = true, rank = true, now = true }
local playerPos = {}

local function stripCodes(text)
	return (text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
end

local function distance(npcID)
	return ns:NearestSpawn(npcID, ns.npcs[npcID], playerPos)
end

local function yardsText(yards)
	return yards and format(" %s%dyd|r", GREY, yards) or ""
end

local function byDistance(ids)
	local faction = ns:PlayerFaction()
	local list = {}
	for _, npcID in ipairs(ids) do
		local npc = ns.npcs[npcID]
		if npc and (not npc.faction or not faction or npc.faction == faction) then
			tinsert(list, npcID)
		end
	end
	table.sort(list, function(a, b)
		local da, db = distance(a) or math.huge, distance(b) or math.huge
		if da ~= db then
			return da < db
		end
		return a < b
	end)
	return list
end

local function trainerIDs()
	local ids = {}
	for npcID in pairs(ns.trainers) do
		tinsert(ids, npcID)
	end
	return byDistance(ids)
end

-- Nodes -------------------------------------------------------------------------
-- { id, text, right, icon, search, children = fn, npcID | npcIDs, recipe, tooltip = fn }

local function npcNode(parentID, npcID, label)
	local npc = ns.npcs[npcID]
	local text = npc.n
	if npc.lv ~= "" and ns.mobDrops[npcID] then
		text = format("%s  %s(%s)|r", text, ns:LevelColor(npc.lv), npc.lv)
	end
	if label then
		text = text .. "  " .. label
	end
	local zone = ns:ZoneName(npc)
	return {
		id = parentID .. ":" .. npcID,
		icon = ns:NpcIcon(npcID),
		text = text,
		right = zone .. yardsText(distance(npcID)),
		search = zone,
		npcID = npcID,
		tooltip = function(tooltip)
			ns:FillTooltip(tooltip, npcID, npc)
		end,
	}
end

local function npcList(parentID, ids, limit, label)
	local kids = {}
	for i, npcID in ipairs(byDistance(ids)) do
		if limit and i > limit then
			break
		end
		tinsert(kids, npcNode(parentID, npcID, label and label(npcID)))
	end
	return kids
end

function ns:RecipeTooltip(tooltip, recipe)
	tooltip:SetText(recipe.name, 1, 0.82, 0)
	local t = recipe.t
	tooltip:AddLine(format("%s%d|r  %s%d|r  %s%d|r  %s%d|r", self.colorCodes.orange, math.max(t[1], self:LearnSkill(recipe)),
		self.colorCodes.yellow, t[2], self.colorCodes.green, t[3], self.colorCodes.grey, t[4]), 1, 1, 1)
	if self.skill then
		local color = self:Difficulty(recipe)
		tooltip:AddLine(format("At %d it's %s%s|r: %d%% chance of a skill-up per craft", self:Skill(), self.colorCodes[color],
			self.colorNames[color], self:SkillUpChance(recipe) * 100 + 0.5), 1, 1, 1)
	end
	tooltip:AddLine(" ")
	for _, reagent in ipairs(recipe.r) do
		local have = self:Count(reagent[1])
		local color = have >= reagent[2] and "|cffffffff" or GREY
		tooltip:AddLine(format("%s%dx %s|r  %s(have %d)|r%s", color, reagent[2], self:ItemName(reagent[1]), GREY, have,
			self:IsBuyable(reagent[1]) and "  |cff80c0ffvendor|r" or ""), 1, 1, 1)
	end
	tooltip:AddLine(" ")
	if self:IsKnown(recipe) then
		tooltip:AddLine("You know this recipe.", 0.4, 1, 0.4)
	else
		tooltip:AddLine(format("Learn: %s, needs Cooking %d", self:LearnSourceText(recipe), self:LearnSkill(recipe)), 1, 1, 1)
	end
	tooltip:AddLine("Shift-click to mark as known / not known.", 0.5, 0.8, 1)
end

local function reagentSourceNodes(parentID, itemID)
	local item = ns.items[itemID] or {}
	local kids = {}
	if item.fish then
		tinsert(kids, { id = parentID .. ":fish", icon = "Interface\\Icons\\Trade_Fishing", text = "Caught by fishing" })
	end
	if item.vendors then
		local ids = item.vendors
		tinsert(kids, {
			id = parentID .. ":vendors", icon = "Interface\\Icons\\INV_Misc_Bag_10",
			text = format("Sold by vendors  %s%s each|r", GREY, ns:Money(item.price)),
			npcIDs = byDistance(ids),
			children = function()
				return npcList(parentID .. ":vendors", ids, VENDOR_LIMIT)
			end,
		})
	end
	if item.drops then
		local chance = {}
		local ids = {}
		for _, drop in ipairs(item.drops) do
			chance[drop[1]] = drop[2]
			tinsert(ids, drop[1])
		end
		for _, node in ipairs(npcList(parentID, ids, nil, function(npcID)
			return format("%s%d%%|r", GREEN, math.floor(chance[npcID] + 0.5))
		end)) do
			tinsert(kids, node)
		end
	end
	return kids
end

local function reagentNode(parentID, itemID, need)
	local id = parentID .. ":" .. itemID
	local have = ns:Count(itemID)
	local text = ns:ItemName(itemID)
	if need then
		text = format("%s%dx|r %s", have >= need and "|cffffffff" or GREY, need, text)
	end
	return {
		id = id,
		icon = ns:ItemIcon(itemID),
		text = text,
		right = format("have %d", have),
		children = function()
			return reagentSourceNodes(id, itemID)
		end,
		tooltip = function(tooltip)
			tooltip:SetItemByID(itemID)
		end,
	}
end

local function learnSourceNodes(parentID, recipe)
	if not recipe.scroll then
		local kids = {}
		for i, npcID in ipairs(trainerIDs()) do
			if i > VENDOR_LIMIT then
				break
			end
			tinsert(kids, npcNode(parentID, npcID))
		end
		return kids
	end
	local item = recipe.scroll and ns.items[recipe.scroll]
	if not item then
		return {}
	end
	local kids = {}
	if item.vendors then
		for _, node in ipairs(npcList(parentID .. ":v", item.vendors, VENDOR_LIMIT, function()
			return GREY .. ns:Money(item.price) .. "|r"
		end)) do
			tinsert(kids, node)
		end
	end
	if item.drops then
		for _, node in ipairs(npcList(parentID .. ":d", (function()
			local ids = {}
			for _, drop in ipairs(item.drops) do
				tinsert(ids, drop[1])
			end
			return ids
		end)(), nil, function()
			return GREY .. "drops it|r"
		end)) do
			tinsert(kids, node)
		end
	end
	if item.quests then
		tinsert(kids, { id = parentID .. ":quest", icon = "Interface\\GossipFrame\\AvailableQuestIcon",
			text = GREY .. "Also a quest reward|r" })
	end
	if item.worldDrop then
		tinsert(kids, { id = parentID .. ":world", icon = "Interface\\Icons\\INV_Misc_Bag_10",
			text = GREY .. "World drop: check the auction house|r" })
	end
	return kids
end

local function recipeNode(parentID, recipe, text, right)
	local id = parentID .. ":" .. recipe.id
	local known = ns:IsKnown(recipe)
	return {
		id = id,
		icon = ns:RecipeIcon(recipe),
		text = text or (ns:ColoredName(recipe) .. (known and "" or (GREY .. "  (not learned)|r"))),
		right = right or (known and GREY .. "known|r" or ns:LearnSourceText(recipe)),
		search = (function()
			local names = {}
			for _, reagent in ipairs(recipe.r) do
				tinsert(names, ns:ItemName(reagent[1]))
			end
			return table.concat(names, " ")
		end)(),
		recipe = recipe,
		children = function()
			local kids = {}
			for _, reagent in ipairs(recipe.r) do
				tinsert(kids, reagentNode(id, reagent[1], reagent[2]))
			end
			if not known then
				tinsert(kids, {
					id = id .. ":learn", icon = "Interface\\Icons\\INV_Scroll_03",
					text = GOLD .. "Where to learn it|r", right = ns:LearnSourceText(recipe),
					children = function()
						return learnSourceNodes(id .. ":learn", recipe)
					end,
				})
			end
			return kids
		end,
		tooltip = function(tooltip)
			ns:RecipeTooltip(tooltip, recipe)
		end,
	}
end

local function note(id, text, icon)
	return { id = id, icon = icon or ns.ICON, text = text }
end

-- Tabs ------------------------------------------------------------------------------

local function rankNode()
	local rank = ns:NextRank()
	if not rank then
		return nil
	end
	local ready = ns:ReadyForNextRank()
	local node = {
		id = "rank",
		icon = "Interface\\Icons\\INV_Misc_Book_11",
		text = (ready and GREEN or GOLD) .. format("Next rank: cap %d|r", rank.cap),
		right = ready and GREEN .. "ready now|r" or format("Cooking %d, level %d", rank.skill, rank.level),
		tooltip = function(tooltip)
			tooltip:SetText(format("Cooking cap %d", rank.cap), 1, 0.82, 0)
			tooltip:AddLine(ns:NextRankText(rank), 1, 1, 1, true)
		end,
	}
	if rank.fee then
		node.npcIDs = trainerIDs()
		node.children = function()
			return npcList("rank", node.npcIDs, VENDOR_LIMIT)
		end
	elseif rank.book and ns.items[rank.book] and ns.items[rank.book].vendors then
		node.npcIDs = byDistance(ns.items[rank.book].vendors)
		node.children = function()
			return npcList("rank", node.npcIDs, VENDOR_LIMIT)
		end
	else
		node.children = function()
			return { note("rank:quest", ns:NextRankText(rank), "Interface\\GossipFrame\\AvailableQuestIcon") }
		end
	end
	return node
end

local function cookTree()
	local plan = ns:Plan()
	local nodes = {}
	for i, line in ipairs(ns:StatusLines()) do
		tinsert(nodes, note("status:" .. i, line))
	end
	if plan.noSkill then
		tinsert(nodes, { id = "trainers", icon = ns.ICON, text = GOLD .. "Cooking trainers|r", npcIDs = trainerIDs(),
			children = function()
				return npcList("trainers", trainerIDs(), VENDOR_LIMIT)
			end })
		return nodes
	end
	if #plan.crafts > 0 then
		tinsert(nodes, {
			id = "crafts", icon = ns.ICON,
			text = format("%sCook these now|r  %sabout %d skill-ups|r", GOLD, GREEN, plan.gain),
			children = function()
				local kids = {}
				for _, craft in ipairs(plan.crafts) do
					local text = format("%s x%d", ns:ColoredName(craft.recipe), craft.count)
					local right = format("%s%d%%|r chance", ns.colorCodes[craft.color], ns:SkillUpChance(craft.recipe) * 100 + 0.5)
					tinsert(kids, recipeNode("crafts", craft.recipe, text, right))
				end
				if ns:Count(4470) == 0 and ns:Count(279981) == 0 then
					tinsert(kids, note("crafts:fire", GREY .. "No Simple Wood for a Basic Campfire: cook at any fire, or buy wood from a trade goods vendor.|r",
						"Interface\\Icons\\Spell_Fire_Fire"))
				end
				return kids
			end,
		})
	end
	if #plan.buy > 0 then
		tinsert(nodes, {
			id = "buy", icon = "Interface\\Icons\\INV_Misc_Bag_10", text = GOLD .. "Buy a little, cook a lot more|r",
			children = function()
				local kids = {}
				for _, buy in ipairs(plan.buy) do
					local parts, cost = {}, 0
					for _, item in ipairs(buy.items) do
						tinsert(parts, format("%d %s", item[2], ns:ItemName(item[1])))
						cost = cost + item[2] * ((ns.items[item[1]] or {}).price or 0)
					end
					local node = recipeNode("buy", buy.recipe, format("%s x%d: buy %s", ns:ColoredName(buy.recipe), buy.count,
						table.concat(parts, ", ")), ns:Money(cost))
					node.children = function()
						local list = {}
						for _, item in ipairs(buy.items) do
							for _, kid in ipairs(reagentSourceNodes("buy:" .. buy.recipe.id .. ":" .. item[1], item[1])) do
								tinsert(list, kid)
							end
						end
						return list
					end
					tinsert(kids, node)
				end
				return kids
			end,
		})
	end
	local carry = {}
	for _, target in ipairs(ns:LearnTargets(0)) do
		if target.held > 0 and ns:SkillUpChance(target.recipe) > 0 then
			tinsert(carry, target)
		end
	end
	if #carry > 0 then
		tinsert(nodes, {
			id = "carry", icon = "Interface\\Icons\\INV_Scroll_03", text = GOLD .. "Learn these to use what you're carrying|r",
			children = function()
				local kids = {}
				for _, target in ipairs(carry) do
					tinsert(kids, recipeNode("carry", target.recipe, format("%s  %s(can make %d)|r",
						ns:ColoredName(target.recipe), GREY, target.held)))
				end
				return kids
			end,
		})
	end
	local grey = {}
	for itemID, count in pairs(ns.bag) do
		if ns.usedIn[itemID] and not ns:IsBuyable(itemID) and ns:ReagentValue(itemID) == 0 then
			tinsert(grey, { itemID, count })
		end
	end
	if #grey > 0 then
		table.sort(grey, function(a, b)
			return a[1] < b[1]
		end)
		tinsert(nodes, {
			id = "grey", icon = "Interface\\Icons\\INV_Misc_Coin_02", text = GREY .. "No skill-ups for you: sell, bank or eat|r",
			children = function()
				local kids = {}
				for _, entry in ipairs(grey) do
					local node = reagentNode("grey", entry[1])
					node.text = format("%s x%d", ns:ItemName(entry[1]), entry[2])
					tinsert(kids, node)
				end
				return kids
			end,
		})
	end
	local rank = rankNode()
	if rank and (ns:IsCapped() or ns:ReadyForNextRank()) then
		tinsert(nodes, rank)
	end
	return nodes
end

local function huntTree()
	if not ns.skill then
		return { note("hunt:none", "Learn Cooking first: see the Cook now tab.") }
	end
	local targets = ns:HuntTargets(playerPos)
	local nodes = {}
	if #targets == 0 then
		tinsert(nodes, note("hunt:none", GREY .. "No mobs at your level drop meat you can level with right now. Check the Learn tab for new recipes.|r"))
		return nodes
	end
	local ids = {}
	for i, target in ipairs(targets) do
		if i > HUNT_LIMIT then
			break
		end
		tinsert(ids, target.id)
	end
	tinsert(nodes, {
		id = "best", icon = "Interface\\Icons\\Ability_Hunter_SniperShot",
		text = GOLD .. "Best mobs to hunt|r  " .. GREY .. "(skill-ups per kill, nearest first)|r",
		npcIDs = ids,
		children = function()
			local kids = {}
			for i, target in ipairs(targets) do
				if i > HUNT_LIMIT then
					break
				end
				local node = npcNode("best", target.id, format("%s%.2f/kill|r", GREEN, target.score))
				local names = {}
				for _, drop in ipairs(target.drops) do
					tinsert(names, ns:ItemName(drop.item))
				end
				node.search = node.search .. " " .. table.concat(names, " ")
				tinsert(kids, node)
			end
			return kids
		end,
	})
	local items = {}
	for itemID in pairs(ns.usedIn) do
		local value, recipe = ns:ReagentValue(itemID)
		local item = ns.items[itemID]
		if value > 0 and item and not item.vendors and (item.drops or item.fish) then
			tinsert(items, { itemID = itemID, value = value, recipe = recipe })
		end
	end
	table.sort(items, function(a, b)
		if a.value ~= b.value then
			return a.value > b.value
		end
		return a.itemID < b.itemID
	end)
	tinsert(nodes, {
		id = "byitem", icon = "Interface\\Icons\\INV_Misc_Food_14", text = GOLD .. "By ingredient|r",
		children = function()
			local kids = {}
			for _, entry in ipairs(items) do
				local node = reagentNode("byitem", entry.itemID)
				node.text = format("%s  %s", ns:ItemName(entry.itemID), ns:ColoredName(entry.recipe))
				node.right = (ns.items[entry.itemID].fish and "fishing  " or "") .. format("have %d", ns:Count(entry.itemID))
				tinsert(kids, node)
			end
			return kids
		end,
	})
	return nodes
end

local ORDER = { "orange", "yellow", "green", "red", "grey" }
local GROUP_NAMES = {
	orange = "Orange: a point every craft",
	yellow = "Yellow: usually a point",
	green = "Green: sometimes a point",
	red = "Not yet: skill too low",
	grey = "Grey: no more points",
}

local function recipesTree()
	local groups = {}
	for _, recipe in ipairs(ns.recipes) do
		local color = ns.skill and ns:Difficulty(recipe) or "red"
		groups[color] = groups[color] or {}
		tinsert(groups[color], recipe)
	end
	local nodes = {}
	for _, color in ipairs(ORDER) do
		local list = groups[color]
		if list then
			local known = 0
			for _, recipe in ipairs(list) do
				if ns:IsKnown(recipe) then
					known = known + 1
				end
			end
			local id = "group:" .. color
			tinsert(nodes, {
				id = id,
				icon = ns.ICON,
				text = ns.colorCodes[color] .. GROUP_NAMES[color] .. "|r",
				right = format("%d known / %d", known, #list),
				children = function()
					local kids = {}
					for _, recipe in ipairs(list) do
						if not ns.db.onlyKnown or ns:IsKnown(recipe) then
							tinsert(kids, recipeNode(id, recipe))
						end
					end
					return kids
				end,
			})
		end
	end
	return nodes
end

local function learnTree()
	local nodes = {}
	local rank = rankNode()
	if rank then
		tinsert(nodes, rank)
	end
	local now, soon = {}, {}
	for _, target in ipairs(ns:LearnTargets(25)) do
		tinsert(target.now and now or soon, target)
	end
	local function group(id, title, list)
		tinsert(nodes, {
			id = id, icon = "Interface\\Icons\\INV_Scroll_03", text = title, right = #list .. " recipes",
			children = function()
				local kids = {}
				for _, target in ipairs(list) do
					local held = target.held > 0 and format("  %s(can make %d)|r", GREY, target.held) or ""
					tinsert(kids, recipeNode(id, target.recipe, ns:ColoredName(target.recipe) .. held))
				end
				return kids
			end,
		})
	end
	if ns.skill then
		group("now", GOLD .. "Worth learning now|r", now)
		group("soon", GOLD .. "Coming up in the next 25 points|r", soon)
	end
	tinsert(nodes, { id = "trainers", icon = ns.ICON, text = GOLD .. "Cooking trainers|r", npcIDs = trainerIDs(),
		children = function()
			return npcList("trainers", trainerIDs())
		end })
	return nodes
end

local TREES = { cook = cookTree, hunt = huntTree, recipes = recipesTree, learn = learnTree }

-- Flattening --------------------------------------------------------------------

local function flatten(nodes, depth, out, query)
	local anyMatch = false
	for _, node in ipairs(nodes) do
		node.depth = depth
		local selfMatch = not query or stripCodes(node.text):lower():find(query, 1, true)
			or (node.search and node.search:lower():find(query, 1, true))
		local isOpen = expanded[node.id]
		local kids = node.children and (isOpen or query) and node.children() or nil
		local childOut = {}
		local childMatch = kids and flatten(kids, depth + 1, childOut, (not selfMatch) and query or nil) or false
		if selfMatch or childMatch then
			anyMatch = true
			tinsert(out, node)
			node.isOpen = node.children and (isOpen or (query and childMatch and not selfMatch)) and true or false
			if node.isOpen then
				for _, child in ipairs(childOut) do
					tinsert(out, child)
				end
			end
		end
	end
	return anyMatch
end

-- Rows ----------------------------------------------------------------------------

local function showNodeOnMap(node)
	if node.npcID then
		ns:ShowOnMap(node.npcID)
		return
	end
	local first, count = nil, 0
	for _, npcID in ipairs(node.npcIDs or {}) do
		local npc = ns.npcs[npcID]
		if npc and npc.s then
			ns.char.tracked[npcID] = true
			first = first or npcID
			count = count + 1
		end
	end
	if first then
		ns:ShowOnMap(first)
		ns:Print(format("Pinned %d on the map. Shift-click a pin or use Clear pins to remove them.", count))
	else
		ns:Print("No map locations known for these.")
	end
end

local function initRow(row)
	if row.label then
		return
	end
	row:SetHeight(ROW_HEIGHT)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
	row.highlight:SetAllPoints()
	row.highlight:SetColorTexture(1, 1, 1, 0.08)
	row.toggle = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	row.toggle:SetWidth(12)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("LEFT", row.toggle, "RIGHT", 2, 0)
	row.mapButton = CreateFrame("Button", nil, row)
	row.mapButton:SetSize(16, 16)
	row.mapButton:SetPoint("RIGHT", -2, 0)
	row.mapButton.icon = row.mapButton:CreateTexture(nil, "ARTWORK")
	row.mapButton.icon:SetAllPoints()
	row.mapButton.icon:SetTexture("Interface\\Icons\\INV_Misc_Map_01")
	row.mapButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	row.mapButton:SetScript("OnClick", function(self)
		showNodeOnMap(self:GetParent().node)
	end)
	row.mapButton:SetScript("OnEnter", function(self)
		local node = self:GetParent().node
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(node.npcID and "Show on world map" or "Pin all on world map", 1, 1, 1)
		GameTooltip:Show()
	end)
	row.mapButton:SetScript("OnLeave", GameTooltip_Hide)
	row.right = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.right:SetPoint("RIGHT", row.mapButton, "LEFT", -6, 0)
	row.right:SetJustifyH("RIGHT")
	row.right:SetWordWrap(false)
	row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
	row.label:SetPoint("RIGHT", row.right, "LEFT", -8, 0)
	row.label:SetJustifyH("LEFT")
	row.label:SetWordWrap(false)

	row:SetScript("OnClick", function(self, button)
		local node = self.node
		if IsShiftKeyDown() and node.recipe then
			ns:SetKnown(node.recipe, not ns:IsKnown(node.recipe))
		elseif node.children then
			expanded[node.id] = not node.isOpen or nil
			ns.browser:Refresh()
		elseif node.npcID and button == "RightButton" then
			ns:SetTracked(node.npcID, not ns:IsTracked(node.npcID))
		elseif node.npcID then
			ns:ShowOnMap(node.npcID)
		end
	end)
	row:SetScript("OnEnter", function(self)
		if self.node.tooltip then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			self.node.tooltip(GameTooltip)
			GameTooltip:Show()
		end
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
end

local function renderRow(row, node)
	initRow(row)
	row.node = node
	row.toggle:ClearAllPoints()
	row.toggle:SetPoint("LEFT", 4 + node.depth * INDENT, 0)
	row.toggle:SetText(node.children and (node.isOpen and "-" or "+") or "")
	row.icon:SetShown(node.icon ~= nil)
	row.icon:SetTexture(node.icon)
	row.label:SetText(node.text)
	row.right:SetText(node.right or "")
	local npc = node.npcID and ns.npcs[node.npcID]
	local mappable = npc and npc.s or (node.npcIDs and #node.npcIDs > 0)
	row.mapButton:SetShown(mappable and true or false)
	row.mapButton.icon:SetDesaturated(node.npcID and not ns:IsTracked(node.npcID) or false)
end

-- Window ----------------------------------------------------------------------------

local function createCookButton(frame, anchor)
	-- Casting is protected, so the button is a secure spell button; those can't be made in combat.
	if InCombatLockdown() then
		return anchor
	end
	local cook = CreateFrame("Button", nil, frame, "SecureActionButtonTemplate, UIPanelButtonTemplate")
	cook:SetSize(110, 22)
	cook:SetPoint("RIGHT", anchor, "LEFT", -6, 0)
	cook:SetText("Open Cooking")
	cook:RegisterForClicks("AnyUp", "AnyDown")
	cook:SetAttribute("type", "spell")
	cook:SetAttribute("spell", ns:CookingSpellName())
	cook:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Open Cooking", 1, 1, 1)
		GameTooltip:AddLine("Opening it also records which recipes you know.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	cook:HookScript("OnLeave", GameTooltip_Hide)
	return cook
end

local function createBrowser()
	local frame = CreateFrame("Frame", "TurkeyTickleUICookingBrowser", UIParent, "PortraitFrameTemplate")
	-- The gamepad interface's menus also close UISpecialFrames, from secure code.
	if not ns:GamepadUI() then
		tinsert(UISpecialFrames, "TurkeyTickleUICookingBrowser")
	end
	frame:SetSize(640, 620)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	if frame.SetTitle then
		frame:SetTitle("Cooking Helper")
	end
	if frame.SetPortraitToAsset then
		frame:SetPortraitToAsset(ns.ICON)
	elseif frame.GetPortrait and frame:GetPortrait() then
		frame:GetPortrait():SetTexture(ns.ICON)
	end

	frame.tabs = {}
	local prev
	for _, tab in ipairs(TABS) do
		local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		button:SetSize(110, 22)
		if prev then
			button:SetPoint("LEFT", prev, "RIGHT", 4, 0)
		else
			button:SetPoint("TOPLEFT", 62, -32)
		end
		button:SetText(tab.label)
		button:SetScript("OnClick", function()
			frame.tab = tab.key
			frame:Refresh()
		end)
		frame.tabs[tab.key] = button
		prev = button
	end

	local search = CreateFrame("EditBox", nil, frame, "SearchBoxTemplate")
	search:SetSize(200, 20)
	search:SetPoint("TOPLEFT", 66, -62)
	search:SetAutoFocus(false)
	search:HookScript("OnTextChanged", function()
		frame:Refresh()
	end)
	frame.search = search

	local onlyKnown = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	onlyKnown:SetSize(24, 24)
	onlyKnown:SetPoint("LEFT", search, "RIGHT", 12, 0)
	onlyKnown.label = onlyKnown:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	onlyKnown.label:SetPoint("LEFT", onlyKnown, "RIGHT", 2, 1)
	onlyKnown.label:SetText("Only recipes I know")
	onlyKnown:SetScript("OnClick", function(self)
		ns.db.onlyKnown = self:GetChecked() and true or false
		frame:Refresh()
	end)
	frame.onlyKnown = onlyKnown

	local inset = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
	inset:SetPoint("TOPLEFT", 12, -90)
	inset:SetPoint("BOTTOMRIGHT", -12, 40)

	local scroll = CreateFrame("Frame", nil, inset, "WowScrollBoxList")
	scroll:SetPoint("TOPLEFT", 4, -4)
	scroll:SetPoint("BOTTOMRIGHT", -22, 4)
	local scrollBar = CreateFrame("EventFrame", nil, inset, "MinimalScrollBar")
	scrollBar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
	scrollBar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(ROW_HEIGHT)
	view:SetElementInitializer("Button", renderRow)
	ScrollUtil.InitScrollBoxListWithScrollBar(scroll, scrollBar, view)
	frame.scroll = scroll

	local clear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	clear:SetSize(90, 22)
	clear:SetPoint("BOTTOMRIGHT", -14, 12)
	clear:SetText("Clear pins")
	clear:SetScript("OnClick", function()
		ns:ClearTracked()
	end)

	local options = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	options:SetSize(80, 22)
	options:SetPoint("RIGHT", clear, "LEFT", -6, 0)
	options:SetText("Options")
	options:SetScript("OnClick", function()
		ns:OpenOptions()
	end)

	local footerLeft = createCookButton(frame, options)

	frame.footer = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	frame.footer:SetPoint("BOTTOMLEFT", 16, 18)
	frame.footer:SetPoint("RIGHT", footerLeft, "LEFT", -8, 0)
	frame.footer:SetJustifyH("LEFT")
	frame.footer:SetWordWrap(false)

	frame.tab = "cook"

	function frame:Refresh()
		playerPos.c, playerPos.x, playerPos.y = ns:PlayerWorldPosition()
		for key, button in pairs(self.tabs) do
			if key == self.tab then
				button:LockHighlight()
			else
				button:UnlockHighlight()
			end
		end
		self.onlyKnown:SetShown(self.tab == "recipes")
		self.onlyKnown:SetChecked(ns.db.onlyKnown)
		local query = strtrim(self.search:GetText() or ""):lower()
		local rows = {}
		flatten(TREES[self.tab](), 0, rows, query ~= "" and query or nil)
		self.scroll:SetDataProvider(CreateDataProvider(rows), ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition)
		local skill = ns.skill
		local plan = ns:Plan()
		if skill then
			self.footer:SetText(format("Cooking %d/%d.  %d skill-ups in your bags.  Shift-click a recipe to mark it known.",
				skill.rank, skill.max, plan.gain))
		else
			self.footer:SetText("Cooking not learned yet.")
		end
	end

	frame:SetScript("OnShow", frame.Refresh)
	return frame
end

function ns:ShowBrowser(tab, query)
	self.browser = self.browser or createBrowser()
	if tab then
		self.browser.tab = tab
	end
	self.browser:Show()
	if query then
		self.browser.search:SetText(query)
	end
	self.browser:Refresh()
end

function ns:ToggleBrowser()
	if self.browser and self.browser:IsShown() then
		self.browser:Hide()
	else
		self:ShowBrowser()
	end
end
