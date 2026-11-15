local _, ns = ...

function ns:IsBuyable(itemID)
	local item = self.items[itemID]
	return item ~= nil and item.vendors ~= nil
end

-- Whether the recipe counts as worth cooking at this skill.
function ns:Worthwhile(recipe, skill)
	local chance = self:SkillUpChance(recipe, skill)
	if chance <= 0 then
		return 0
	end
	if not self.db.includeGreen and self:Difficulty(recipe, skill) == "green" then
		return 0
	end
	return chance
end

local function makeable(recipe, have)
	local n
	for _, reagent in ipairs(recipe.r) do
		local can = math.floor((have[reagent[1]] or 0) / reagent[2])
		n = n and math.min(n, can) or can
	end
	return n or 0
end

local function knownRecipes()
	local list = {}
	for _, recipe in ipairs(ns.recipes) do
		if ns:IsKnown(recipe) then
			tinsert(list, recipe)
		end
	end
	return list
end

-- What to cook from the bags, best chance first, with the skill moving as you go.
-- plan = { crafts = { { recipe, count, color } }, gain, to, buy = { { recipe, count, items = { { item, need } } } } }
function ns:Plan()
	if self.plan then
		return self.plan
	end
	local plan = { crafts = {}, buy = {}, gain = 0 }
	self.plan = plan
	local skill = self.skill
	if not skill then
		plan.noSkill = true
		return plan
	end
	plan.to = skill.rank
	if self:IsCapped() then
		plan.capped = true
		return plan
	end

	local have = {}
	for itemID, count in pairs(self.bag) do
		have[itemID] = count
	end
	local known = knownRecipes()
	plan.knownCount = #known
	local room = skill.max - skill.rank
	local effective = skill.effective
	local made, order = {}, {}
	for _ = 1, 500 do
		if plan.gain >= room then
			break
		end
		local at = math.floor(effective + plan.gain)
		local best, bestChance = nil, 0
		for _, recipe in ipairs(known) do
			local chance = self:Worthwhile(recipe, at)
			if chance > bestChance and makeable(recipe, have) > 0 then
				best, bestChance = recipe, chance
			end
		end
		if not best then
			break
		end
		for _, reagent in ipairs(best.r) do
			have[reagent[1]] = have[reagent[1]] - reagent[2]
		end
		if not made[best] then
			tinsert(order, best)
		end
		made[best] = (made[best] or 0) + 1
		plan.gain = plan.gain + bestChance
	end
	plan.gain = math.min(plan.gain, room)
	plan.to = skill.rank + plan.gain
	for _, recipe in ipairs(order) do
		tinsert(plan.crafts, { recipe = recipe, count = made[recipe], color = self:Difficulty(recipe) })
	end

	-- Leftover meat that only lacks something a vendor sells (spices, milk, water).
	local at = math.floor(effective + plan.gain)
	for _, recipe in ipairs(known) do
		if self:Worthwhile(recipe, at) > 0 then
			local n, needsVendor
			for _, reagent in ipairs(recipe.r) do
				if self:IsBuyable(reagent[1]) then
					needsVendor = true
				else
					local can = math.floor((have[reagent[1]] or 0) / reagent[2])
					n = n and math.min(n, can) or can
				end
			end
			if n and n > 0 and needsVendor then
				local items = {}
				for _, reagent in ipairs(recipe.r) do
					local need = n * reagent[2]
					if self:IsBuyable(reagent[1]) then
						if need > (have[reagent[1]] or 0) then
							tinsert(items, { reagent[1], need - (have[reagent[1]] or 0) })
						end
						have[reagent[1]] = math.max(0, (have[reagent[1]] or 0) - need)
					else
						have[reagent[1]] = have[reagent[1]] - need
					end
				end
				if #items > 0 then
					tinsert(plan.buy, { recipe = recipe, count = n, items = items })
				end
			end
		end
	end
	return plan
end

-- Reagents and hunting ------------------------------------------------------

-- Skill-ups one of this item is worth: the best recipe you know or can learn now that uses it.
-- Other reagents that you'd have to hunt too halve it.
function ns:ReagentValue(itemID)
	local plan = self:Plan()
	plan.values = plan.values or {}
	local cached = plan.values[itemID]
	if cached then
		return cached[1], cached[2]
	end
	local best, bestRecipe = 0, nil
	for _, recipe in ipairs(self.usedIn[itemID] or {}) do
		if self:IsKnown(recipe) or self:CanLearnNow(recipe) then
			local chance = self:Worthwhile(recipe)
			if chance > 0 then
				local qty, factor = 1, 1
				for _, reagent in ipairs(recipe.r) do
					if reagent[1] == itemID then
						qty = reagent[2]
					elseif not self:IsBuyable(reagent[1]) and self:Count(reagent[1]) < reagent[2] then
						factor = 0.5
					end
				end
				local value = chance * factor / qty
				if value > best then
					best, bestRecipe = value, recipe
				end
			end
		end
	end
	plan.values[itemID] = { best, bestRecipe }
	return best, bestRecipe
end

local function isHuntable(npc)
	if not npc or not npc.s or npc.faction then
		return false
	end
	local level = ns:MinLevel(npc.lv) or 1
	local player = ns:PlayerLevel()
	if level > player + ns.db.levelsAbove then
		return false
	end
	return not npc.elite or level + 5 <= player
end

-- Expected skill-ups per kill, and the drops that make it up.
function ns:MobValue(npcID)
	local score, drops = 0, {}
	for _, drop in ipairs(self.mobDrops[npcID] or {}) do
		local value, recipe = self:ReagentValue(drop[1])
		if value > 0 then
			score = score + drop[2] / 100 * value
			tinsert(drops, { item = drop[1], chance = drop[2], recipe = recipe })
		end
	end
	return score, drops
end

-- Mobs worth killing for Cooking, best first: skill-ups per kill, discounted by how far away they are.
-- pos is a cached player position ({ c, x, y }); targets on another continent go last.
function ns:HuntTargets(pos)
	local list = {}
	for npcID in pairs(self.mobDrops) do
		local npc = self.npcs[npcID]
		if isHuntable(npc) then
			local score, drops = self:MobValue(npcID)
			if score > 0 then
				local yards = self:NearestSpawn(npcID, npc, pos)
				tinsert(list, { id = npcID, npc = npc, score = score, drops = drops, yards = yards,
					rank = yards and score / (1 + yards / 800) or nil })
			end
		end
	end
	table.sort(list, function(a, b)
		if (a.rank ~= nil) ~= (b.rank ~= nil) then
			return a.rank ~= nil
		end
		if a.rank and a.rank ~= b.rank then
			return a.rank > b.rank
		end
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.id < b.id
	end)
	return list
end

-- Learning ------------------------------------------------------------------------------

-- Recipes you don't know that would level you now (or within `ahead` points), best first:
-- ones whose reagents you already carry, then the cheapest to learn.
function ns:LearnTargets(ahead)
	local list = {}
	if not self.skill then
		return list
	end
	local skill = self:Skill()
	for _, recipe in ipairs(self.recipes) do
		if not self:IsKnown(recipe) and recipe.t[4] > skill then
			local need = self:LearnSkill(recipe)
			local soon = need <= self.skill.rank + (ahead or 0)
			if soon then
				local held = 0
				for _, reagent in ipairs(recipe.r) do
					if not self:IsBuyable(reagent[1]) then
						held = held + math.floor(self:Count(reagent[1]) / reagent[2])
					end
				end
				tinsert(list, { recipe = recipe, held = held, now = need <= self.skill.rank })
			end
		end
	end
	table.sort(list, function(a, b)
		if a.now ~= b.now then
			return a.now
		end
		if (a.held > 0) ~= (b.held > 0) then
			return a.held > 0
		end
		local ca, cb = ns:SkillUpChance(a.recipe), ns:SkillUpChance(b.recipe)
		if ca ~= cb then
			return ca > cb
		end
		return a.recipe.t[2] < b.recipe.t[2]
	end)
	return list
end

-- Recipes with no recipe item are taught by cooking trainers (the data has fees for most of them).
function ns:LearnSourceText(recipe)
	if not recipe.scroll then
		return recipe.trainer and format("Trainer, %s", self:Money(recipe.trainer[1])) or "Trainer"
	end
	local item = self.items[recipe.scroll]
	if not item then
		return "Recipe item"
	end
	if item.vendors then
		return format("Vendor, %s", self:Money(item.price))
	elseif item.drops then
		return "Drop"
	elseif item.quests then
		return "Quest reward"
	elseif item.worldDrop then
		return "World drop"
	end
	return "Recipe item"
end

-- The next Cooking rank above your cap, if any.
function ns:NextRank()
	if not self.skill then
		return nil
	end
	for _, rank in ipairs(self.ranks) do
		if rank.cap > self.skill.max then
			return rank
		end
	end
end

function ns:NextRankText(rank)
	rank = rank or self:NextRank()
	if not rank then
		return nil
	end
	local needs = {}
	if rank.skill > 0 then
		tinsert(needs, format("Cooking %d", rank.skill))
	end
	if rank.level > 0 then
		tinsert(needs, format("level %d", rank.level))
	end
	local how
	if rank.fee then
		how = format("Train it at a cooking trainer (%s)", self:Money(rank.fee))
	elseif rank.book then
		how = format("Buy and read %s (%s)", self:ItemName(rank.book), self:Money(rank.price))
	elseif rank.quest then
		how = "Do the Clamlette Surprise quest from Dirge Quikcleave in Gadgetzan"
	end
	return format("Next cap %d: %s. Needs %s.", rank.cap, how or "", table.concat(needs, " and "))
end

function ns:ReadyForNextRank()
	local rank = self:NextRank()
	return rank and self.skill.rank >= rank.skill and self:PlayerLevel() >= rank.level, rank
end
