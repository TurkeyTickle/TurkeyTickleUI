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
	maxDistance = 60,
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
	print("|cff66ccffForeverPlates|r: " .. msg)
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

function ns:ApplyDistance()
	if InCombatLockdown() then
		self.distancePending = true
		return
	end
	self.distancePending = nil
	if tonumber(GetCVar("nameplateMaxDistance")) ~= self.db.maxDistance then
		SetCVar("nameplateMaxDistance", self.db.maxDistance)
	end
end

function ns:RefreshAll()
	self:ApplyDistance()
	for _, nameplate in ipairs(C_NamePlate.GetNamePlates()) do
		local unit = nameplate.namePlateUnitToken or (nameplate.UnitFrame and nameplate.UnitFrame.unit)
		if unit then
			self:OnPlateRemoved(unit)
			self:OnPlateAdded(unit)
		end
	end
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
	UNIT_THREAT_SITUATION_UPDATE = "UpdateThreat",
	UNIT_THREAT_LIST_UPDATE = "UpdateThreat",
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
	ForeverPlatesDB = ForeverPlatesDB or {}
	copyDefaults(ForeverPlatesDB, ns.defaults)
	ns.db = ForeverPlatesDB
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

function globalHandlers.PLAYER_REGEN_DISABLED()
	ns:ForEachPlate(function(plate)
		plate:UpdateThreat()
	end)
end

function globalHandlers.PLAYER_REGEN_ENABLED()
	globalHandlers.PLAYER_REGEN_DISABLED()
	if ns.distancePending then
		ns:ApplyDistance()
	end
end

function globalHandlers.PLAYER_ENTERING_WORLD()
	ns:ApplyDistance()
end

function globalHandlers.CVAR_UPDATE(name, value)
	if type(name) ~= "string" or name:lower() ~= "nameplatemaxdistance" then
		return
	end
	-- Let other addons raise it temporarily, but put ours back if something lowers it.
	value = tonumber(value)
	if value and value < ns.db.maxDistance then
		C_Timer.After(0, function()
			ns:ApplyDistance()
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

SLASH_FOREVERPLATES1 = "/fplates"
SLASH_FOREVERPLATES2 = "/fp"
SlashCmdList.FOREVERPLATES = function(msg)
	msg = strtrim(msg or ""):lower()
	if msg == "tank" then
		ns.db.tankMode = not ns.db.tankMode
		ns:Print("Tank mode " .. (ns.db.tankMode and "|cff00ff00on|r" or "|cffff4040off|r"))
		ns:RefreshAll()
	elseif msg == "reset" then
		wipe(ForeverPlatesDB)
		copyDefaults(ForeverPlatesDB, ns.defaults)
		ns:RefreshAll()
		ns:Print("Settings reset.")
	else
		ns:OpenOptions()
	end
end
