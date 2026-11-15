local _, ns = ...

local GREEN = "|cff40ff40"

local lastRemind, lastGain = 0, 0
local capWarned = {}

function ns:CookingSpellName()
	return C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(self.COOKING_SPELL) or "Cooking"
end

local function craftList(plan, limit)
	local parts = {}
	for i, craft in ipairs(plan.crafts) do
		if i > limit then
			tinsert(parts, format("and %d more", #plan.crafts - limit))
			break
		end
		tinsert(parts, format("%s x%d", ns:ColoredName(craft.recipe), craft.count))
	end
	return table.concat(parts, ", ")
end

local function buyText(buy)
	local parts = {}
	for _, item in ipairs(buy.items) do
		tinsert(parts, format("%d %s", item[2], ns:ItemName(item[1])))
	end
	return format("buy %s for %d more %s", table.concat(parts, " and "), buy.count, ns:ColoredName(buy.recipe))
end

function ns:NearestTrainer()
	local faction, best, bestYards = self:PlayerFaction()
	for npcID in pairs(self.trainers) do
		local npc = self.npcs[npcID]
		if npc and (not npc.faction or npc.faction == faction) then
			local yards = self:NearestSpawn(npcID, npc)
			if yards and (not bestYards or yards < bestYards) then
				best, bestYards = npcID, yards
			end
		end
	end
	return best, bestYards
end

-- The one-line summary used by reminders, the nudge tooltip and the browser footer.
function ns:StatusLines()
	local lines = {}
	local plan = self:Plan()
	if plan.noSkill then
		local trainer, yards = self:NearestTrainer()
		tinsert(lines, "You haven't learned Cooking yet." .. (trainer and format(" Nearest trainer: %s (%s, %d yd).",
			self.npcs[trainer].n, self:ZoneName(self.npcs[trainer]), yards) or " Any cooking trainer teaches it."))
		return lines
	end
	local skill = self.skill
	local head = format("Cooking %d/%d", skill.rank, skill.max)
	if plan.capped then
		local next = self:NextRankText()
		tinsert(lines, head .. ": you're at your cap, so cooking won't level you. " .. (next or "You've maxed Cooking!"))
		return lines
	end
	if plan.gain >= 1 then
		tinsert(lines, format("%s: your bags hold about %s%d skill-ups|r (to %d): %s.", head, GREEN, plan.gain,
			plan.to, craftList(plan, 4)))
	elseif not self.char.scanned and (plan.knownCount or 0) == 0 then
		tinsert(lines, head .. ": open your Cooking window once so I can see which recipes you know.")
	else
		tinsert(lines, head .. ": nothing in your bags gives skill-ups right now. /ttcook hunt shows what to kill nearby.")
	end
	for i, buy in ipairs(plan.buy) do
		if i > 2 then
			break
		end
		tinsert(lines, "Vendor: " .. buyText(buy) .. ".")
	end
	local ready = self:ReadyForNextRank()
	if ready and skill.max - skill.rank <= 10 then
		tinsert(lines, self:NextRankText())
	end
	return lines
end

function ns:Remind(alert)
	for _, line in ipairs(self:StatusLines()) do
		self:Print(line)
	end
	if alert and self.db.remindAlert and UIErrorsFrame then
		UIErrorsFrame:AddMessage(format("Time to cook: about %d Cooking skill-ups in your bags", self:Plan().gain), 1, 0.6, 0.2)
	end
	lastRemind, lastGain = GetTime and GetTime() or 0, self:Plan().gain
end

local function cooledDown()
	local now = GetTime and GetTime() or 0
	return lastRemind == 0 or now - lastRemind >= ns.db.remindMinutes * 60
end

local function worthNagging()
	local plan = ns:Plan()
	return plan.gain >= ns.db.remindThreshold
end

function ns:LoginReminder()
	if not self.db.remind then
		return
	end
	local plan = self:Plan()
	if plan.noSkill and self.char.noSkillHinted then
		return
	end
	self.char.noSkillHinted = plan.noSkill or nil
	if plan.noSkill or worthNagging() or plan.capped or self:ReadyForNextRank() then
		self:Remind()
	end
end

-- New meat in the bags: nag once the pile is worth a few more points than last time.
function ns:BagReminder()
	if not self.db.remind or not worthNagging() or (InCombatLockdown and InCombatLockdown()) then
		return
	end
	if cooledDown() and self:Plan().gain >= lastGain + self.db.remindThreshold then
		self:Remind(true)
	end
end

function ns.handlers.PLAYER_UPDATE_RESTING()
	if ns.db.remind and IsResting and IsResting() and worthNagging() and cooledDown() then
		ns:Print("You're resting: a good time to cook.")
		ns:Remind(true)
	end
	ns:RefreshNudge()
end

function ns:CheckCap()
	if not self.db.remind or not self.skill then
		return
	end
	local ready, rank = self:ReadyForNextRank()
	local skill = self.skill
	if ready and skill.max - skill.rank <= 5 and not capWarned[rank.cap] then
		capWarned[rank.cap] = true
		self:Print(format("You're %d points from your Cooking cap of %d. %s", skill.max - skill.rank, skill.max, self:NextRankText(rank)))
		if self.db.remindAlert and UIErrorsFrame then
			UIErrorsFrame:AddMessage(format("Cooking %d/%d: train your next Cooking rank", skill.rank, skill.max), 1, 0.6, 0.2)
		end
	end
end

-- Nudge button -------------------------------------------------------------------
-- A secure spell button (casting is protected), so it can only be shown or hidden out of combat.

local nudge

local function nudgeTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:SetText("Cooking", 1, 0.82, 0)
	for _, line in ipairs(ns:StatusLines()) do
		GameTooltip:AddLine(line, 1, 1, 1, true)
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Click: open Cooking", 0.5, 0.8, 1)
	GameTooltip:AddLine("Right-click: Cooking helper", 0.5, 0.8, 1)
	GameTooltip:AddLine("Shift-drag: move", 0.5, 0.8, 1)
	GameTooltip:Show()
end

local function savePoint(self)
	local point, _, relativePoint, x, y = self:GetPoint()
	local saved = ns.db.nudgePoint
	saved.point, saved.relativePoint, saved.x, saved.y = point, relativePoint, x, y
end

function ns:CreateNudge()
	if nudge or (InCombatLockdown and InCombatLockdown()) then
		return
	end
	nudge = CreateFrame("Button", "TurkeyTickleUICookingNudge", UIParent, "SecureActionButtonTemplate")
	self.nudge = nudge
	nudge:SetSize(36, 36)
	local saved = self.db.nudgePoint
	if saved.point then
		nudge:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x, saved.y)
	else
		nudge:SetPoint("CENTER", UIParent, "CENTER", 260, -120)
	end
	nudge:SetFrameStrata("MEDIUM")
	nudge:SetClampedToScreen(true)
	nudge:SetMovable(true)
	nudge:RegisterForDrag("LeftButton")
	nudge:RegisterForClicks("AnyUp", "AnyDown")
	nudge:SetAttribute("type1", "spell")
	nudge:SetAttribute("spell1", self:CookingSpellName())

	nudge.icon = nudge:CreateTexture(nil, "ARTWORK")
	nudge.icon:SetAllPoints()
	nudge.icon:SetTexture(self.ICON)
	nudge.border = nudge:CreateTexture(nil, "OVERLAY")
	nudge.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	nudge.border:SetBlendMode("ADD")
	nudge.border:SetPoint("CENTER")
	nudge.border:SetSize(66, 66)
	nudge.border:SetVertexColor(1, 0.6, 0.2)
	nudge:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	nudge.count = nudge:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	nudge.count:SetPoint("BOTTOMRIGHT", -2, 2)

	nudge.pulse = nudge.border:CreateAnimationGroup()
	nudge.pulse:SetLooping("BOUNCE")
	local fade = nudge.pulse:CreateAnimation("Alpha")
	fade:SetFromAlpha(1)
	fade:SetToAlpha(0.2)
	fade:SetDuration(0.8)

	nudge:SetScript("OnDragStart", function(self)
		if IsShiftKeyDown() and not InCombatLockdown() then
			self:StartMoving()
		end
	end)
	nudge:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		savePoint(self)
	end)
	nudge:HookScript("OnClick", function(_, button, down)
		if button == "RightButton" and not down then
			ns:ToggleBrowser()
		end
	end)
	nudge:SetScript("OnEnter", nudgeTooltip)
	nudge:SetScript("OnLeave", GameTooltip_Hide)
	nudge:Hide()
	self:RefreshNudge()
end

function ns:RefreshNudge()
	if not nudge then
		return
	end
	local plan = self:Plan()
	local want = self.db.nudge and plan.gain >= 1
	nudge.count:SetText(want and format("+%d", plan.gain) or "")
	if want and IsResting and IsResting() then
		nudge.pulse:Play()
	else
		nudge.pulse:Stop()
	end
	if want == nudge:IsShown() then
		return
	end
	if InCombatLockdown and InCombatLockdown() then
		self.nudgePending = true
		return
	end
	nudge:SetShown(want)
end

function ns.handlers.PLAYER_REGEN_ENABLED()
	if not nudge then
		ns:CreateNudge()
	end
	if ns.nudgePending then
		ns.nudgePending = nil
		ns:RefreshNudge()
	end
	ns:MapRegenEnabled()
end

function ns:ResetNudgePosition()
	wipe(self.db.nudgePoint)
	if nudge and not InCombatLockdown() then
		nudge:ClearAllPoints()
		nudge:SetPoint("CENTER", UIParent, "CENTER", 260, -120)
	end
end