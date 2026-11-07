local _, ns = ...

local BAR_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local RAID_ICONS = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"
local FAIL_DISPLAY_TIME = 0.6

local GetDebuffData
if C_UnitAuras and C_UnitAuras.GetDebuffDataByIndex then
	GetDebuffData = function(unit, index)
		local aura = C_UnitAuras.GetDebuffDataByIndex(unit, index, "HARMFUL|PLAYER")
		if aura then
			return aura.icon, aura.applications, aura.duration, aura.expirationTime
		end
	end
else
	GetDebuffData = function(unit, index)
		local name, icon, count, _, duration, expirationTime = UnitAura(unit, index, "HARMFUL|PLAYER")
		if name then
			return icon, count, duration, expirationTime
		end
	end
end

local GetDifficultyColor = GetCreatureDifficultyColor or GetQuestDifficultyColor

local CLASSIFICATION_SUFFIX = {
	elite = "+",
	rareelite = " R+",
	rare = " R",
	worldboss = " B",
}

local function abbreviate(n)
	if n >= 1e6 then
		return format("%.1fm", n / 1e6)
	elseif n >= 1e4 then
		return format("%.0fk", n / 1e3)
	elseif n >= 1e3 then
		return format("%.1fk", n / 1e3)
	end
	return tostring(n)
end

local function setFont(fs, size)
	fs:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
	fs:SetShadowOffset(0, 0)
end

local function createBar(parent)
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetStatusBarTexture(BAR_TEXTURE)

	bar.border = bar:CreateTexture(nil, "BACKGROUND", nil, -8)
	bar.border:SetTexture(BAR_TEXTURE)
	bar.border:SetVertexColor(0, 0, 0, 1)
	bar.border:SetPoint("TOPLEFT", -1, 1)
	bar.border:SetPoint("BOTTOMRIGHT", 1, -1)

	bar.bg = bar:CreateTexture(nil, "BACKGROUND", nil, 0)
	bar.bg:SetTexture(BAR_TEXTURE)
	bar.bg:SetAllPoints()

	return bar
end

local function hideBlizzardFrame(nameplate)
	local uf = nameplate.UnitFrame
	if not uf or uf.foreverPlatesHooked then
		return
	end
	uf.foreverPlatesHooked = true
	uf:HookScript("OnShow", function(self)
		local plate = nameplate.ForeverPlate
		if plate and plate.unit then
			self:Hide()
		end
	end)
end

local Plate = {}

function ns:GetPlate(nameplate)
	if nameplate.ForeverPlate then
		return nameplate.ForeverPlate
	end

	local plate = Mixin(CreateFrame("Frame", nil, nameplate), Plate)
	plate.nameplate = nameplate
	plate:SetPoint("CENTER")
	plate:EnableMouse(false)

	plate.health = createBar(plate)
	plate.health:SetAllPoints()

	plate.healthText = plate.health:CreateFontString(nil, "OVERLAY")
	plate.healthText:SetPoint("RIGHT", -2, 0)

	plate.name = plate:CreateFontString(nil, "OVERLAY")
	plate.name:SetPoint("BOTTOMLEFT", plate.health, "TOPLEFT", 0, 3)
	plate.name:SetJustifyH("LEFT")
	plate.name:SetWordWrap(false)

	plate.level = plate:CreateFontString(nil, "OVERLAY")
	plate.level:SetPoint("BOTTOMRIGHT", plate.health, "TOPRIGHT", 0, 3)
	plate.name:SetPoint("RIGHT", plate.level, "LEFT", -4, 0)

	plate.raidIcon = plate:CreateTexture(nil, "OVERLAY")
	plate.raidIcon:SetTexture(RAID_ICONS)
	plate.raidIcon:SetSize(22, 22)
	plate.raidIcon:SetPoint("LEFT", plate.health, "RIGHT", 6, 0)

	plate.cast = createBar(plate)
	plate.cast:SetPoint("TOPLEFT", plate.health, "BOTTOMLEFT", 0, -3)
	plate.cast:SetPoint("TOPRIGHT", plate.health, "BOTTOMRIGHT", 0, -3)
	plate.cast.bg:SetVertexColor(0.1, 0.1, 0.1, 0.85)
	plate.cast:Hide()
	plate.cast:SetScript("OnUpdate", function(bar)
		plate:OnCastUpdate(bar)
	end)

	plate.cast.icon = plate.cast:CreateTexture(nil, "OVERLAY")
	plate.cast.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	plate.cast.icon:SetPoint("TOPRIGHT", plate.health, "TOPLEFT", -3, 0)
	plate.cast.icon:SetPoint("BOTTOMRIGHT", plate.cast, "BOTTOMLEFT", -3, 0)

	plate.cast.iconBorder = plate.cast:CreateTexture(nil, "ARTWORK")
	plate.cast.iconBorder:SetTexture(BAR_TEXTURE)
	plate.cast.iconBorder:SetVertexColor(0, 0, 0, 1)
	plate.cast.iconBorder:SetPoint("TOPLEFT", plate.cast.icon, -1, 1)
	plate.cast.iconBorder:SetPoint("BOTTOMRIGHT", plate.cast.icon, 1, -1)

	plate.cast.text = plate.cast:CreateFontString(nil, "OVERLAY")
	plate.cast.text:SetPoint("LEFT", 2, 0)
	plate.cast.text:SetPoint("RIGHT", -28, 0)
	plate.cast.text:SetJustifyH("LEFT")
	plate.cast.text:SetWordWrap(false)

	plate.cast.timer = plate.cast:CreateFontString(nil, "OVERLAY")
	plate.cast.timer:SetPoint("RIGHT", -2, 0)

	plate.debuffs = CreateFrame("Frame", nil, plate)
	plate.debuffs:SetSize(1, 1)
	plate.debuffs.icons = {}

	nameplate.ForeverPlate = plate
	hideBlizzardFrame(nameplate)
	plate:ApplyLayout()
	return plate
end

function ns:RestoreBlizzard(nameplate)
	local plate = nameplate.ForeverPlate
	if plate then
		plate:ClearUnit()
	end
	if nameplate.UnitFrame then
		nameplate.UnitFrame:Show()
	end
end

function Plate:ApplyLayout()
	local db = ns.db
	self:SetSize(db.width, db.height)
	self.cast:SetHeight(db.castHeight)
	setFont(self.name, db.fontSize)
	setFont(self.level, db.fontSize)
	setFont(self.healthText, db.fontSize - 1)
	setFont(self.cast.text, db.fontSize - 1)
	setFont(self.cast.timer, db.fontSize - 1)
	self.cast.icon:SetWidth(db.height + db.castHeight + 3)
	self.debuffs:ClearAllPoints()
	self.debuffs:SetPoint("BOTTOM", self.health, "TOP", 0, db.fontSize + 7)
	for _, icon in ipairs(self.debuffs.icons) do
		icon:SetSize(db.debuffSize, db.debuffSize * 0.8)
		setFont(icon.count, db.fontSize - 1)
	end
end

function Plate:SetUnit(unit)
	self.unit = unit
	if self.nameplate.UnitFrame then
		self.nameplate.UnitFrame:Hide()
	end
	self:Show()
	self:UpdateAll()
end

function Plate:ClearUnit()
	self.unit = nil
	self.castFailedUntil = nil
	self.cast:Hide()
	self:Hide()
end

function Plate:UpdateAll()
	if not self.unit then
		return
	end
	self:UpdateName()
	self:UpdateHealth()
	self:UpdateTarget()
	self:UpdateRaidIcon()
	self:UpdateDebuffs()
	self:UpdateCast()
end

function Plate:UpdateName()
	local unit = self.unit
	self.name:SetText(UnitName(unit) or "")

	if not ns.db.showLevel then
		self.level:SetText("")
		return
	end

	local level = UnitLevel(unit)
	local suffix = CLASSIFICATION_SUFFIX[UnitClassification(unit)] or ""
	if level == -1 then
		self.level:SetText("??" .. suffix)
		self.level:SetTextColor(1, 0.1, 0.1)
	else
		self.level:SetText(level .. suffix)
		local color = GetDifficultyColor(level)
		self.level:SetTextColor(color.r, color.g, color.b)
	end
end

function Plate:UpdateHealth()
	local unit = self.unit
	local cur, max = UnitHealth(unit), UnitHealthMax(unit)
	if max == 0 then
		max = 1
	end
	self.health:SetMinMaxValues(0, max)
	self.health:SetValue(cur)

	local pct = cur / max * 100
	local mode = ns.db.healthText
	if mode == "percent" then
		self.healthText:SetFormattedText("%d%%", pct + 0.5)
	elseif mode == "value" then
		self.healthText:SetText(abbreviate(cur))
	elseif mode == "both" then
		self.healthText:SetFormattedText("%s  %d%%", abbreviate(cur), pct + 0.5)
	else
		self.healthText:SetText("")
	end

	self:UpdateHealthColor(pct)
end

function Plate:GetThreatColor()
	local unit = self.unit
	if not ns.db.threatColors or UnitIsPlayer(unit) or not UnitAffectingCombat(unit) then
		return
	end
	local status = UnitThreatSituation("player", unit)
	if not status then
		return
	end
	local c = ns.colors
	if ns.db.tankMode then
		if status == 3 then
			return c.threatGood
		elseif status > 0 then
			return c.threatWarn
		end
		return c.threatBad
	end
	if status >= 2 then
		return c.threatBad
	elseif status == 1 then
		return c.threatWarn
	end
end

function Plate:GetBaseColor()
	local unit = self.unit
	local c = ns.colors
	if UnitIsPlayer(unit) then
		if ns.db.classColors then
			local _, class = UnitClass(unit)
			local cc = class and RAID_CLASS_COLORS[class]
			if cc then
				return { cc.r, cc.g, cc.b }
			end
		end
		return UnitIsFriend("player", unit) and c.friendlyPlayer or c.hostile
	end
	local reaction = UnitReaction(unit, "player") or 4
	if reaction <= 3 then
		return c.hostile
	elseif reaction == 4 then
		return c.neutral
	end
	return c.friendly
end

function Plate:UpdateHealthColor(pct)
	local unit = self.unit
	if not unit then
		return
	end
	local db, c = ns.db, ns.colors

	if not pct then
		local max = UnitHealthMax(unit)
		pct = max > 0 and UnitHealth(unit) / max * 100 or 100
	end

	local color
	if UnitIsTapDenied(unit) then
		color = c.tapped
	elseif db.executeHighlight and not db.tankMode and pct > 0 and pct <= db.executePercent
		and UnitCanAttack("player", unit) then
		color = c.execute
	else
		color = self:GetThreatColor() or self:GetBaseColor()
	end

	local r, g, b = color[1], color[2], color[3]
	self.health:SetStatusBarColor(r, g, b)
	self.health.bg:SetVertexColor(r * 0.2, g * 0.2, b * 0.2, 0.9)
	self.name:SetTextColor(1, 1, 1)
end

function Plate:UpdateTarget()
	local isTarget = UnitIsUnit(self.unit, "target")
	if isTarget then
		self.health.border:SetVertexColor(1, 1, 1, 1)
		self.health.border:SetPoint("TOPLEFT", -2, 2)
		self.health.border:SetPoint("BOTTOMRIGHT", 2, -2)
	else
		self.health.border:SetVertexColor(0, 0, 0, 1)
		self.health.border:SetPoint("TOPLEFT", -1, 1)
		self.health.border:SetPoint("BOTTOMRIGHT", 1, -1)
	end
end

function Plate:UpdateRaidIcon()
	local index = GetRaidTargetIndex(self.unit)
	if index then
		SetRaidTargetIconTexture(self.raidIcon, index)
		self.raidIcon:Show()
	else
		self.raidIcon:Hide()
	end
end

function Plate:GetDebuffIcon(i)
	local icons = self.debuffs.icons
	if icons[i] then
		return icons[i]
	end

	local icon = CreateFrame("Frame", nil, self.debuffs)
	icon.border = icon:CreateTexture(nil, "BACKGROUND")
	icon.border:SetTexture(BAR_TEXTURE)
	icon.border:SetVertexColor(0, 0, 0, 1)
	icon.border:SetPoint("TOPLEFT", -1, 1)
	icon.border:SetPoint("BOTTOMRIGHT", 1, -1)

	icon.texture = icon:CreateTexture(nil, "ARTWORK")
	icon.texture:SetAllPoints()
	icon.texture:SetTexCoord(0.08, 0.92, 0.18, 0.82)

	icon.cooldown = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
	icon.cooldown:SetAllPoints()
	icon.cooldown:SetReverse(true)
	icon.cooldown:SetDrawEdge(false)

	icon.count = icon.cooldown:CreateFontString(nil, "OVERLAY")
	icon.count:SetPoint("BOTTOMRIGHT", 2, -1)

	icon:SetSize(ns.db.debuffSize, ns.db.debuffSize * 0.8)
	setFont(icon.count, ns.db.fontSize - 1)
	icons[i] = icon
	return icon
end

function Plate:UpdateDebuffs()
	local unit = self.unit
	local db = ns.db
	local shown = 0

	if db.showDebuffs and UnitCanAttack("player", unit) then
		for index = 1, 40 do
			if shown >= db.maxDebuffs then
				break
			end
			local texture, count, duration, expirationTime = GetDebuffData(unit, index)
			if not texture then
				break
			end
			shown = shown + 1
			local icon = self:GetDebuffIcon(shown)
			icon.texture:SetTexture(texture)
			icon.count:SetText(count and count > 1 and count or "")
			if duration and duration > 0 then
				icon.cooldown:SetCooldown(expirationTime - duration, duration)
			else
				icon.cooldown:Clear()
			end
			icon:Show()
		end
	end

	local icons = self.debuffs.icons
	for i = shown + 1, #icons do
		icons[i]:Hide()
	end

	local spacing = 3
	local total = shown * db.debuffSize + math.max(shown - 1, 0) * spacing
	for i = 1, shown do
		icons[i]:ClearAllPoints()
		icons[i]:SetPoint("BOTTOMLEFT", self.debuffs, "BOTTOM", -total / 2 + (i - 1) * (db.debuffSize + spacing), 0)
	end
end

function Plate:UpdateCast()
	local unit = self.unit
	local cast = self.cast
	if not unit or not ns.db.castBar then
		cast:Hide()
		return
	end

	local name, _, texture, startMS, endMS, _, castID, notInterruptible = UnitCastingInfo(unit)
	local channel = false
	if not name then
		castID = nil
		name, _, texture, startMS, endMS, _, notInterruptible = UnitChannelInfo(unit)
		channel = name ~= nil
	end
	if not name then
		if not self.castFailedUntil then
			cast:Hide()
		end
		return
	end

	self.castFailedUntil = nil
	cast.channel = channel
	cast.castID = castID
	cast.startTime = startMS / 1000
	cast.endTime = endMS / 1000
	cast:SetMinMaxValues(0, cast.endTime - cast.startTime)
	cast.text:SetText(name)
	cast.icon:SetTexture(texture)

	local color = notInterruptible and ns.colors.castLocked or (channel and ns.colors.channel or ns.colors.cast)
	cast:SetStatusBarColor(color[1], color[2], color[3])
	cast:Show()
	self:OnCastUpdate(cast)
end

function Plate:OnCastUpdate(cast)
	local now = GetTime()
	if self.castFailedUntil then
		if now >= self.castFailedUntil then
			self.castFailedUntil = nil
			cast:Hide()
		end
		return
	end
	if now >= cast.endTime then
		cast:Hide()
		return
	end
	local remaining = cast.endTime - now
	cast:SetValue(cast.channel and remaining or (now - cast.startTime))
	cast.timer:SetFormattedText("%.1f", remaining)
end

function Plate:StopCast()
	if not self.castFailedUntil then
		self.cast:Hide()
	end
end

function Plate:FailCast(castGUID)
	local cast = self.cast
	if not cast:IsShown() or self.castFailedUntil then
		return
	end
	-- FAILED also fires for casts the unit tried and never started; ignore those.
	if cast.castID and castGUID and castGUID ~= cast.castID then
		return
	end
	local c = ns.colors.castFailed
	cast:SetStatusBarColor(c[1], c[2], c[3])
	cast:SetValue(select(2, cast:GetMinMaxValues()))
	cast.text:SetText(INTERRUPTED or "Interrupted")
	cast.timer:SetText("")
	self.castFailedUntil = GetTime() + FAIL_DISPLAY_TIME
end
