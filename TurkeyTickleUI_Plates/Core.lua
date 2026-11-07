local ADDON, ns = ...

ns.defaults = {
	width = 130,
	height = 12,
	castHeight = 9,
	fontSize = 10,
	styleFriendly = true,
	showLevel = true,
	healthText = "percent", -- "percent", "value", "both", "none"
	classColors = true,
	threatColors = true,
	tankMode = false,
	threatWarnPercent = 80,
	threatSound = true,
	maxDistance = 60,
	stackPlates = true,
	stackSpacing = 140,
	executeHighlight = true,
	executePercent = 20,
	showDebuffs = true,
	debuffSize = 20,
	maxDebuffs = 6,
	castBar = true,
}

ns.colors = {
	hostile = { 1.00, 0.00, 0.00 },
	neutral = { 1.00, 1.00, 0.00 },
	friendly = { 0.00, 1.00, 0.00 },
	friendlyPlayer = { 0.00, 0.44, 0.87 },
	tapped = { 0.50, 0.50, 0.50 },
	threatWarn = { 1.00, 0.60, 0.00 },
	threatAggro = { 1.00, 0.10, 0.10 },
	execute = { 0.60, 0.35, 1.00 },
	cast = { 1.00, 0.70, 0.00 },
	channel = { 0.00, 1.00, 0.00 },
	locked = { 0.70, 0.70, 0.70 },
	failed = { 1.00, 0.00, 0.00 },
}

ns.plates = {}

local function copyDefaults(dst, src)
	for k, v in pairs(src) do
		if dst[k] == nil then
			dst[k] = v
		end
	end
end

function ns:Print(msg)
	print("|cffe8a33dTurkey Tickle UI|r Plates: " .. msg)
end

function ns:ForEachPlate(fn)
	for unit, plate in pairs(self.plates) do
		fn(plate, unit)
	end
end

function ns:OnPlateAdded(unit)
	local nameplate = C_NamePlate.GetNamePlateForUnit(unit)
	if not nameplate or (nameplate.IsForbidden and nameplate:IsForbidden()) then
		return
	end
	if UnitIsUnit(unit, "player") then
		return
	end
	if not self.db.styleFriendly and not UnitCanAttack("player", unit) then
		self:RestoreBlizzard(nameplate)
		return
	end
	local plate = self:GetPlate(nameplate)
	plate:ApplyLayout()
	self.plates[unit] = plate
	plate:SetUnit(unit)
end

function ns:OnPlateRemoved(unit)
	local plate = self.plates[unit]
	if plate then
		plate:ClearUnit()
		self.plates[unit] = nil
	end
end

function ns:PlayThreatWarning()
	if not self.db.threatSound then
		return
	end
	local now = GetTime()
	if self.lastThreatSound and now - self.lastThreatSound < 3 then
		return
	end
	self.lastThreatSound = now
	PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master")
end

local function setCVarIfChanged(name, value)
	if tonumber(GetCVar(name)) ~= value then
		SetCVar(name, value)
	end
end

-- Nameplate CVars are blocked in combat, so changes made then wait for PLAYER_REGEN_ENABLED.
function ns:ApplyCVars()
	if InCombatLockdown() then
		self.cvarsPending = true
		return
	end
	self.cvarsPending = nil
	local db = self.db
	setCVarIfChanged("nameplateMaxDistance", db.maxDistance)
	setCVarIfChanged("nameplateMotion", db.stackPlates and 1 or 0)
	if db.stackPlates then
		setCVarIfChanged("nameplateOverlapV", db.stackSpacing / 100)
	end
end

function ns:RefreshAll()
	self:ApplyCVars()
	for _, nameplate in ipairs(C_NamePlate.GetNamePlates()) do
		local unit = nameplate.namePlateUnitToken or (nameplate.UnitFrame and nameplate.UnitFrame.unit)
		if unit then
			self:OnPlateRemoved(unit)
			self:OnPlateAdded(unit)
		end
	end
end

function ns:DebugThreat()
	local function show(v)
		if issecretvalue and issecretvalue(v) then
			return "|cffff8000<secret>|r"
		end
		return tostring(v)
	end
	local unit = "target"
	if not UnitExists(unit) then
		self:Print("Target an enemy first.")
		return
	end
	local nameplate = C_NamePlate.GetNamePlateForUnit(unit)
	local styled
	for token, p in pairs(self.plates) do
		if UnitIsUnit(token, unit) then
			styled = p
		end
	end
	self:Print(format("blizzardPlate=%s styled=%s glowOption=%s tankMode=%s warnAt=%d%%", tostring(nameplate ~= nil),
		tostring(styled ~= nil), tostring(self.db.threatColors), tostring(self.db.tankMode), self.db.threatWarnPercent))
	if styled then
		local color, percent = styled:GetThreatState()
		self:Print(format("glowShown=%s state=%s percent=%s", tostring(styled.threatGlow:IsShown()),
			color == self.colors.threatAggro and "aggro" or (color and "warn" or "none"), show(percent)))
	end
	self:Print(format("isPlayer=%s inCombat=%s mobTargetIsMe=%s", show(UnitIsPlayer(unit)),
		show(UnitAffectingCombat(unit)), show(UnitIsUnit("targettarget", "player"))))
	local isTanking, status, scaled, raw = UnitDetailedThreatSituation("player", unit)
	self:Print(format("detailed: tanking=%s status=%s scaled=%s raw=%s", show(isTanking), show(status),
		show(scaled), show(raw)))
	self:Print("simple status=" .. show(UnitThreatSituation("player", unit)))
end

-- Records every texture Blizzard's unit frames use into saved variables, so the art can be matched.
function ns:DumpFrames()
	local out = {}
	local function describeTexture(tex)
		local w, h = tex:GetSize()
		local r, g, b, a = tex:GetVertexColor()
		local _, sub = tex:GetDrawLayer()
		return format("%s | atlas=%s file=%s size=%.0fx%.0f color=%.2f,%.2f,%.2f,%.2f layer=%s:%s shown=%s",
			tex:GetDebugName() or "?", tostring(tex:GetAtlas()), tostring(tex:GetTexture()), w or 0, h or 0,
			r or 1, g or 1, b or 1, a or 1, tostring((tex:GetDrawLayer())), tostring(sub), tostring(tex:IsShown()))
	end
	local function walk(frame, depth)
		if depth > 12 or frame:IsForbidden() then
			return
		end
		if frame.GetStatusBarTexture and frame:GetStatusBarTexture() then
			tinsert(out, "STATUSBAR " .. describeTexture(frame:GetStatusBarTexture()))
		end
		for _, region in ipairs({ frame:GetRegions() }) do
			if region:IsObjectType("Texture") then
				tinsert(out, describeTexture(region))
			end
		end
		for _, child in ipairs({ frame:GetChildren() }) do
			walk(child, depth + 1)
		end
	end
	for _, name in ipairs({ "PlayerFrame", "PetFrame", "TargetFrame" }) do
		if _G[name] then
			walk(_G[name], 0)
		end
	end
	self.db.frameDump = out
	self:Print(format("Saved %d textures. Type /reload so they get written to disk.", #out))
end

local driver = CreateFrame("Frame")
ns.driver = driver

local function isPlateUnit(unit)
	return unit and ns.plates[unit] ~= nil
end

local unitHandlers = {
	UNIT_HEALTH = "UpdateHealth",
	UNIT_MAXHEALTH = "UpdateHealth",
	UNIT_NAME_UPDATE = "UpdateName",
	UNIT_LEVEL = "UpdateName",
	UNIT_FACTION = "UpdateAll",
	UNIT_THREAT_LIST_UPDATE = "UpdateThreat",
	UNIT_TARGET = "UpdateThreat",
	UNIT_AURA = "UpdateDebuffs",
	UNIT_SPELLCAST_START = "UpdateCast",
	UNIT_SPELLCAST_DELAYED = "UpdateCast",
	UNIT_SPELLCAST_CHANNEL_START = "UpdateCast",
	UNIT_SPELLCAST_CHANNEL_UPDATE = "UpdateCast",
	UNIT_SPELLCAST_INTERRUPTIBLE = "UpdateCast",
	UNIT_SPELLCAST_NOT_INTERRUPTIBLE = "UpdateCast",
	UNIT_SPELLCAST_STOP = "StopCast",
	UNIT_SPELLCAST_CHANNEL_STOP = "StopCast",
	UNIT_SPELLCAST_FAILED = "FailCast",
	UNIT_SPELLCAST_INTERRUPTED = "FailCast",
}

local globalHandlers = {}

function globalHandlers.ADDON_LOADED(name)
	if name ~= ADDON then
		return
	end
	TurkeyTickleUI_PlatesDB = TurkeyTickleUI_PlatesDB or {}
	copyDefaults(TurkeyTickleUI_PlatesDB, ns.defaults)
	ns.db = TurkeyTickleUI_PlatesDB
	ns:CreateOptions()
	driver:UnregisterEvent("ADDON_LOADED")
end

function globalHandlers.NAME_PLATE_UNIT_ADDED(unit)
	ns:OnPlateAdded(unit)
end

function globalHandlers.NAME_PLATE_UNIT_REMOVED(unit)
	ns:OnPlateRemoved(unit)
end

function globalHandlers.PLAYER_TARGET_CHANGED()
	ns:ForEachPlate(function(plate)
		plate:UpdateTarget()
	end)
end

function globalHandlers.RAID_TARGET_UPDATE()
	ns:ForEachPlate(function(plate)
		plate:UpdateRaidIcon()
	end)
end

local function updateAllThreat()
	ns:ForEachPlate(function(plate)
		xpcall(plate.UpdateThreat, geterrorhandler(), plate)
	end)
end

-- Fires for the player whose threat changed, not the mob, so refresh every plate.
globalHandlers.UNIT_THREAT_SITUATION_UPDATE = updateAllThreat

-- Threat % changes constantly in combat without always firing an event for each mob.
function globalHandlers.PLAYER_REGEN_DISABLED()
	updateAllThreat()
	if not ns.threatTicker then
		ns.threatTicker = C_Timer.NewTicker(0.25, updateAllThreat)
	end
end

function globalHandlers.PLAYER_REGEN_ENABLED()
	if ns.threatTicker then
		ns.threatTicker:Cancel()
		ns.threatTicker = nil
	end
	updateAllThreat()
	if ns.cvarsPending then
		ns:ApplyCVars()
	end
end

function globalHandlers.PLAYER_ENTERING_WORLD()
	ns:ApplyCVars()
end

function globalHandlers.CVAR_UPDATE(name, value)
	if type(name) ~= "string" or name:lower() ~= "nameplatemaxdistance" then
		return
	end
	-- Let other addons raise it temporarily, but put ours back if something lowers it.
	value = tonumber(value)
	if value and value < ns.db.maxDistance then
		C_Timer.After(0, function()
			ns:ApplyCVars()
		end)
	end
end

driver:SetScript("OnEvent", function(_, event, unit, ...)
	local method = unitHandlers[event]
	if method then
		if isPlateUnit(unit) then
			local plate = ns.plates[unit]
			xpcall(plate[method], geterrorhandler(), plate, ...)
		end
		return
	end
	xpcall(globalHandlers[event], geterrorhandler(), unit, ...)
end)

for event in pairs(globalHandlers) do
	driver:RegisterEvent(event)
end
for event in pairs(unitHandlers) do
	-- Some retail-era events don't exist on every client; skip the ones that error.
	pcall(driver.RegisterEvent, driver, event)
end

SLASH_TURKEYTICKLEUI_PLATES1 = "/ttplates"
SLASH_TURKEYTICKLEUI_PLATES2 = "/ttp"
SlashCmdList.TURKEYTICKLEUI_PLATES = function(msg)
	msg = strtrim(msg or ""):lower()
	if msg == "tank" then
		ns.db.tankMode = not ns.db.tankMode
		ns:Print("Tank mode " .. (ns.db.tankMode and "|cff00ff00on|r" or "|cffff4040off|r"))
		ns:RefreshAll()
	elseif msg == "dump" then
		ns:DumpFrames()
	elseif msg == "threat" then
		ns:DebugThreat()
	elseif msg == "reset" then
		wipe(TurkeyTickleUI_PlatesDB)
		copyDefaults(TurkeyTickleUI_PlatesDB, ns.defaults)
		ns:RefreshAll()
		ns:Print("Settings reset.")
	else
		ns:OpenOptions()
	end
end
