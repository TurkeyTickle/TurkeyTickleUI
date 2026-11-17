local _, ns = ...

local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local SOLID = "Interface\\Buttons\\WHITE8X8"
local SPARK = "Interface\\CastingBar\\UI-CastingBar-Spark"
local FAIL_DISPLAY_TIME = 0.6

local issecretvalue = issecretvalue or function()
	return false
end

-- On this engine, unit APIs can return "secret" values that error when compared or used in math.
-- Anything we branch on goes through known(); secrets read as nil and we fall back to a safe default.
local function known(v)
	if issecretvalue(v) then
		return nil
	end
	return v
end

local function safeCall(fn, ...)
	return xpcall(fn, geterrorhandler(), ...)
end

local function hasAtlas(name)
	return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

-- The tintable fill the Forever unit frames use for status-colored health bars.
local UNIT_FRAME_BAR = "UI-HUD-UnitFrame-Player-PortraitOn-Bar-Health-Status"
if hasAtlas(UNIT_FRAME_BAR) then
	BAR_TEXTURE = UNIT_FRAME_BAR
end
local SHIELD_ATLAS = hasAtlas("nameplates-InterruptShield") and "nameplates-InterruptShield"
local ELITE_ATLAS = hasAtlas("nameplates-icon-elite-gold") and "nameplates-icon-elite-gold"
local RARE_ATLAS = hasAtlas("nameplates-icon-elite-silver") and "nameplates-icon-elite-silver"

-- Only used on clients without aura containers. Fields may be secret; they're only handed to widgets, never compared.
local GetPlayerDebuffs
if C_UnitAuras and C_UnitAuras.GetUnitAuras then
	GetPlayerDebuffs = function(unit)
		return C_UnitAuras.GetUnitAuras(unit, "HARMFUL|PLAYER") or {}
	end
else
	GetPlayerDebuffs = function(unit)
		local auras = {}
		for index = 1, 40 do
			local name, icon, count, _, duration, expirationTime = UnitAura(unit, index, "HARMFUL|PLAYER")
			if not name then
				break
			end
			auras[index] = { icon = icon, applications = count, duration = duration, expirationTime = expirationTime }
		end
		return auras
	end
end

local function getLevelColor(unit, level)
	if C_PlayerInfo and C_PlayerInfo.GetContentDifficultyCreatureForPlayer and GetDifficultyColor then
		local difficulty = known(C_PlayerInfo.GetContentDifficultyCreatureForPlayer(unit))
		if difficulty then
			return GetDifficultyColor(difficulty)
		end
	end
	local legacy = GetCreatureDifficultyColor or GetQuestDifficultyColor
	return legacy(level)
end
local UnitIsTapDenied = UnitIsTapDenied or function()
	return false
end

local CLASSIFICATION_SUFFIX = {
	elite = "+",
	rareelite = "+",
	rare = "",
	worldboss = "",
}

local function fontFile()
	local object = SystemFont_NamePlate or GameFontNormalSmall
	return (object and object:GetFont()) or STANDARD_TEXT_FONT
end

local function setFont(fs, size)
	fs:SetFont(fontFile(), size, "")
	fs:SetShadowColor(0, 0, 0, 1)
	fs:SetShadowOffset(1, -1)
end

local function abbreviate(n)
	if AbbreviateLargeNumbers then
		return AbbreviateLargeNumbers(n)
	end
	n = known(n)
	if not n then
		return ""
	elseif n >= 1e6 then
		return format("%.1fm", n / 1e6)
	elseif n >= 1e4 then
		return format("%.0fk", n / 1e3)
	end
	return tostring(n)
end

local BORDER_STYLES = {
	normal = { { 0.07, 0.05, 0.03 } },
	target = { { 0.70, 0.54, 0.16 } },
}
local BORDER_SIZE = #BORDER_STYLES.normal

local Border = {}

function Border:SetStyle(name)
	local colors = BORDER_STYLES[name]
	for i, color in ipairs(colors) do
		self[i]:SetVertexColor(color[1], color[2], color[3], 1)
	end
	local inner = colors[#colors]
	for _, strip in ipairs(self.lip) do
		strip:SetVertexColor(inner[1], inner[2], inner[3], 1)
	end
end

-- The unit frame bar fill has a dark edge baked in, so the innermost bronze overlaps the fill by a pixel to hide it.
local function addLip(frame, anchor)
	local lip = {}
	for _, side in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" } }) do
		local strip = frame:CreateTexture(nil, "OVERLAY", nil, -8)
		strip:SetTexture(SOLID)
		strip:SetPoint(side[1], anchor)
		strip:SetPoint(side[2], anchor)
		strip:SetHeight(1)
		tinsert(lip, strip)
	end
	for _, side in ipairs({ { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
		local strip = frame:CreateTexture(nil, "OVERLAY", nil, -8)
		strip:SetTexture(SOLID)
		strip:SetPoint(side[1], anchor)
		strip:SetPoint(side[2], anchor)
		strip:SetWidth(1)
		tinsert(lip, strip)
	end
	return lip
end

local function addBorder(frame, anchor)
	anchor = anchor or frame
	local border = Mixin({}, Border)
	for i = 1, BORDER_SIZE do
		local inset = BORDER_SIZE + 1 - i
		local ring = frame:CreateTexture(nil, "BACKGROUND", nil, -9 + i)
		ring:SetTexture(SOLID)
		ring:SetPoint("TOPLEFT", anchor, -inset, inset)
		ring:SetPoint("BOTTOMRIGHT", anchor, inset, -inset)
		border[i] = ring
	end
	border.lip = addLip(frame, anchor)
	border:SetStyle("normal")
	return border
end

-- Clients with secret auras refuse every aura query from addon code in combat. Blizzard's aura containers read
-- the auras themselves and fill in frames we style, so they're the only way to show them there.
local HAS_AURA_CONTAINERS = C_XMLUtil and C_XMLUtil.GetTemplateInfo
	and C_XMLUtil.GetTemplateInfo("CustomAuraContainerTemplate") and true or false
local DEBUFF_GROUP = "mine"
local DEBUFF_SPACING = 6

local function debuffLayout()
	local db = ns.db
	return {
		elementWidth = db.debuffSize,
		elementHeight = db.debuffSize * 0.75,
		elementSpacing = DEBUFF_SPACING,
		lineSpacing = DEBUFF_SPACING,
		maximumLineSize = math.huge,
	}
end

-- Aura buttons turn forbidden once they've shown an aura, so they can only be styled here, when first created.
local function initDebuffButton(button)
	local db = ns.db
	button:SetSize(db.debuffSize, db.debuffSize * 0.75)
	button:SetMouseMotionEnabled(false)
	addBorder(button)

	button.icon = button:CreateTexture(nil, "ARTWORK")
	button.icon:SetAllPoints()
	button.icon:SetTexCoord(0.08, 0.92, 0.2, 0.8)
	button:SetIcon(button.icon)

	button.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
	button.cooldown:SetAllPoints()
	button.cooldown:SetReverse(true)
	button.cooldown:SetDrawEdge(false)
	button:SetDurationCooldown(button.cooldown)

	button.count = button.cooldown:CreateFontString(nil, "OVERLAY")
	button.count:SetPoint("BOTTOMRIGHT", 2, -1)
	setFont(button.count, db.fontSize - 1)
	button:SetApplicationCount(button.count)
end

local function debuffStyleKey()
	return ns.db.debuffSize .. ":" .. ns.db.fontSize
end

local function createAuraContainer(parent)
	local container = CreateFrame("AuraContainer", nil, parent, "CustomAuraContainerTemplate")
	container:SetSize(1, 1)
	container.styleKey = debuffStyleKey()
	container:AddAuraGroup(DEBUFF_GROUP, "HARMFUL|PLAYER", {
		maxFrameCount = math.max(ns.db.maxDebuffs, 1),
		sortMethod = AuraContainerSortMethod.Default,
		sortDirection = AuraContainerSortDirection.Normal,
		initializeFrame = initDebuffButton,
		layout = debuffLayout(),
	})
	container:SetFlowLayoutAnchorPoint("BOTTOMLEFT")
	container:SetFlowLayoutGrowthDirection(AnchorUtil.FlowDirection.Right, AnchorUtil.FlowDirection.Up)
	container:SetFlowLayoutMaximumLineSize(math.huge)
	container:SetEnabled(false)
	return container
end

local function createBar(parent)
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetStatusBarTexture(BAR_TEXTURE)
	bar.border = addBorder(bar)
	bar.bg = bar:CreateTexture(nil, "BACKGROUND", nil, 0)
	bar.bg:SetTexture(SOLID)
	bar.bg:SetVertexColor(0.05, 0.05, 0.05, 1)
	bar.bg:SetAllPoints()
	return bar
end

local function hideBlizzardFrame(nameplate)
	local uf = nameplate.UnitFrame
	if not uf or uf.turkeyTicklePlatesHooked then
		return
	end
	uf.turkeyTicklePlatesHooked = true
	uf:HookScript("OnShow", function(self)
		local plate = nameplate.TurkeyTicklePlate
		if plate and plate.unit then
			self:Hide()
		end
	end)
end

local Plate = {}

function ns:GetPlate(nameplate)
	if nameplate.TurkeyTicklePlate then
		return nameplate.TurkeyTicklePlate
	end

	local plate = Mixin(CreateFrame("Frame", nil, nameplate), Plate)
	plate.nameplate = nameplate
	plate:SetPoint("CENTER")
	plate:EnableMouse(false)

	plate.health = createBar(plate)
	plate.health:SetAllPoints()

	-- Sits below the health frame, so only the parts outside the bar show: a solid ring plus a soft outer halo.
	plate.threatGlow = CreateFrame("Frame", nil, plate)
	plate.threatGlow:SetFrameLevel(plate:GetFrameLevel())
	plate.threatGlow:SetAllPoints(plate.health)
	plate.threatGlow.layers = {}
	for i, layer in ipairs({ { 6, 1 }, { 9, 0.45 }, { 12, 0.2 } }) do
		local tex = plate.threatGlow:CreateTexture(nil, "BACKGROUND", nil, -i)
		tex:SetTexture(SOLID)
		tex:SetPoint("TOPLEFT", -layer[1], layer[1])
		tex:SetPoint("BOTTOMRIGHT", layer[1], -layer[1])
		tex.alpha = layer[2]
		plate.threatGlow.layers[i] = tex
	end
	plate.threatGlow:Hide()

	plate.threatPulse = plate.threatGlow:CreateAnimationGroup()
	plate.threatPulse:SetLooping("BOUNCE")
	local fade = plate.threatPulse:CreateAnimation("Alpha")
	fade:SetFromAlpha(1)
	fade:SetToAlpha(0.25)
	fade:SetDuration(0.35)

	plate.healthText = plate.health:CreateFontString(nil, "OVERLAY")
	plate.healthText:SetPoint("CENTER", 0, 0)

	plate.threatAlert = CreateFrame("Frame", nil, plate)
	plate.threatAlert:SetSize(1, 1)
	plate.threatAlert:SetPoint("RIGHT", plate.health, "LEFT", -6, 0)
	plate.threatAlert:Hide()
	plate.threatText = plate.threatAlert:CreateFontString(nil, "OVERLAY")
	plate.threatText:SetPoint("RIGHT")
	plate.threatBang = plate.threatAlert:CreateFontString(nil, "OVERLAY")
	plate.threatBang:SetPoint("RIGHT", plate.threatText, "LEFT", -1, 1)
	plate.threatAlertPulse = plate.threatAlert:CreateAnimationGroup()
	plate.threatAlertPulse:SetLooping("BOUNCE")
	local alertFade = plate.threatAlertPulse:CreateAnimation("Alpha")
	alertFade:SetFromAlpha(1)
	alertFade:SetToAlpha(0.4)
	alertFade:SetDuration(0.35)

	plate.name = plate:CreateFontString(nil, "OVERLAY")
	plate.name:SetPoint("BOTTOM", plate.health, "TOP", 0, BORDER_SIZE + 3)
	plate.name:SetWordWrap(false)

	plate.level = plate.health:CreateFontString(nil, "OVERLAY")
	plate.level:SetPoint("LEFT", plate.health, "RIGHT", 4, 0)

	plate.elite = plate.health:CreateTexture(nil, "OVERLAY")
	plate.elite:SetSize(14, 14)
	plate.elite:SetPoint("LEFT", plate.level, "RIGHT", 1, 0)
	plate.elite:Hide()

	plate.raidIcon = plate:CreateTexture(nil, "OVERLAY")
	plate.raidIcon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
	plate.raidIcon:SetSize(22, 22)
	plate.raidIcon:SetPoint("LEFT", plate.health, "RIGHT", 36, 0)

	plate.cast = createBar(plate)
	plate.cast:SetPoint("TOPLEFT", plate.health, "BOTTOMLEFT", 0, -5)
	plate.cast:SetPoint("TOPRIGHT", plate.health, "BOTTOMRIGHT", 0, -5)
	plate.cast.bg:SetVertexColor(0, 0, 0, 0.6)
	plate.cast:Hide()
	plate.cast:SetScript("OnUpdate", function(bar)
		plate:OnCastUpdate(bar)
	end)

	plate.cast.spark = plate.cast:CreateTexture(nil, "OVERLAY")
	plate.cast.spark:SetTexture(SPARK)
	plate.cast.spark:SetBlendMode("ADD")
	plate.cast.spark:SetWidth(16)

	plate.cast.icon = plate.cast:CreateTexture(nil, "OVERLAY")
	plate.cast.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	plate.cast.icon:SetPoint("RIGHT", plate.cast, "LEFT", -5, 0)
	plate.cast.iconBorder = addBorder(plate.cast, plate.cast.icon)

	plate.cast.shield = plate.cast:CreateTexture(nil, "OVERLAY", nil, 1)
	if SHIELD_ATLAS then
		plate.cast.shield:SetAtlas(SHIELD_ATLAS)
	end
	plate.cast.shield:SetPoint("CENTER", plate.cast.icon, "CENTER")
	plate.cast.shield:Hide()

	plate.cast.text = plate.cast:CreateFontString(nil, "OVERLAY")
	plate.cast.text:SetPoint("TOP", plate.cast, "BOTTOM", 0, -2)
	plate.cast.text:SetWordWrap(false)

	plate.cast.timer = plate.cast:CreateFontString(nil, "OVERLAY")
	plate.cast.timer:SetPoint("LEFT", plate.cast, "RIGHT", 4, 0)

	plate.debuffs = CreateFrame("Frame", nil, plate)
	plate.debuffs:SetSize(1, 1)
	plate.debuffs.icons = {}
	if HAS_AURA_CONTAINERS then
		plate.auraContainer = createAuraContainer(plate)
	end

	nameplate.TurkeyTicklePlate = plate
	hideBlizzardFrame(nameplate)
	plate:ApplyLayout()
	return plate
end

function ns:RestoreBlizzard(nameplate)
	local plate = nameplate.TurkeyTicklePlate
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
	self.cast.spark:SetHeight(db.castHeight * 2.5)
	self.cast.icon:SetSize(db.castHeight + 4, db.castHeight + 4)
	self.cast.shield:SetSize(db.castHeight * 1.6, db.castHeight * 2)
	self.cast.text:SetWidth(db.width)
	self.name:SetWidth(db.width + 40)
	setFont(self.name, db.fontSize)
	setFont(self.level, db.fontSize - 1)
	setFont(self.healthText, db.fontSize - 2)
	self.threatText:SetFont(fontFile(), db.fontSize + 1, "OUTLINE")
	self.threatBang:SetFont(fontFile(), db.fontSize + 7, "OUTLINE")
	self.threatBang:SetText("!")
	setFont(self.cast.text, db.fontSize - 1)
	setFont(self.cast.timer, db.fontSize - 2)
	self.debuffs:ClearAllPoints()
	self.debuffs:SetPoint("BOTTOM", self.health, "TOP", 0, db.fontSize + BORDER_SIZE + 9)
	for _, icon in ipairs(self.debuffs.icons) do
		icon:SetSize(db.debuffSize, db.debuffSize * 0.75)
		setFont(icon.count, db.fontSize - 1)
	end

	local container = self.auraContainer
	if container then
		if container.styleKey ~= debuffStyleKey() then
			self:DisableAuraContainer()
			container:SetParent(nil)
			container = createAuraContainer(self)
			self.auraContainer = container
		end
		container:ClearAllPoints()
		container:SetPoint("BOTTOMLEFT", self.health, "TOPLEFT", 0, db.fontSize + BORDER_SIZE + 9)
		container:SetAuraGroupMaxFrameCount(DEBUFF_GROUP, math.max(db.maxDebuffs, 1))
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
	self.threatState = nil
	self.threatPulse:Stop()
	self.threatAlertPulse:Stop()
	self.threatGlow:Hide()
	self.threatAlert:Hide()
	self.cast:Hide()
	self:DisableAuraContainer()
	self:Hide()
end

local UPDATE_ORDER = { "UpdateHealth", "UpdateThreat", "UpdateName", "UpdateTarget", "UpdateRaidIcon", "UpdateDebuffs", "UpdateCast" }

function Plate:UpdateAll()
	if not self.unit then
		return
	end
	for _, method in ipairs(UPDATE_ORDER) do
		safeCall(self[method], self)
	end
end

function Plate:UpdateName()
	local unit = self.unit
	self.name:SetText(UnitName(unit) or "")
	self.name:SetTextColor(1, 0.82, 0)

	self.elite:Hide()
	local level = known(UnitLevel(unit))
	if not ns.db.showLevel or not level then
		self.level:SetText("")
		return
	end

	local classification = known(UnitClassification(unit))
	local suffix = classification and CLASSIFICATION_SUFFIX[classification] or ""
	local icon = (classification == "elite" or classification == "worldboss") and ELITE_ATLAS
		or ((classification == "rare" or classification == "rareelite") and RARE_ATLAS)
	if icon then
		self.elite:SetAtlas(icon)
		self.elite:Show()
		suffix = ""
	end

	if level < 0 then
		self.level:SetText("??" .. suffix)
		self.level:SetTextColor(1, 0.1, 0.1)
	else
		self.level:SetText(level .. suffix)
		local color = getLevelColor(unit, level)
		self.level:SetTextColor(color.r, color.g, color.b)
	end
end

-- Returns the health percent as a plain number, or nil when the game hides it.
function Plate:GetHealthPercent()
	local cur, max = known(UnitHealth(self.unit)), known(UnitHealthMax(self.unit))
	if cur and max and max > 0 then
		return cur / max * 100
	end
end

function Plate:UpdateHealth()
	local unit = self.unit
	local cur, max = UnitHealth(unit), UnitHealthMax(unit)
	self.health:SetMinMaxValues(0, max)
	self.health:SetValue(cur)

	local mode = ns.db.healthText
	local pct = self:GetHealthPercent()
	local displayPct = pct
	if not displayPct and UnitHealthPercent and CurveConstants and CurveConstants.ScaleTo100 then
		displayPct = UnitHealthPercent(unit, false, CurveConstants.ScaleTo100)
	end

	if mode == "percent" and displayPct then
		self.healthText:SetFormattedText("%.0f%%", displayPct)
	elseif mode == "value" then
		self.healthText:SetText(abbreviate(cur))
	elseif mode == "both" and displayPct then
		self.healthText:SetFormattedText("%s - %.0f%%", abbreviate(cur), displayPct)
	else
		self.healthText:SetText("")
	end

	self:UpdateHealthColor(pct)
end

-- Returns the glow color and optional threat % text for this unit, or nil for no indicator.
function Plate:GetThreatState()
	local unit = self.unit
	if not ns.db.threatColors or known(UnitIsPlayer(unit)) == true then
		return
	end
	local c = ns.colors
	local isTanking, status, scaledPercent = UnitDetailedThreatSituation("player", unit)
	isTanking, status, scaledPercent = known(isTanking), known(status), known(scaledPercent)
	if not status then
		-- No usable threat data: fall back to who the mob is attacking.
		if known(UnitAffectingCombat(unit)) ~= true or known(UnitExists(unit .. "target")) ~= true then
			return
		end
		local onMe = known(UnitIsUnit(unit .. "target", "player"))
		if onMe == nil then
			return
		end
		if ns.db.tankMode then
			return not onMe and c.threatAggro or nil
		end
		return onMe and c.threatAggro or nil
	end
	if ns.db.tankMode then
		if status == 3 then
			return
		elseif status == 2 then
			return c.threatWarn
		end
		return c.threatAggro
	end
	if isTanking or status >= 2 then
		return c.threatAggro
	end
	if status == 1 or (scaledPercent and scaledPercent >= ns.db.threatWarnPercent) then
		return c.threatWarn, scaledPercent
	end
end

function Plate:UpdateThreat()
	if not self.unit then
		return
	end
	local color, percent = self:GetThreatState()
	local state = color and (color == ns.colors.threatWarn and "warn" or "aggro")
	local glow = self.threatGlow

	if color then
		for _, tex in ipairs(glow.layers) do
			tex:SetVertexColor(color[1], color[2], color[3], tex.alpha)
		end
		glow:Show()
	else
		glow:Hide()
	end

	if state == "warn" then
		if not self.threatPulse:IsPlaying() then
			self.threatPulse:Play()
			self.threatAlertPulse:Play()
		end
		self.threatBang:SetTextColor(color[1], color[2], color[3])
		self.threatText:SetTextColor(color[1], color[2], color[3])
		self.threatText:SetText(percent and format("%.0f%%", percent) or "")
		self.threatAlert:Show()
	else
		self.threatPulse:Stop()
		self.threatAlertPulse:Stop()
		self.threatAlert:Hide()
	end

	if state == "warn" and self.threatState ~= "warn" then
		ns:PlayThreatWarning()
	end
	self.threatState = state
end

function Plate:GetBaseColor()
	local unit = self.unit
	local c = ns.colors
	if known(UnitIsPlayer(unit)) then
		if ns.db.classColors then
			local _, class = UnitClass(unit)
			local cc = known(class) and RAID_CLASS_COLORS[class]
			if cc then
				return { cc.r, cc.g, cc.b }
			end
		end
		return known(UnitIsFriend("player", unit)) and c.friendlyPlayer or c.hostile
	end
	local reaction = known(UnitReaction(unit, "player")) or 4
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
	pct = pct or self:GetHealthPercent()

	local color
	if known(UnitIsTapDenied(unit)) then
		color = c.tapped
	elseif db.executeHighlight and not db.tankMode and pct and pct > 0 and pct <= db.executePercent
		and known(UnitCanAttack("player", unit)) then
		color = c.execute
	else
		color = self:GetBaseColor()
	end

	local r, g, b = color[1], color[2], color[3]
	self.health:SetStatusBarColor(r, g, b)
end

function Plate:UpdateTarget()
	self.health.border:SetStyle(known(UnitIsUnit(self.unit, "target")) == true and "target" or "normal")
end

function Plate:UpdateRaidIcon()
	local index = known(GetRaidTargetIndex(self.unit))
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
	addBorder(icon)

	icon.texture = icon:CreateTexture(nil, "ARTWORK")
	icon.texture:SetAllPoints()
	icon.texture:SetTexCoord(0.08, 0.92, 0.2, 0.8)

	icon.cooldown = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
	icon.cooldown:SetAllPoints()
	icon.cooldown:SetReverse(true)
	icon.cooldown:SetDrawEdge(false)

	icon.count = icon.cooldown:CreateFontString(nil, "OVERLAY")
	icon.count:SetPoint("BOTTOMRIGHT", 2, -1)

	icon:SetSize(ns.db.debuffSize, ns.db.debuffSize * 0.75)
	setFont(icon.count, ns.db.fontSize - 1)
	icons[i] = icon
	return icon
end

function Plate:SetDebuffCount(icon, count)
	if C_StringUtil and C_StringUtil.TruncateWhenZero then
		icon.count:SetText(C_StringUtil.TruncateWhenZero(count))
		return
	end
	count = known(count)
	icon.count:SetText(count and count > 1 and count or "")
end

function Plate:SetDebuffCooldown(icon, aura)
	local cooldown = icon.cooldown
	if aura.auraInstanceID and C_UnitAuras.GetAuraDuration and cooldown.SetCooldownFromDurationObject then
		local durationObject = C_UnitAuras.GetAuraDuration(self.unit, aura.auraInstanceID)
		if durationObject then
			cooldown:SetCooldownFromDurationObject(durationObject)
			if cooldown.SetAlphaFromBoolean then
				cooldown:SetAlphaFromBoolean(durationObject:IsZero(), 0, 1)
			end
		else
			cooldown:Clear()
		end
		return
	end
	local duration, expirationTime = known(aura.duration), known(aura.expirationTime)
	if duration and expirationTime and duration > 0 then
		cooldown:SetCooldown(expirationTime - duration, duration)
	else
		cooldown:Clear()
	end
end

function Plate:DisableAuraContainer()
	local container = self.auraContainer
	if container then
		container:SetEnabled(false)
		container:Hide()
		container.boundUnit = nil
	end
end

function Plate:UpdateDebuffs()
	local unit = self.unit
	local db = ns.db
	local shown = 0

	local container = self.auraContainer
	if container then
		if not (db.showDebuffs and db.maxDebuffs > 0 and known(UnitCanAttack("player", unit))) then
			self:DisableAuraContainer()
		elseif container.boundUnit ~= unit then
			-- The container tracks the unit's aura events itself once bound.
			container:SetEnabled(true)
			container:SetUnit(unit)
			container:Show()
			container.boundUnit = unit
		end
		return
	end

	if db.showDebuffs and known(UnitCanAttack("player", unit)) then
		for _, aura in ipairs(GetPlayerDebuffs(unit)) do
			if shown >= db.maxDebuffs then
				break
			end
			shown = shown + 1
			local icon = self:GetDebuffIcon(shown)
			icon.texture:SetTexture(aura.icon)
			self:SetDebuffCount(icon, aura.applications)
			self:SetDebuffCooldown(icon, aura)
			icon:Show()
		end
	end

	local icons = self.debuffs.icons
	for i = shown + 1, #icons do
		icons[i]:Hide()
	end

	local spacing = 6
	local total = shown * db.debuffSize + math.max(shown - 1, 0) * spacing
	for i = 1, shown do
		icons[i]:ClearAllPoints()
		icons[i]:SetPoint("BOTTOMLEFT", self.debuffs, "BOTTOM", -total / 2 + (i - 1) * (db.debuffSize + spacing), 0)
	end
end

function Plate:SetCastStyle(kind)
	local cast = self.cast
	local color = ns.colors[kind]
	cast:SetStatusBarColor(color[1], color[2], color[3])
	cast.shield:SetShown(kind == "locked" and SHIELD_ATLAS ~= nil)
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
	if not issecretvalue(name) and name == nil then
		castID = nil
		name, _, texture, startMS, endMS, _, notInterruptible = UnitChannelInfo(unit)
		channel = true
	end
	if not issecretvalue(name) and name == nil then
		if not self.castFailedUntil then
			cast:Hide()
		end
		return
	end

	self.castFailedUntil = nil
	cast.channel = channel
	cast.castID = known(castID)
	cast.text:SetText(name)
	cast.icon:SetTexture(texture)
	cast.timer:SetText("")

	startMS, endMS = known(startMS), known(endMS)
	if startMS and endMS then
		cast.startTime = startMS / 1000
		cast.endTime = endMS / 1000
		cast:SetMinMaxValues(0, cast.endTime - cast.startTime)
	else
		local durationFn = channel and UnitChannelDuration or UnitCastingDuration
		if not (durationFn and cast.SetTimerDuration) then
			cast:Hide()
			return
		end
		cast.endTime = nil
		cast:SetTimerDuration(durationFn(unit))
	end

	local locked = known(notInterruptible)
	self:SetCastStyle(locked and "locked" or (channel and "channel" or "cast"))
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
	if not cast.endTime then
		cast.spark:Hide()
		return
	end
	if now >= cast.endTime then
		cast:Hide()
		return
	end
	local remaining = cast.endTime - now
	local total = cast.endTime - cast.startTime
	local value = cast.channel and remaining or (now - cast.startTime)
	cast:SetValue(value)
	cast.timer:SetFormattedText("%.1f", remaining)
	cast.spark:SetPoint("CENTER", cast, "LEFT", cast:GetWidth() * value / total, 0)
	cast.spark:Show()
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
	castGUID = known(castGUID)
	if cast.castID and castGUID and castGUID ~= cast.castID then
		return
	end
	self:SetCastStyle("failed")
	cast:SetMinMaxValues(0, 1)
	cast:SetValue(1)
	cast.spark:Hide()
	cast.text:SetText(INTERRUPTED or "Interrupted")
	cast.timer:SetText("")
	self.castFailedUntil = GetTime() + FAIL_DISPLAY_TIME
end
