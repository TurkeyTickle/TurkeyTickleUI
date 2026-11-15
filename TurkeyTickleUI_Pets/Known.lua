local _, ns = ...

ns.BEAST_TRAINING = 5149

function ns:KnowsBeastTraining()
	if IsPlayerSpell then
		return IsPlayerSpell(self.BEAST_TRAINING)
	end
	return C_SpellBook and C_SpellBook.IsSpellKnown and C_SpellBook.IsSpellKnown(self.BEAST_TRAINING) or false
end

local ROMAN = { I = 1, II = 2, III = 3, IV = 4, V = 5, VI = 6, VII = 7, VIII = 8, IX = 9, X = 10, XI = 11, XII = 12 }

local function isSecret(v)
	return issecretvalue and issecretvalue(v)
end

-- Spell names arrive as "Bite" + "Rank 2", "Bite (Rank 2)", "Bite II" or "Bite 2" depending on the client.
function ns:ParseAbility(name, subText)
	if type(name) ~= "string" or isSecret(name) then
		return nil
	end
	if isSecret(subText) then
		subText = nil
	end
	local base, rank = name:match("^(.-)%s*%(%a+ (%d+)%)$")
	if not base then
		local numeral
		base, numeral = name:match("^(.-)%s+([IVX]+)$")
		rank = numeral and ROMAN[numeral]
	end
	if not base then
		base, rank = name:match("^(.-)%s+(%d+)$")
	end
	base = strtrim(base or name)
	local ability = self.abilityByName[base:lower()]
	if not ability then
		return nil
	end
	rank = tonumber(rank) or (type(subText) == "string" and tonumber(subText:match("%d+")))
	if not rank and #ability.ranks == 1 then
		rank = 1
	end
	return ability, rank
end

function ns:KnownRank(ability)
	local ranks = self.char.known[ability.key]
	local best = 0
	if ranks then
		for rank in pairs(ranks) do
			if rank > best then
				best = rank
			end
		end
	end
	return best
end

function ns:IsRankKnown(ability, rank)
	-- Ranks can be skipped, so knowing a higher one covers the lower ones.
	return rank.rank <= self:KnownRank(ability)
end

-- A rank you could go and learn right now: not known, and a teacher is low enough to tame.
function ns:IsRankLearnable(ability, rank)
	if self:IsRankKnown(ability, rank) or rank.source == "unknown" then
		return false
	end
	if rank.source == "trainer" then
		return rank.level <= self:PlayerLevel()
	end
	for _, npcID in ipairs(rank.npcs) do
		local npc = self.npcs[npcID]
		if npc and self:IsTameable(npc) then
			return true
		end
	end
	return false
end

function ns:SetKnown(ability, rankNumber, known)
	local ranks = self.char.known[ability.key] or {}
	ranks[rankNumber] = known or nil
	self.char.known[ability.key] = next(ranks) and ranks or nil
	self:RefreshBrowser()
	self:RefreshMap()
end

local function learn(name, subText)
	local ability, rank = ns:ParseAbility(name, subText)
	if ability and rank and not (ns.char.known[ability.key] and ns.char.known[ability.key][rank]) then
		ns.char.known[ability.key] = ns.char.known[ability.key] or {}
		ns.char.known[ability.key][rank] = true
		return true
	end
	return false
end

local function spellNameAndRank(spellID)
	local name, subText
	if C_Spell and C_Spell.GetSpellName then
		name = C_Spell.GetSpellName(spellID)
		subText = C_Spell.GetSpellSubtext and C_Spell.GetSpellSubtext(spellID)
	elseif GetSpellInfo then
		name = GetSpellInfo(spellID)
		subText = GetSpellSubtext and GetSpellSubtext(spellID)
	end
	return name, subText
end

local function afterScan(changed)
	if changed then
		ns:RefreshBrowser()
		ns:RefreshMap()
	end
end

-- Spells whose rank text the client hadn't loaded yet; retried on SPELL_DATA_LOAD_RESULT.
local pendingSpells = {}

-- Records a spell ID as a known pet skill rank. Returns changed, recognised.
local function learnSpell(spellID)
	local name, subText = spellNameAndRank(spellID)
	local ability, rank = ns:ParseAbility(name, subText)
	if ability and not rank then
		pendingSpells[spellID] = true
		if C_Spell and C_Spell.RequestLoadSpellData then
			C_Spell.RequestLoadSpellData(spellID)
		end
		return false, true
	end
	return ability and learn(name, subText) or false, ability ~= nil
end

function ns.handlers.SPELL_DATA_LOAD_RESULT(spellID, success)
	if pendingSpells[spellID] and success then
		pendingSpells[spellID] = nil
		afterScan(learnSpell(spellID))
	end
end

-- Forever's Beast Training opens the trainer window listing every pet skill you know. At a real pet
-- trainer the same window lists skills for sale, where only "used" ones are known. Wild-only skills
-- never appear at a trainer, so seeing one means this is Beast Training.
local function isPetTrainer()
	if C_Trainer and C_Trainer.GetTrainerType and Enum and Enum.TrainerType and Enum.TrainerType.Pet then
		return C_Trainer.GetTrainerType() == Enum.TrainerType.Pet
	end
	return false
end

-- Forever leaves the service names out, so each one is identified by its spell ID.
local function serviceSpellID(i)
	if C_TooltipInfo and C_TooltipInfo.GetTrainerService then
		local data = C_TooltipInfo.GetTrainerService(i)
		if data and type(data.id) == "number" and not isSecret(data.id) then
			return data.id
		end
	end
end

local function scanTrainer()
	if not isPetTrainer() or not GetNumTrainerServices then
		return
	end
	local services, beastTraining = {}, not UnitExists("npc")
	for i = 1, GetNumTrainerServices() do
		local name, subText, category = GetTrainerServiceInfo(i)
		if category ~= "header" then
			local spellID = serviceSpellID(i)
			if spellID then
				name, subText = spellNameAndRank(spellID)
			end
			local ability = ns:ParseAbility(name, subText)
			if ability then
				tinsert(services, { spellID = spellID, name = name, subText = subText, category = category })
				beastTraining = beastTraining or not ability.trainer
			end
		end
	end
	local changed, count = false, 0
	for _, service in ipairs(services) do
		if beastTraining or service.category == "used" then
			local learned
			if service.spellID then
				learned = learnSpell(service.spellID)
			else
				learned = learn(service.name, service.subText)
			end
			changed = learned or changed
			count = count + 1
		end
	end
	if beastTraining and count > 0 and not ns.scanReported then
		ns.scanReported = true
		ns:Print(format("Read %d pet skill ranks from Beast Training.", count))
	end
	afterScan(changed)
end

-- WhatsTraining keeps the pet skills it saw in Beast Training as spell IDs; take them on login.
function ns:ImportWhatsTraining()
	if type(WT_LearnedPetAbilities) ~= "table" then
		return
	end
	local changed = false
	for spellID, learned in pairs(WT_LearnedPetAbilities) do
		if learned == true and type(spellID) == "number" then
			changed = learnSpell(spellID) or changed
		end
	end
	afterScan(changed)
end

function ns.handlers.PLAYER_LOGIN()
	ns:ImportWhatsTraining()
end

-- Classic-style Beast Training uses the craft window instead.
local function scanCraft()
	if not GetNumCrafts or (GetCraftDisplaySkillLine and GetCraftDisplaySkillLine()) then
		return
	end
	local changed = false
	for i = 1, GetNumCrafts() do
		local name, subText = GetCraftInfo(i)
		changed = learn(name, subText) or changed
	end
	afterScan(changed)
end

ns.handlers.TRAINER_SHOW = scanTrainer
ns.handlers.TRAINER_UPDATE = scanTrainer
ns.handlers.CRAFT_SHOW = scanCraft
ns.handlers.CRAFT_UPDATE = scanCraft

local learnPatterns
local function buildPatterns()
	learnPatterns = {}
	for _, key in ipairs({ "ERR_LEARN_SPELL_S", "ERR_LEARN_ABILITY_S", "ERR_PET_LEARN_SPELL_S", "ERR_PET_LEARN_ABILITY_S" }) do
		local text = _G[key]
		if type(text) == "string" then
			local pattern = text:gsub("([%.%(%)%[%]%-%+%*%?%^%$])", "%%%1"):gsub("%%s", "(.+)")
			tinsert(learnPatterns, "^" .. pattern .. "$")
		end
	end
end

function ns.handlers.CHAT_MSG_SYSTEM(message)
	if type(message) ~= "string" or isSecret(message) then
		return
	end
	if not learnPatterns then
		buildPatterns()
	end
	for _, pattern in ipairs(learnPatterns) do
		local learned = message:match(pattern)
		if learned then
			-- Forever sends a spell link rather than a plain name.
			local spellID = tonumber(learned:match("|Hspell:(%d+)"))
			local name, subText
			if spellID then
				name, subText = spellNameAndRank(spellID)
			end
			name = name or learned:match("%[(.-)%]") or learned
			if learn(name, subText) then
				local ability, rank = ns:ParseAbility(name, subText)
				ns:Print(format("Learned %s %d.", ability.name, rank))
				afterScan(true)
			end
			return
		end
	end
end

function ns:PrintKnown()
	local any = false
	for _, ability in ipairs(self.abilities) do
		local rank = self:KnownRank(ability)
		if rank > 0 then
			self:Print(format("%s: rank %d of %d", ability.name, rank, #ability.ranks))
			any = true
		end
	end
	if not any then
		self:Print("No pet skills recorded yet. Cast Beast Training once so they can be read.")
	end
end
