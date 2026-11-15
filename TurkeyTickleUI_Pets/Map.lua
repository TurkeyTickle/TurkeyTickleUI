local _, ns = ...

local COLORS = {
	tracked = { 0.25, 1.00, 0.35 },
	special = { 0.75, 0.45, 1.00 },
	trainer = { 1.00, 0.82, 0.20 },
}

local function isSecret(v)
	return issecretvalue and issecretvalue(v)
end

local function vector(x, y)
	return CreateVector2D and CreateVector2D(x, y) or { x = x, y = y }
end

local function xyOf(pos)
	if not pos or isSecret(pos) then
		return nil
	end
	if pos.GetXY then
		return pos:GetXY()
	end
	return pos.x, pos.y
end

-- Coordinates ---------------------------------------------------------------
-- Spawn points are map percentages in either the Classic Era frame (era = true) or the live Forever frame.
-- Forever moved some zones, so both are taken through world coordinates before landing on the open map.

local worldCache = {}

local function toWorld(mapID, era, x, y)
	if era then
		local b = ns.eraMapFrames[mapID]
		if b then
			return b.c, b.top + (b.bottom - b.top) * y / 100, b.left + (b.right - b.left) * x / 100
		end
		return nil
	end
	if not (C_Map and C_Map.GetWorldPosFromMapPos) then
		return nil
	end
	local ok, continent, pos = pcall(C_Map.GetWorldPosFromMapPos, mapID, vector(x / 100, y / 100))
	local wx, wy = xyOf(ok and pos)
	if continent and wx then
		return continent, wx, wy
	end
end

-- Every spawn point of an NPC, once: { mapID, era, x, y, group, continent, wx, wy }.
function ns:SpawnPoints(npcID, npc)
	local points = worldCache[npcID]
	if points then
		return points
	end
	points = {}
	for group, spawn in ipairs(npc.s or {}) do
		local mapID, era = spawn[1], spawn[2]
		for i = 3, #spawn - 1, 2 do
			local x, y = spawn[i], spawn[i + 1]
			local c, wx, wy = toWorld(mapID, era, x, y)
			tinsert(points, { mapID = mapID, era = era, x = x, y = y, group = group, c = c, wx = wx, wy = wy })
		end
	end
	worldCache[npcID] = points
	return points
end

-- Point position (0-1) on uiMapID, or nil when it isn't on that map.
function ns:ProjectPoint(point, mapID)
	if point.c and C_Map and C_Map.GetMapPosFromWorldPos then
		local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, point.c, vector(point.wx, point.wy), mapID)
		local x, y = xyOf(ok and pos)
		if x then
			if x >= 0 and x <= 1 and y >= 0 and y <= 1 then
				return x, y
			end
			return nil
		end
	end
	if point.mapID == mapID then
		return point.x / 100, point.y / 100
	end
end

function ns:PlayerWorldPosition()
	if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then
		return nil
	end
	local mapID = C_Map.GetBestMapForUnit("player")
	if not mapID or isSecret(mapID) then
		return nil
	end
	local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
	local x, y = xyOf(ok and pos)
	if not x then
		return nil
	end
	return toWorld(mapID, false, x * 100, y * 100)
end

-- Yards to the closest spawn on the player's continent, plus that spawn. pos is a cached
-- { c, x, y } from PlayerWorldPosition, looked up when not given.
function ns:NearestSpawn(npcID, npc, pos)
	local c, px, py
	if pos then
		c, px, py = pos.c, pos.x, pos.y
	else
		c, px, py = self:PlayerWorldPosition()
	end
	local best, bestPoint
	for _, point in ipairs(self:SpawnPoints(npcID, npc)) do
		if c and point.c == c then
			local d = math.sqrt((point.wx - px) ^ 2 + (point.wy - py) ^ 2)
			if not best or d < best then
				best, bestPoint = d, point
			end
		end
	end
	return best, bestPoint
end

-- What goes on the map ----------------------------------------------------

function ns:MapEntries()
	local entries, seen = {}, {}
	local function add(kind, npcID, npc)
		if not seen[npcID] and npc and npc.s then
			seen[npcID] = true
			tinsert(entries, { kind = kind, id = npcID, npc = npc })
		end
	end
	local db = self.db
	if db.showTracked then
		for npcID in pairs(self.char.tracked) do
			add("tracked", npcID, self.npcs[npcID] or self.trainers[npcID])
		end
	end
	if db.showSpecial then
		for npcID, npc in pairs(self.npcs) do
			if npc.lists and not npc.untameable then
				add("special", npcID, npc)
			end
		end
	end
	if db.showTrainers then
		local faction = self:PlayerFaction()
		for npcID, trainer in pairs(self.trainers) do
			if not db.myFactionOnly or not faction or trainer.faction == "" or trainer.faction == faction then
				add("trainer", npcID, trainer)
			end
		end
	end
	return entries
end

local function isZoomedOut(mapID)
	local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
	local types = Enum and Enum.UIMapType
	return info and types and info.mapType and info.mapType <= types.Continent
end

-- Pins ----------------------------------------------------------------------
-- Forever's gamepad interface reads the world map from secure code, so nothing here writes into the
-- map: no data provider, no AcquirePin, no map method that sets fields. Pins are our own frames under
-- the canvas, made without a parent first, and take no OnMouseDown/OnMouseUp script (the gamepad
-- navigation reads those back). Clicks come from GLOBAL_MOUSE_DOWN/UP while the pointer is on a pin.

local pins, shownPins = {}, 0
local view = {}
local mousePin, pressedPin

local function canvas()
	return WorldMapFrame and WorldMapFrame.GetCanvas and WorldMapFrame:GetCanvas()
end

local function frameUnder(parent)
	local f = CreateFrame("Frame")
	f:SetParent(parent)
	return f
end

local function passRightButton(pin)
	if InCombatLockdown() then
		view.passPending = true
	elseif pin.SetPassThroughButtons then
		pcall(pin.SetPassThroughButtons, pin, "RightButton")
		pin.passThroughSet = true
	end
end

local function createPin(parent)
	local pin = frameUnder(parent)
	pin.Glow = pin:CreateTexture(nil, "BACKGROUND")
	pin.Glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	pin.Glow:SetBlendMode("ADD")
	pin.Glow:SetPoint("CENTER")
	pin.Ring = pin:CreateTexture(nil, "BORDER")
	pin.Ring:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
	pin.Ring:SetPoint("TOPLEFT", -2, 2)
	pin.Ring:SetPoint("BOTTOMRIGHT", 2, -2)
	pin.Icon = pin:CreateTexture(nil, "ARTWORK")
	pin.Icon:SetAllPoints()
	pin.Mask = pin:CreateMaskTexture()
	pin.Mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	pin.Mask:SetAllPoints(pin.Icon)
	pin.Icon:AddMaskTexture(pin.Mask)
	pin:EnableMouse(true)
	pin:SetScript("OnEnter", function(self)
		mousePin = self
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		ns:FillTooltip(GameTooltip, self.entry.id, self.entry.npc, true)
		GameTooltip:Show()
	end)
	pin:SetScript("OnLeave", function(self)
		if mousePin == self then
			mousePin = nil
		end
		GameTooltip:Hide()
	end)
	passRightButton(pin)
	return pin
end

local function stylePin(pin, entry)
	local size = ns.db.pinSize
	pin:SetSize(size, size)
	pin.Glow:SetSize(size * 2.4, size * 2.4)
	pin.Glow:SetShown(entry.kind == "tracked")
	local color = COLORS[entry.kind]
	pin.Glow:SetVertexColor(color[1], color[2], color[3], 0.9)
	pin.Ring:SetVertexColor(color[1], color[2], color[3])
	if entry.kind == "trainer" then
		pin.Icon:SetTexture("Interface\\Icons\\Ability_Hunter_BeastTraining")
	else
		pin.Icon:SetTexture(ns:FamilyIcon(entry.npc.f))
	end
end

-- Constant size on screen, growing a little as the map zooms in (like SetScalingLimits(1, 1, 1.25)).
local function pinScale()
	local map = WorldMapFrame
	local scale = map.GetCanvasScale and map:GetCanvasScale() or 1
	local zoom = map.GetCanvasZoomPercent and map:GetCanvasZoomPercent() or 0
	if not scale or scale <= 0 then
		scale = 1
	end
	return (1 + 0.25 * (zoom or 0)) / scale
end

local function layoutPins()
	local parent = canvas()
	if not parent then
		return
	end
	local width, height = parent:GetWidth(), parent:GetHeight()
	local scale = pinScale()
	for i = 1, shownPins do
		local pin = pins[i]
		pin:SetScale(scale)
		pin:ClearAllPoints()
		pin:SetPoint("CENTER", parent, "TOPLEFT", pin.x * width / scale, -pin.y * height / scale)
	end
end

local function frameLevel()
	local map = WorldMapFrame
	local ok, manager = pcall(map.GetPinFrameLevelsManager, map)
	if ok and manager and manager.GetValidFrameLevel then
		local okLevel, level = pcall(manager.GetValidFrameLevel, manager, "PIN_FRAME_LEVEL_VIGNETTE")
		if okLevel and level then
			return level
		end
	end
	return (canvas():GetFrameLevel() or 1) + 20
end

local function drawPins()
	local parent = canvas()
	local mapID = WorldMapFrame:GetMapID()
	local count = 0
	if parent and mapID then
		local zoomedOut = isZoomedOut(mapID)
		local level = frameLevel()
		for _, entry in ipairs(ns:MapEntries()) do
			local groupsShown = {}
			for _, point in ipairs(ns:SpawnPoints(entry.id, entry.npc)) do
				-- Continent and world maps get one pin per zone, not every spawn point.
				if not (zoomedOut and groupsShown[point.group]) then
					local x, y = ns:ProjectPoint(point, mapID)
					if x then
						groupsShown[point.group] = true
						count = count + 1
						local pin = pins[count] or createPin(parent)
						pins[count] = pin
						pin.entry, pin.point, pin.x, pin.y = entry, point, x, y
						stylePin(pin, entry)
						pin:SetFrameLevel(level)
						pin:Show()
					end
				end
			end
		end
	end
	for i = count + 1, #pins do
		pins[i]:Hide()
	end
	shownPins = count
	layoutPins()
end

-- Runs only while the map is shown (a hidden frame's children don't update).
local function watch()
	local map = WorldMapFrame
	local parent = canvas()
	local mapID = map:GetMapID()
	local width, height = parent:GetWidth(), parent:GetHeight()
	local scale = map.GetCanvasScale and map:GetCanvasScale()
	local zoom = map.GetCanvasZoomPercent and map:GetCanvasZoomPercent()
	if view.dirty or mapID ~= view.mapID then
		view.dirty, view.mapID, view.width, view.height, view.scale, view.zoom = nil, mapID, width, height, scale, zoom
		drawPins()
	elseif width ~= view.width or height ~= view.height or scale ~= view.scale or zoom ~= view.zoom then
		view.width, view.height, view.scale, view.zoom = width, height, scale, zoom
		layoutPins()
	end
end

function ns.handlers.GLOBAL_MOUSE_DOWN(button)
	if button ~= "RightButton" then
		pressedPin = mousePin
	end
end

function ns.handlers.GLOBAL_MOUSE_UP(button)
	local pin = pressedPin
	pressedPin = nil
	if not (pin and pin == mousePin and button == "LeftButton" and pin:IsVisible()) then
		return
	end
	if IsShiftKeyDown() then
		ns:SetTracked(pin.entry.id, not ns:IsTracked(pin.entry.id))
	else
		ns:AddWaypoint(pin.entry.id, pin.entry.npc, pin.point)
	end
end

function ns.handlers.PLAYER_REGEN_ENABLED()
	if view.passPending then
		view.passPending = nil
		for _, pin in ipairs(pins) do
			if not pin.passThroughSet then
				passRightButton(pin)
			end
		end
	end
end

function ns:InitMap()
	local parent = canvas()
	if not parent then
		self:Print("Couldn't find the world map canvas; map markers are off.")
		return
	end
	local watcher = frameUnder(parent)
	watcher:SetSize(1, 1)
	watcher:SetPoint("TOPLEFT")
	watcher:SetScript("OnUpdate", function()
		xpcall(watch, geterrorhandler())
	end)
	self.mapWatcher = watcher
end

function ns:RefreshMap()
	view.dirty = true
end

-- Opening the map / waypoints ------------------------------------------

function ns:BestSpawn(npcID, npc)
	local _, point = self:NearestSpawn(npcID, npc)
	return point or self:SpawnPoints(npcID, npc)[1]
end

function ns:ShowOnMap(npcID, npc)
	npc = npc or self.npcs[npcID] or self.trainers[npcID]
	local point = npc and self:BestSpawn(npcID, npc)
	if not point then
		self:Print(format("No map location known for %s (%s).", npc and npc.n or npcID, npc and npc.z or "?"))
		return
	end
	self.char.tracked[npcID] = true
	self:RefreshMap()
	self:RefreshBrowser()
	if not self:OpenWorldMap(point.mapID) then
		local zone = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(point.mapID)
		self:Print(format("Pinned %s on your map: %s %.0f, %.0f.", npc.n, zone and zone.name or npc.z or "", point.x, point.y))
	end
end

-- The client's own C_Map.OpenWorldMap; the Lua openers leave the map tainted so later opens in combat
-- fail. Never in combat, and never with the gamepad interface, whose map close would then be blocked.
function ns:OpenWorldMap(mapID)
	if self:GamepadUI() or InCombatLockdown() or not (C_Map and C_Map.OpenWorldMap) then
		return false
	end
	return pcall(C_Map.OpenWorldMap, mapID) and true or false
end

function ns:GamepadUI()
	if self.gamepadUI == nil then
		local types = Enum and Enum.InputDeviceInterfaceType
		local style = C_InputInterfaceStyle
		self.gamepadUI = types and types.Gamepad and style and style.GetCurrentStyle
			and style.GetCurrentStyle() == types.Gamepad or false
	end
	return self.gamepadUI
end

function ns:AddWaypoint(npcID, npc, point)
	point = point or self:BestSpawn(npcID, npc)
	if not point then
		return
	end
	local x, y = self:ProjectPoint(point, point.mapID)
	if not x then
		x, y = point.x / 100, point.y / 100
	end
	local name = npc.n
	if TomTom and TomTom.AddWaypoint then
		TomTom:AddWaypoint(point.mapID, x, y, { title = name, from = "Turkey Tickle UI: Pets" })
		return
	end
	local zone = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(point.mapID)
	self:Print(format("%s: %s %.1f, %.1f", name, zone and zone.name or npc.z or "", x * 100, y * 100))
end
