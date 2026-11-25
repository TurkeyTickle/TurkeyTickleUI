local _, ns = ...

-- One suggestion per family keeps the shortlist useful when several tames do the same job.
ns.guideArchetypes = {
	{ key = "solo", name = "Solo questing", families = {
		{ "boar", "charge", "Charge gets your pet onto a target quickly." },
		{ "bear", "swipe", "High health and Swipe for nearby enemies." },
		{ "turtle", "shellshield", "High base armor and Shell Shield for tough pulls." },
	} },
	{ key = "packs", name = "Tank multiple enemies", families = {
		{ "bear", "swipe", "Swipe hits up to three nearby enemies." },
		{ "gorilla", "thunderstomp", "Thunderstomp damages nearby enemies." },
		{ "carrionbird", "demoralizingscreech", "Screech lowers nearby enemies' melee attack power." },
	} },
	{ key = "damage", name = "Damage", families = {
		{ "cat", "claw", "High physical damage with Claw as a focus spender." },
		{ "raptor", "savagerend", "High physical damage with a bleed from Savage Rend." },
		{ "windserpent", "lightningbreath", "Lightning Breath deals Nature damage from range." },
	} },
	{ key = "group", name = "Group support", families = {
		{ "wolf", "furioushowl", "Furious Howl buffs nearby allies' melee attack power." },
		{ "carrionbird", "demoralizingscreech", "Screech lowers nearby enemies' melee attack power." },
		{ "tallstrider", "dustcloud", "Dust Cloud lowers the target's armor." },
	} },
	{ key = "pvp", name = "PvP control", families = {
		{ "spider", "web", "Web holds a target in place." },
		{ "bat", "sonicblast", "Sonic Blast slows the target's spellcasting." },
		{ "crocolisk", "dismember", "Dismember reduces healing on the target." },
	} },
}

local FAMILY_IDS = {
	[1] = "wolf", [2] = "cat", [3] = "spider", [4] = "bear", [5] = "boar",
	[6] = "crocolisk", [7] = "carrionbird", [8] = "crab", [9] = "gorilla", [11] = "raptor",
	[12] = "tallstrider", [20] = "scorpid", [21] = "turtle", [24] = "bat", [25] = "hyena",
	[26] = "birdofprey", [27] = "windserpent", [45] = "corehound", [50] = "fox",
}

local function isReadable(value, kind)
	return type(value) == kind and not (issecretvalue and issecretvalue(value))
end

local function readPetRanks()
	local ranks = {}
	local book = C_SpellBook
	local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Pet
	if not (bank and book and book.HasPetSpells and book.GetSpellBookItemName) then
		return ranks
	end
	local count = book.HasPetSpells()
	if isReadable(count, "number") then
		for slot = 1, count do
			local ability, rank = ns:ParseAbility(book.GetSpellBookItemName(slot, bank))
			if ability and rank then
				ranks[ability.key] = math.max(ranks[ability.key] or 0, rank)
			end
		end
	end
	return ranks
end

function ns:GuidePet()
	local exists = UnitExists("pet")
	if not isReadable(exists, "boolean") or not exists then
		return
	end
	local name, level = UnitName("pet"), UnitLevel("pet")
	local family, id
	if UnitCreatureFamily then
		family, id = UnitCreatureFamily("pet")
	end
	local key = isReadable(id, "number") and FAMILY_IDS[id]
	if not key and isReadable(family, "string") then
		for _, entry in ipairs(self.families) do
			if entry.single == family or (entry.key == "birdofprey" and family == "Owl") then
				key = entry.key
				break
			end
		end
	end
	return {
		name = isReadable(name, "string") and name or nil,
		level = isReadable(level, "number") and level > 0 and level or nil,
		family = key or nil,
		ranks = readPetRanks(),
	}
end

local function earliestTeacher(rank)
	local level
	for _, npcID in ipairs(rank.npcs) do
		local npc = ns.npcs[npcID]
		local min = npc and not npc.untameable and ns:MinLevel(npc.lv)
		if min then
			level = math.min(min, level or min)
		end
	end
	return level
end

-- A wild teacher's level gates the hunter; the rank requirement gates the pet it'll be taught to.
function ns:GuideUpgrades(pet, hunterLevel)
	local now, later = {}, {}
	for _, ability in ipairs(self.abilities) do
		local key = ability.key
		if key ~= "cower" and self:CanFamilyLearn(pet.family, ability) and
			(not key:find("resistance", 1, true) or pet.ranks[key]) then
			local ready, upcoming
			local currentRank = pet.ranks[key]
			local known = self.char.known[key] or {}
			local knownRank = self:KnownRank(ability)
			for index = #ability.ranks, 1, -1 do
				local rank = ability.ranks[index]
				if rank.rank > (currentRank or 0) then
					local source = known[rank.rank] and "known" or rank.source
					local hunterGate
					if source == "known" then
						hunterGate = 0
					elseif rank.rank > knownRank and source == "trainer" then
						hunterGate = rank.level
					elseif rank.rank > knownRank and source == "wild" then
						hunterGate = earliestTeacher(rank)
					end
					if hunterGate then
						local action = { ability = ability, rank = rank, source = source,
							hunterGate = hunterGate, currentRank = currentRank }
						if hunterGate <= hunterLevel and rank.level <= pet.level then
							if not ready or rank.rank > ready.rank.rank then ready = action end
						elseif (not ready or rank.rank > ready.rank.rank) and
							(not upcoming or math.max(hunterGate, rank.level) < math.max(upcoming.hunterGate, upcoming.rank.level)) then
							upcoming = action
						end
					end
				end
			end
			if ready then tinsert(now, ready) end
			if upcoming and (not ready or upcoming.rank.rank > ready.rank.rank) then tinsert(later, upcoming) end
		end
	end
	table.sort(later, function(a, b)
		local aLevel, bLevel = math.max(a.hunterGate, a.rank.level), math.max(b.hunterGate, b.rank.level)
		if aLevel ~= bLevel then return aLevel < bLevel end
		return a.ability.name < b.ability.name
	end)
	return now, later
end

local function ordinaryTame(npc)
	local tags, lists = npc.tags or {}, npc.lists or {}
	return not npc.untameable and not (tags.rare or tags.elite or lists.rare or lists.elite
		or lists.collector or lists.spawned)
end

local function startingRank(npcID, key)
	for _, skill in ipairs(ns.teaches[npcID] or {}) do
		if skill.ability.key == key then return skill.rank.rank end
	end
	return 0
end

function ns:GuideTames(archetype, hunterLevel, getDistance)
	local choices = {}
	for _, entry in ipairs(archetype.families) do
		local family, skill, reason = unpack(entry)
		local best
		for npcID, npc in pairs(self.npcs) do
			local min = npc.f == family and ordinaryTame(npc) and self:MinLevel(npc.lv)
			if min and min <= hunterLevel then
				local level = math.min(hunterLevel, tonumber(npc.lv:match("(%d+)%s*$")) or min)
				local rank = startingRank(npcID, skill)
				local score = level + (rank > 0 and 4 or 0)
				local yards = getDistance(npcID, npc) or math.huge
				if not best or score > best.score
					or (score == best.score and (rank > best.rank
						or (rank == best.rank and (yards < best.yards or (yards == best.yards and npcID < best.npcID))))) then
					best = { npcID = npcID, level = level, rank = rank, score = score, yards = yards,
						skill = self.abilityByKey[skill], reason = reason }
				end
			end
		end
		if best then tinsert(choices, best) end
	end
	return choices
end

local function refreshGuide()
	local browser = ns.browser
	if browser and browser.tab == "guide" and browser:IsShown() then
		browser:Refresh()
	end
end

ns.handlers.PET_BAR_UPDATE = refreshGuide
ns.handlers.SPELLS_CHANGED = refreshGuide

function ns.handlers.UNIT_PET(unit)
	if unit == "player" then refreshGuide() end
end

function ns.handlers.UNIT_LEVEL(unit)
	if unit == "pet" then refreshGuide() end
end
