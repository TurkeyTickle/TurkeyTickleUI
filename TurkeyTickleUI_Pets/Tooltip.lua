local _, ns = ...

local GREEN, GREY, WHITE, PURPLE, RED = "|cff40ff40", "|cff9d9d9d", "|cffffffff", "|cffc080ff", "|cffff4040"

local function isSecret(v)
	return issecretvalue and issecretvalue(v)
end

function ns:RankLabel(ability, rank)
	local text = format("%s %d", ability.name, rank.rank)
	if self:IsRankKnown(ability, rank) then
		return GREY .. text .. " (known)|r"
	elseif self:IsRankLearnable(ability, rank) then
		return GREEN .. text .. " (new!)|r"
	end
	return WHITE .. text .. "|r"
end

function ns:TeachesText(npcID)
	local list = self.teaches[npcID]
	if not list then
		return nil
	end
	local parts = {}
	for _, t in ipairs(list) do
		tinsert(parts, self:RankLabel(t.ability, t.rank))
	end
	return table.concat(parts, ", ")
end

function ns:FillTooltip(tooltip, npcID, npc, isPin)
	local name = npc.n .. (npc.sub and (" <" .. npc.sub .. ">") or "")
	tooltip:SetText(name, 1, 0.82, 0)
	if self.trainers[npcID] then
		tooltip:AddLine("Pet Trainer", 1, 1, 1)
		tooltip:AddLine("Sells Growl, Great Stamina, Natural Armor and the resistances.", 0.8, 0.8, 0.8, true)
	else
		tooltip:AddLine(format("%sLevel %s|r %s", self:LevelColor(npc.lv), npc.lv ~= "" and npc.lv or "??",
			self:FamilyName(npc.f)), 1, 1, 1)
		if npc.look then
			tooltip:AddLine("Look: " .. npc.look, 0.8, 0.8, 0.8)
		end
		if npc.lists then
			local labels = {}
			for _, key in ipairs(self.listOrder) do
				if npc.lists[key] then
					tinsert(labels, self.listNames[key])
				end
			end
			tooltip:AddLine(PURPLE .. table.concat(labels, ", ") .. "|r")
		end
		local teaches = self:TeachesText(npcID)
		if teaches then
			tooltip:AddLine("Teaches: " .. teaches, 1, 1, 1, true)
		end
		if npc.untameable then
			tooltip:AddLine(RED .. "Can't be tamed|r")
		end
		if npc.note then
			tooltip:AddLine(npc.note, 0.9, 0.9, 0.6, true)
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

-- Unit tooltips -------------------------------------------------------------

local function npcIDFromGUID(guid)
	if type(guid) ~= "string" or isSecret(guid) then
		return nil
	end
	local kind, _, _, _, _, id = strsplit("-", guid)
	if kind == "Creature" then
		return tonumber(id)
	end
end

local byName
local function npcIDFromName(tooltip)
	local line = tooltip.GetName and tooltip:GetName() and _G[tooltip:GetName() .. "TextLeft1"]
	local text = line and line:GetText()
	if type(text) ~= "string" or isSecret(text) then
		return nil
	end
	if not byName then
		byName = {}
		for npcID, npc in pairs(ns.npcs) do
			byName[npc.n] = byName[npc.n] or npcID
		end
	end
	return byName[text]
end

local function onUnitTooltip(tooltip, data)
	if not ns.db.tooltips or tooltip ~= GameTooltip then
		return
	end
	local npcID = npcIDFromGUID(data and data.guid)
	if not npcID then
		local _, unit = tooltip:GetUnit()
		if unit and not isSecret(unit) then
			npcID = npcIDFromGUID(UnitGUID(unit))
		end
	end
	npcID = npcID or npcIDFromName(tooltip)
	local npc = npcID and ns.npcs[npcID]
	if not npc then
		return
	end
	local teaches = ns:TeachesText(npcID)
	if teaches then
		tooltip:AddLine("|cffe8a33dPet skills:|r " .. teaches, 1, 1, 1, true)
	end
	if npc.lists and not npc.untameable then
		tooltip:AddLine("|cffe8a33dPet:|r " .. PURPLE .. (npc.look or "Special pet") .. "|r")
	end
	if teaches or npc.lists then
		tooltip:Show()
	end
end

function ns:InitTooltip()
	local processor = TooltipDataProcessor
	if processor and processor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
		processor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
			xpcall(onUnitTooltip, geterrorhandler(), tooltip, data)
		end)
	elseif GameTooltip and GameTooltip.HookScript then
		GameTooltip:HookScript("OnTooltipSetUnit", function(tooltip)
			xpcall(onUnitTooltip, geterrorhandler(), tooltip)
		end)
	end
end
