local _, ns = ...

local ROW_HEIGHT = 20
local INDENT = 14
local TABS = {
	{ key = "guide", label = "Guide" },
	{ key = "skills", label = "Skills" },
	{ key = "families", label = "Families" },
	{ key = "special", label = "Rare & Special" },
	{ key = "trainers", label = "Trainers" },
}

local GREEN, GREY, GOLD, PURPLE = "|cff40ff40", "|cff9d9d9d", "|cffffd100", "|cffc080ff"

local expanded = { ready = true, ["guide:pet"] = true, ["guide:now"] = true, ["guide:tames"] = true }
local playerPos = {}

local function stripCodes(text)
	return (text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
end

local function distance(npcID, npc)
	return ns:NearestSpawn(npcID, npc, playerPos)
end

local function byDistanceThenLevel(a, b)
	local da, db = distance(a, ns.npcs[a]), distance(b, ns.npcs[b])
	if da and db and da ~= db then
		return da < db
	elseif (da ~= nil) ~= (db ~= nil) then
		return da ~= nil
	end
	local la, lb = ns:MinLevel(ns.npcs[a].lv) or 0, ns:MinLevel(ns.npcs[b].lv) or 0
	if la ~= lb then
		return la < lb
	end
	return ns.npcs[a].n < ns.npcs[b].n
end

local function byLevel(a, b)
	local la, lb = ns:MinLevel(ns.npcs[a].lv) or 0, ns:MinLevel(ns.npcs[b].lv) or 0
	if la ~= lb then
		return la < lb
	end
	return ns.npcs[a].n < ns.npcs[b].n
end

-- Nodes -----------------------------------------------------------------
-- { id, text, right, icon, children = fn, npcID | npcIDs, ability, rank, tooltip = fn }

local function beastNode(parentID, npcID)
	local npc = ns.npcs[npcID]
	local text = format("%s%s|r  %s(%s)|r", ns:IsTameable(npc) and "|cffffffff" or GREY, npc.n,
		ns:LevelColor(npc.lv), npc.lv ~= "" and npc.lv or "??")
	local interval = ns:PetAttackInterval(npcID, npc)
	if interval then
		text = text .. format("  %.1fs swing", interval)
	end
	if npc.lists and npc.look then
		text = text .. "  " .. PURPLE .. npc.look .. "|r"
	end
	local yards = distance(npcID, npc)
	local zone = ns:ZoneName(npc)
	return {
		id = parentID .. ":" .. npcID,
		icon = ns:FamilyIcon(npc.f),
		text = text,
		right = (npc.s and "" or GREY) .. zone .. (yards and format(" |cff9d9d9d%dyd|r", yards) or ""),
		search = zone .. " " .. (npc.look or ""),
		npcID = npcID,
		tooltip = function(tooltip)
			ns:FillTooltip(tooltip, npcID, npc)
		end,
	}
end

local function trainerNode(parentID, npcID)
	local trainer = ns.trainers[npcID]
	local yards = distance(npcID, trainer)
	return {
		id = parentID .. ":" .. npcID,
		icon = "Interface\\Icons\\Ability_Hunter_BeastTraining",
		text = trainer.n .. (trainer.faction == "A" and "  |cff3399ffAlliance|r" or trainer.faction == "H" and "  |cffff3333Horde|r" or ""),
		right = ns:ZoneName(trainer) .. (yards and format(" |cff9d9d9d%dyd|r", yards) or ""),
		search = ns:ZoneName(trainer),
		npcID = npcID,
		tooltip = function(tooltip)
			ns:FillTooltip(tooltip, npcID, trainer)
		end,
	}
end

local function myTrainers()
	local faction, ids = ns:PlayerFaction(), {}
	for npcID, trainer in pairs(ns.trainers) do
		if not ns.db.myFactionOnly or not faction or trainer.faction == faction or trainer.faction == "" then
			tinsert(ids, npcID)
		end
	end
	table.sort(ids, function(a, b)
		local da = distance(a, ns.trainers[a]) or math.huge
		local db = distance(b, ns.trainers[b]) or math.huge
		if da ~= db then
			return da < db
		end
		return ns.trainers[a].n < ns.trainers[b].n
	end)
	return ids
end

local function teacherIDs(rank, tameableOnly)
	local ids = {}
	for _, npcID in ipairs(rank.npcs) do
		local npc = ns.npcs[npcID]
		if npc and (not tameableOnly or ns:IsTameable(npc)) then
			tinsert(ids, npcID)
		end
	end
	table.sort(ids, byDistanceThenLevel)
	return ids
end

local function rankStatus(ability, rank)
	if ns:IsRankKnown(ability, rank) then
		return GREY .. "Known|r"
	elseif ns:IsRankLearnable(ability, rank) then
		return GREEN .. "Learn now|r"
	elseif rank.source == "unknown" then
		return GREY .. "No known source|r"
	elseif rank.source == "trainer" then
		return format("Trainer, level %d", rank.level)
	end
	return GREY .. "Beasts too high|r"
end

local function rankNode(parentID, ability, rank, title)
	local id = parentID .. ":" .. rank.rank
	local isWild = rank.source == "wild"
	return {
		id = id,
		icon = ns:AbilityIcon(ability),
		text = format("%s  |cff9d9d9dpet lvl %d, %d TP|r", title or ("Rank " .. rank.rank), rank.level, rank.tp),
		right = rankStatus(ability, rank),
		ability = ability,
		rank = rank,
		npcIDs = isWild and teacherIDs(rank, true) or (rank.source == "trainer" and myTrainers()) or nil,
		children = (isWild or rank.source == "trainer") and function()
			local kids = {}
			if isWild then
				for _, npcID in ipairs(teacherIDs(rank, ns.db.onlyNeeded)) do
					tinsert(kids, beastNode(id, npcID))
				end
			else
				for _, npcID in ipairs(myTrainers()) do
					tinsert(kids, trainerNode(id, npcID))
				end
			end
			return kids
		end or nil,
		tooltip = function(tooltip)
			tooltip:SetText(format("%s %d", ability.name, rank.rank), 1, 0.82, 0)
			tooltip:AddLine(rank.desc, 1, 1, 1, true)
			tooltip:AddLine(format("Pet level %d, %d training points", rank.level, rank.tp), 0.8, 0.8, 0.8)
			tooltip:AddLine(" ")
			tooltip:AddLine("Shift-click to mark as known / not known.", 0.5, 0.8, 1)
		end,
	}
end

local function familiesText(ability)
	if ability.families == true then
		return "All families"
	end
	local names = {}
	for _, key in ipairs(ability.families) do
		tinsert(names, ns:FamilyName(key, true))
	end
	return table.concat(names, ", ")
end

local function abilityNode(parentID, ability)
	local id = parentID .. ":" .. ability.key
	return {
		id = id,
		icon = ns:AbilityIcon(ability),
		text = GOLD .. ability.name .. "|r",
		right = format("known %d / %d", ns:KnownRank(ability), #ability.ranks),
		search = familiesText(ability),
		children = function()
			local kids = {}
			for _, rank in ipairs(ability.ranks) do
				if not ns.db.onlyNeeded or ns:IsRankLearnable(ability, rank) then
					tinsert(kids, rankNode(id, ability, rank))
				end
			end
			return kids
		end,
		tooltip = function(tooltip)
			tooltip:SetText(ability.name, 1, 0.82, 0)
			tooltip:AddLine(ability.desc, 1, 1, 1, true)
			tooltip:AddLine("Learned by: " .. familiesText(ability), 0.8, 0.8, 0.8, true)
		end,
	}
end

-- The best rank of each skill you don't have yet and can learn at your level.
local function readyNodes()
	local kids, trainerRanks = {}, {}
	if not next(ns.char.known) then
		tinsert(kids, { id = "ready:unknown", icon = "Interface\\Icons\\Ability_Hunter_BeastTraining",
			text = GOLD .. "Your skills aren't recorded yet: click Read my skills below, or cast Beast Training.|r" })
	end
	for _, ability in ipairs(ns.abilities) do
		local best
		for _, rank in ipairs(ability.ranks) do
			if ns:IsRankLearnable(ability, rank) then
				best = rank
			end
		end
		if best then
			if best.source == "trainer" then
				tinsert(trainerRanks, format("%s %d", ability.name, best.rank))
			else
				tinsert(kids, rankNode("ready:" .. ability.key, ability, best, format("%s%s %d|r", GREEN, ability.name, best.rank)))
			end
		end
	end
	if #trainerRanks > 0 then
		tinsert(kids, {
			id = "ready:trainer",
			icon = "Interface\\Icons\\Ability_Hunter_BeastTraining",
			text = GREEN .. "Pet trainer:|r " .. table.concat(trainerRanks, ", "),
			npcIDs = myTrainers(),
			children = function()
				local list = {}
				for _, npcID in ipairs(myTrainers()) do
					tinsert(list, trainerNode("ready:trainer", npcID))
				end
				return list
			end,
		})
	end
	if #kids == 0 then
		tinsert(kids, { id = "ready:none", text = GREY .. "Nothing new to learn at your level. Check back after you level up.|r" })
	end
	return kids
end

local function skillsTree()
	local wild, trainer = {}, {}
	for _, ability in ipairs(ns.abilities) do
		tinsert(ability.trainer and trainer or wild, abilityNode(ability.trainer and "trainer" or "wild", ability))
	end
	return {
		{ id = "ready", icon = "Interface\\Icons\\Ability_Hunter_BeastTaming", text = GREEN .. "Ready to learn now|r",
			right = "level " .. ns:PlayerLevel(), children = readyNodes },
		{ id = "wild", icon = "Interface\\Icons\\Ability_Hunter_BeastTaming", text = GOLD .. "Learned by taming wild beasts|r",
			children = function() return wild end },
		{ id = "trainer", icon = "Interface\\Icons\\Ability_Hunter_BeastTraining", text = GOLD .. "Learned from pet trainers|r",
			children = function() return trainer end },
	}
end

local function familiesTree()
	local nodes = {}
	for _, family in ipairs(ns.families) do
		local id = "family:" .. family.key
		local modifiers = ns:FamilyStatsText(family.key)
		local stats = ns.familyStats[family.key]
		tinsert(nodes, {
			id = id,
			icon = ns:FamilyIcon(family.key),
			text = GOLD .. family.name .. "|r  " .. (ns.roleNames[family.role] or ""),
			right = modifiers or family.diet,
			tooltip = function(tooltip)
				tooltip:SetText(family.name, 1, 0.82, 0)
				if modifiers then
					tooltip:AddLine("Family modifiers relative to baseline", 0.8, 0.8, 0.8)
					tooltip:AddLine(modifiers, 1, 1, 1)
				end
				if stats and stats.fastest then
					local range = stats.fastest == stats.slowest and format("%.1f", stats.fastest)
						or format("%.1f–%.1f", stats.fastest, stats.slowest)
					tooltip:AddLine("Documented attack speed: " .. range .. " sec per swing", 1, 1, 1)
				end
				tooltip:AddLine("Diet: " .. family.diet, 0.8, 0.8, 0.8)
			end,
			children = function()
				local kids = {}
				for _, key in ipairs(family.active) do
					local ability = ns.abilityByKey[key]
					if ability then
						local node = abilityNode(id, ability)
						tinsert(kids, node)
					end
				end
				tinsert(kids, { id = id .. ":passive", icon = "Interface\\Icons\\Spell_Nature_SpiritArmor",
					text = GREY .. "Passive: Great Stamina, Natural Armor and all resistances|r" })
				tinsert(kids, { id = id .. ":diet", icon = "Interface\\Icons\\INV_Misc_Food_14",
					text = GREY .. "Diet: " .. family.diet .. "|r" })
				local special, teachers = {}, {}
				for npcID, npc in pairs(ns.npcs) do
					if npc.f == family.key then
						if npc.lists then
							tinsert(special, npcID)
						end
						if ns.teaches[npcID] and not npc.lists then
							tinsert(teachers, npcID)
						end
					end
				end
				table.sort(special, byLevel)
				table.sort(teachers, byLevel)
				if #special > 0 then
					tinsert(kids, { id = id .. ":special", icon = "Interface\\Icons\\INV_Misc_Gem_Amethyst_02",
						text = PURPLE .. "Rare & special looks|r", right = #special .. " pets", children = function()
							local list = {}
							for _, npcID in ipairs(special) do
								tinsert(list, beastNode(id .. ":special", npcID))
							end
							return list
						end })
				end
				if #teachers > 0 then
					tinsert(kids, { id = id .. ":teachers", icon = "Interface\\Icons\\INV_Misc_Book_09",
						text = "Beasts that teach skills", right = #teachers .. " beasts", children = function()
							local list = {}
							for _, npcID in ipairs(teachers) do
								local node = beastNode(id .. ":teachers", npcID)
								node.right = stripCodes(ns:TeachesText(npcID) or "")
								tinsert(list, node)
							end
							return list
						end })
				end
				return kids
			end,
		})
	end
	return nodes
end

local function specialTree()
	local nodes = {}
	for _, key in ipairs(ns.listOrder) do
		local ids = {}
		for npcID, npc in pairs(ns.npcs) do
			if npc.lists and npc.lists[key] then
				tinsert(ids, npcID)
			end
		end
		table.sort(ids, byLevel)
		local id = "list:" .. key
		tinsert(nodes, {
			id = id,
			icon = "Interface\\Icons\\INV_Misc_Gem_Amethyst_02",
			text = PURPLE .. ns.listNames[key] .. "|r",
			right = #ids .. " pets",
			npcIDs = ids,
			children = function()
				local list = {}
				for _, npcID in ipairs(ids) do
					tinsert(list, beastNode(id, npcID))
				end
				return list
			end,
		})
	end
	return nodes
end

local function trainersTree()
	local nodes = {}
	for _, npcID in ipairs(myTrainers()) do
		tinsert(nodes, trainerNode("trainers", npcID))
	end
	return nodes
end

local function guideRankNode(groupID, action, pet, hunterLevel)
	local ability, rank = action.ability, action.rank
	local id = groupID .. ":" .. ability.key .. ":" .. rank.rank
	local route, instructions, children
	if action.source == "wild" then
		route = "Tame to learn"
		instructions = "Stable your usual pet, tame a teacher, and use the skill until you learn it. Then teach your usual pet in Beast Training."
		children = function()
			local teachers = {}
			for _, npcID in ipairs(teacherIDs(rank, false)) do
				local npc = ns.npcs[npcID]
				local level = ns:MinLevel(npc.lv)
				if not npc.untameable and level and level <= math.max(hunterLevel, action.hunterGate) then
					tinsert(teachers, beastNode(id, npcID))
				end
			end
			return teachers
		end
	elseif action.source == "trainer" then
		route = "Visit a pet trainer"
		instructions = "Learn the rank from a pet trainer, then teach it to your pet in Beast Training."
		children = function()
			local trainers = {}
			for _, npcID in ipairs(myTrainers()) do
				tinsert(trainers, trainerNode(id, npcID))
			end
			return trainers
		end
	else
		route = action.currentRank and "Teach with Beast Training" or "Check Beast Training"
		instructions = "You've learned this rank. Check your pet's training points and whether it already knows the rank in Beast Training."
	end
	local gates = {}
	if action.hunterGate > hunterLevel then tinsert(gates, "hunter " .. action.hunterGate) end
	if rank.level > pet.level then tinsert(gates, "pet " .. rank.level) end
	local status = #gates > 0 and ("At " .. table.concat(gates, " & ")) or route
	if action.hunterGate <= hunterLevel and rank.level > pet.level and action.source ~= "known" then
		status = format("Learn now, teach at pet %d", rank.level)
	end
	return {
		id = id,
		icon = ns:AbilityIcon(ability),
		text = format("%s %d  %s%d TP total|r", ability.name, rank.rank, GREY, rank.tp),
		right = status,
		children = children,
		tooltip = function(tooltip)
			tooltip:SetText(format("%s %d", ability.name, rank.rank), 1, 0.82, 0)
			tooltip:AddLine(rank.desc, 1, 1, 1, true)
			if action.currentRank then
				tooltip:AddLine("Your pet knows rank " .. action.currentRank, 0.8, 0.8, 0.8)
			end
			tooltip:AddLine(format("Pet level %d, %d total training points", rank.level, rank.tp), 0.8, 0.8, 0.8)
			tooltip:AddLine(instructions, 0.8, 0.8, 0.8, true)
		end,
	}
end

local function guideUpgradeGroups(pet, hunterLevel)
	local now, later = ns:GuideUpgrades(pet, hunterLevel)
	local groups = {}
	for _, group in ipairs({
		{ id = "guide:now", title = "Improve now", actions = now, empty = "No documented upgrades to work on at these levels." },
		{ id = "guide:later", title = "Upcoming upgrades", actions = later, empty = "No higher ranks with a documented source." },
	}) do
		local rows = {}
		for _, action in ipairs(group.actions) do
			tinsert(rows, guideRankNode(group.id, action, pet, hunterLevel))
		end
		if #rows == 0 then
			tinsert(rows, { id = group.id .. ":empty", text = GREY .. group.empty .. "|r" })
		end
		tinsert(groups, { id = group.id, text = group.title, children = function() return rows end })
	end
	return groups
end

local function guideTameGroups(tameLevel)
	local groups = {}
	for _, archetype in ipairs(ns.guideArchetypes) do
		local id = "guide:" .. archetype.key
		local rows = {}
		for _, choice in ipairs(ns:GuideTames(archetype, tameLevel, distance)) do
			local npc = ns.npcs[choice.npcID]
			local node = beastNode(id, choice.npcID)
			local fill = node.tooltip
			local skill = choice.skill
			local reason = choice.reason
			local highestSpawnLevel = tonumber(npc.lv:match("(%d+)%s*$"))
			node.tooltip = function(tooltip)
				fill(tooltip)
				tooltip:AddLine(reason, 1, 1, 1, true)
				if highestSpawnLevel and highestSpawnLevel > choice.level then
					tooltip:AddLine("Look for a level " .. choice.level .. " spawn.", 0.8, 0.8, 0.8)
				end
				if choice.rank == 0 and skill and ns:KnownRank(skill) == 0 then
					tooltip:AddLine("Check this beast with Beast Lore or learn " .. skill.name .. " from a teacher.", 0.8, 0.8, 0.8, true)
				end
			end
			node.text = ns:FamilyName(npc.f) .. "  " .. node.text
			tinsert(rows, node)
		end
		if #rows > 0 then
			local top = ns.npcs[rows[1].npcID]
			tinsert(groups, { id = id, text = archetype.name, right = top.n .. " (" .. top.lv .. ")",
				children = function() return rows end })
		end
	end
	return groups
end

local function guideTree()
	local hunterLevel = ns:PlayerLevel()
	local pet = ns:GuidePet()
	local petRows
	local petLabel = "No active pet"
	if pet then
		petLabel = pet.name or "Active pet"
		if pet.family then petLabel = petLabel .. "  /  " .. ns:FamilyName(pet.family) end
		if pet.level then petLabel = petLabel .. "  /  Level " .. pet.level end
	end
	if pet and pet.family and pet.level then
		petRows = guideUpgradeGroups(pet, hunterLevel)
		if not next(ns.char.known) then
			table.insert(petRows, 1, { id = "guide:import", text = GREY .. "Use Read my skills to include the ranks you've learned.|r" })
		end
	else
		petRows = { { id = "guide:no-pet", text = GREY ..
			(pet and "Your pet's family or level is unavailable." or "Call your pet to see its training plan.") .. "|r" } }
	end
	local tames = guideTameGroups(math.max(hunterLevel, 10))
	if #tames == 0 then
		tinsert(tames, { id = "guide:no-tames", text = GREY .. "No documented ordinary tames at this level.|r" })
	end
	return {
		{ id = "guide:pet", text = GOLD .. "Current pet|r", right = petLabel, children = function() return petRows end },
		{ id = "guide:tames", text = GOLD .. "Choose a pet|r",
			right = hunterLevel < 10 and "First tame at hunter level 10" or "Hunter level " .. hunterLevel,
			children = function() return tames end },
	}
end

local TREES = { guide = guideTree, skills = skillsTree, families = familiesTree, special = specialTree, trainers = trainersTree }

-- Flattening ------------------------------------------------------------

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

-- Rows --------------------------------------------------------------------

local function showNodeOnMap(node)
	if node.npcID then
		ns:ShowOnMap(node.npcID)
		return
	end
	local ids = node.npcIDs or {}
	local first
	for _, npcID in ipairs(ids) do
		local npc = ns.npcs[npcID] or ns.trainers[npcID]
		if npc and npc.s then
			ns.char.tracked[npcID] = true
			first = first or npcID
		end
	end
	if first then
		ns:ShowOnMap(first)
		ns:Print(format("Pinned %d beasts. Shift-click a pin or use Clear pins to remove them.", #ids))
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
		if IsShiftKeyDown() and node.rank then
			ns:SetKnown(node.ability, node.rank.rank, not ns:IsRankKnown(node.ability, node.rank))
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
	local mappable = node.npcID and (ns.npcs[node.npcID] or ns.trainers[node.npcID]).s or (node.npcIDs and #node.npcIDs > 0)
	row.mapButton:SetShown(mappable and true or false)
	row.mapButton.icon:SetDesaturated(node.npcID and not ns:IsTracked(node.npcID) or false)
end

-- Window ------------------------------------------------------------------

local function createBrowser()
	local frame = CreateFrame("Frame", "TurkeyTickleUIPetsBrowser", UIParent, "PortraitFrameTemplate")
	-- The gamepad interface's menus also close UISpecialFrames, from secure code.
	if not ns:GamepadUI() then
		tinsert(UISpecialFrames, "TurkeyTickleUIPetsBrowser")
	end
	frame:SetSize(620, 620)
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
		frame:SetTitle("Hunter Pets")
	end
	if frame.SetPortraitToAsset then
		frame:SetPortraitToAsset("Interface\\Icons\\Ability_Hunter_BeastTaming")
	elseif frame.GetPortrait and frame:GetPortrait() then
		frame:GetPortrait():SetTexture("Interface\\Icons\\Ability_Hunter_BeastTaming")
	end

	frame.tabs = {}
	local prev
	for _, tab in ipairs(TABS) do
		local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		button:SetSize(104, 22)
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
		button.key = tab.key
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

	local needed = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	needed:SetSize(24, 24)
	needed:SetPoint("LEFT", search, "RIGHT", 12, 0)
	needed.label = needed:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	needed.label:SetPoint("LEFT", needed, "RIGHT", 2, 1)
	needed.label:SetText("Only what I can still learn")
	needed:SetScript("OnClick", function(self)
		ns.db.onlyNeeded = self:GetChecked() and true or false
		frame:Refresh()
	end)
	frame.needed = needed

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
	clear:SetSize(100, 22)
	clear:SetPoint("BOTTOMRIGHT", -14, 12)
	clear:SetText("Clear pins")
	clear:SetScript("OnClick", function()
		ns:ClearTracked()
	end)

	local options = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	options:SetSize(80, 22)
	options:SetPoint("RIGHT", clear, "LEFT", -6, 0)

	local footerLeft = options
	-- Casting is protected, so the button is a secure spell button; those can't be made in combat.
	if not InCombatLockdown() and ns:KnowsBeastTraining() then
		local read = CreateFrame("Button", nil, frame, "SecureActionButtonTemplate, UIPanelButtonTemplate")
		read:SetSize(120, 22)
		read:SetPoint("RIGHT", options, "LEFT", -6, 0)
		read:SetText("Read my skills")
		read:RegisterForClicks("AnyUp", "AnyDown")
		read:SetAttribute("type", "spell")
		read:SetAttribute("spell", ns.BEAST_TRAINING)
		read:HookScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText("Read my skills", 1, 1, 1)
			GameTooltip:AddLine("Opens Beast Training so the pet skills you know can be recorded.", nil, nil, nil, true)
			GameTooltip:Show()
		end)
		read:HookScript("OnLeave", GameTooltip_Hide)
		footerLeft = read
	end
	options:SetText("Options")
	options:SetScript("OnClick", function()
		ns:OpenOptions()
	end)

	frame.footer = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	frame.footer:SetPoint("BOTTOMLEFT", 16, 18)
	frame.footer:SetPoint("RIGHT", footerLeft, "LEFT", -8, 0)
	frame.footer:SetJustifyH("LEFT")

	frame.tab = "skills"

	function frame:Refresh()
		playerPos.c, playerPos.x, playerPos.y = ns:PlayerWorldPosition()
		for key, button in pairs(self.tabs) do
			if key == self.tab then
				button:LockHighlight()
			else
				button:UnlockHighlight()
			end
		end
		self.needed:SetShown(self.tab == "skills" or self.tab == "families")
		self.needed:SetChecked(ns.db.onlyNeeded)
		self.search:SetShown(self.tab ~= "guide")
		local query = self.tab ~= "guide" and strtrim(self.search:GetText() or ""):lower() or ""
		local rows = {}
		flatten(TREES[self.tab](), 0, rows, query ~= "" and query or nil)
		self.scroll:SetDataProvider(CreateDataProvider(rows), ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition)
		local pinned = 0
		for _ in pairs(ns.char.tracked) do
			pinned = pinned + 1
		end
		self.footer:SetText(format("%d pinned on the map.  Shift-click a rank to mark it known.  Data: Petopia (wow-petopia.com/forever)", pinned))
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
