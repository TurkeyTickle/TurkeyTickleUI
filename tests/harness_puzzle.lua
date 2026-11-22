-- Runs several copies of TurkeyTickleUI_Puzzle against a fake guild channel with the client's
-- addon message throttle, then checks they all end up with the same picture and pieces.
--   luajit tests/harness_puzzle.lua TurkeyTickleUI_Puzzle [image code file]
local ADDON_DIR = arg[1] or "TurkeyTickleUI_Puzzle"
local EXTRA_CODE_FILE = arg[2]
local FILES = {}
for line in io.lines(ADDON_DIR .. "/TurkeyTickleUI_Puzzle.toc") do
	if line:match("%.lua%s*$") then
		FILES[#FILES + 1] = line:gsub("%s+$", "")
	end
end
local LATENCY = 0.1
local STEP = 0.05

local now = 0
local timers = {}
local deliveries = {}
local clients = {}
local errors = {}
local stats = { sent = 0, throttled = 0, bytes = 0 }

local function check(condition, message)
	if not condition then
		error("FAILED: " .. message, 2)
	end
	print("ok   " .. message)
end

local function schedule(delay, fn, interval)
	local timer = { at = now + delay, fn = fn, interval = interval }
	timer.Cancel = function() timer.cancelled = true end
	table.insert(timers, timer)
	return timer
end

-- Widgets: just enough state for the addon's own bookkeeping.
local makeWidget
local methods = {
	Show = function(self) self._shown = true end,
	Hide = function(self) self._shown = false; local f = self._scripts.OnHide; if f then f(self) end end,
	IsShown = function(self) return self._shown end,
	IsVisible = function(self) return self._shown and (not self._parent or self._parent:IsVisible()) end,
	SetShown = function(self, shown) if shown then self:Show() else self:Hide() end end,
	SetScript = function(self, k, fn) self._scripts[k] = fn end,
	GetScript = function(self, k) return self._scripts[k] or function() end end,
	HookScript = function(self, k, fn) self._scripts[k] = fn end,
	SetText = function(self, text) self._text = text end,
	SetFormattedText = function(self, fmt, ...) self._text = string.format(fmt, ...) end,
	GetText = function(self) return self._text end,
	GetFrameLevel = function(self) return self._level end,
	SetFrameLevel = function(self, level) self._level = level end,
	GetEffectiveScale = function() return 1 end,
	GetLeft = function() return 0 end,
	GetTop = function() return 0 end,
	GetChecked = function() return false end,
	GetID = function() return 1 end,
	GetWidth = function() return 140 end,
	GetCenter = function() return 0, 0 end,
	CreateAnimationGroup = function() return makeWidget() end,
	CreateAnimation = function() return makeWidget() end,
	CreateTexture = function(self)
		local tex = makeWidget(self)
		if self._client then
			table.insert(self._client.textures, tex)
		end
		return tex
	end,
	CreateMaskTexture = function(self)
		local mask = makeWidget(self)
		if self._client then
			table.insert(self._client.textures, mask)
		end
		return mask
	end,
	AddMaskTexture = function(self, mask)
		self._masks = self._masks or {}
		assert(#self._masks < 3, "Texture:AddMaskTexture(): Texture already has the maximum number of mask textures (3)")
		table.insert(self._masks, mask)
	end,
	RemoveMaskTexture = function(self, mask)
		for k, m in ipairs(self._masks or {}) do
			if m == mask then
				table.remove(self._masks, k)
				return
			end
		end
	end,
	CreateFontString = function() return makeWidget() end,
}
makeWidget = function(parent, client)
	client = client or parent and parent._client
	return setmetatable({ _shown = true, _scripts = {}, _text = "", _level = 1, _parent = parent, _client = client }, {
		__index = function(_, k)
			if k:match("^%u") then
				return methods[k] or function() end
			end
		end,
	})
end

-- Forever names: UnitName is the first name, UnitFullName returns the surname (or the realm
-- when there isn't one), and same-realm addon messages come from "First Last".
local REALM = "Realm1"
local function newClient(name, surname)
	local client = { name = name, full = surname and (name .. " " .. surname) or name, ns = {}, popups = {}, tokens = {}, refill = now, frames = {}, textures = {} }
	local env = setmetatable({}, { __index = _G })
	client.env = env
	env.print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[i] = tostring(select(i, ...))
		end
		print(string.format("     [%s] %s", name, table.concat(parts, " "):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")))
	end
	env.CreateFrame = function(_, frameName, parent)
		local frame = makeWidget(parent, client)
		table.insert(client.frames, frame)
		if frameName then
			env[frameName] = frame
		end
		return frame
	end
	env.Minimap = makeWidget(nil, client)
	env.UIParent = makeWidget(nil, client)
	env.CreateColor = function(r, g, b, a)
		return { r = r, g = g, b = b, a = a, SetRGB = function(c, nr, ng, nb) c.r, c.g, c.b = nr, ng, nb end }
	end
	env.unpack = unpack
	env.UISpecialFrames = {}
	env.SlashCmdList = {}
	env.StaticPopupDialogs = {}
	env.StaticPopup_Show = function(which, a, b, data) table.insert(client.popups, { which = which, data = data }) end
	env.GameTooltip = makeWidget()
	env.GameTooltip_Hide = function() end
	env.SOUNDKIT = { IG_ABILITY_ICON_DROP = 1, LEVELUP = 2 }
	env.PlaySound = function(id) client.sounds = (client.sounds or 0) + 1 end
	env.Settings = {
		RegisterCanvasLayoutCategory = function() return makeWidget() end,
		RegisterCanvasLayoutSubcategory = function() return makeWidget() end,
		RegisterAddOnCategory = function() end,
		OpenToCategory = function() end,
	}
	env.C_AddOns = { GetAddOnMetadata = function() return "0.1.0" end }
	env.C_Timer = {
		After = function(delay, fn) schedule(delay, fn) end,
		NewTicker = function(interval, fn) return schedule(interval, fn, interval) end,
	}
	env.GetTime = function() return now end
	env.GetCursorPosition = function() return 0, 0 end
	env.UnitName = function() return name end
	env.UnitFullName = function() return name, surname or REALM end
	env.GetNormalizedRealmName = function() return REALM end
	env.IsInGuild = function() return true end
	env.IsInGroup = function() return false end
	env.IsInRaid = function() return false end
	env.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
	env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	env.tinsert = table.insert
	env.tContains = function(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end
	env.format = string.format
	env.geterrorhandler = function()
		return function(e)
			table.insert(errors, name .. ": " .. tostring(e))
			print(debug.traceback(tostring(e)))
		end
	end
	env.C_ChatInfo = {
		RegisterAddonMessagePrefix = function(prefix) client.tokens[prefix] = 10 end,
		SendAddonMessage = function(prefix, text, chatType, target)
			assert(client.tokens[prefix], "unregistered prefix " .. prefix)
			assert(#text <= 255, "message too long: " .. #text)
			for p, t in pairs(client.tokens) do
				client.tokens[p] = math.min(10, t + (now - client.refill))
			end
			client.refill = now
			if client.tokens[prefix] < 1 then
				stats.throttled = stats.throttled + 1
				return 3
			end
			client.tokens[prefix] = client.tokens[prefix] - 1
			stats.sent = stats.sent + 1
			stats.bytes = stats.bytes + #text
			for _, other in ipairs(clients) do
				local whisper = chatType == "WHISPER"
				if other.online and (not whisper or other.full == target or other.full .. "-" .. REALM == target) then
					table.insert(deliveries, { at = now + LATENCY, to = other, args = { prefix, text, chatType, client.full } })
				end
			end
			return 0
		end,
	}

	for _, file in ipairs(FILES) do
		local chunk = assert(loadfile(ADDON_DIR .. "/" .. file))
		setfenv(chunk, env)
		chunk("TurkeyTickleUI_Puzzle", client.ns)
	end
	client.fire = function(event, ...)
		client.ns.driver._scripts.OnEvent(client.ns.driver, event, ...)
	end
	table.insert(clients, client)
	return client
end

local function login(client)
	client.online = true
	client.fire("ADDON_LOADED", "TurkeyTickleUI_Puzzle")
	client.fire("PLAYER_ENTERING_WORLD", true, false)
end

local function run(seconds, untilFn)
	local stop = now + seconds
	while now < stop do
		now = now + STEP
		local pending = {}
		local ready = {}
		for _, d in ipairs(deliveries) do
			table.insert(d.at <= now and ready or pending, d)
		end
		deliveries = pending
		for _, d in ipairs(ready) do
			if d.to.online then
				d.to.fire("CHAT_MSG_ADDON", unpack(d.args))
			end
		end
		local snapshot = {}
		for i, t in ipairs(timers) do snapshot[i] = t end
		for _, t in ipairs(snapshot) do
			if not t.cancelled and t.at <= now then
				if t.interval then t.at = t.at + t.interval else t.cancelled = true end
				t.fn()
			end
		end
		for i = #timers, 1, -1 do
			if timers[i].cancelled then table.remove(timers, i) end
		end
		for _, client in ipairs(clients) do
			for _, frame in ipairs(client.frames) do
				local onUpdate = frame._scripts.OnUpdate
				if onUpdate and frame:IsVisible() then
					onUpdate(frame, STEP)
				end
			end
		end
		if untilFn and untilFn() then
			return true
		end
	end
	return false
end

local function visibleTextures(client)
	local n = 0
	for _, tex in ipairs(client.textures) do
		if tex:IsVisible() then
			n = n + 1
		end
	end
	return n
end

local function sessionOf(client)
	local _, session = next(client.ns.sessions)
	return session
end

local function samePieces(a, b)
	for i, piece in ipairs(a.pieces) do
		local other = b.pieces[i]
		if math.abs(piece.x - other.x) > 1e-9 or math.abs(piece.y - other.y) > 1e-9 or (piece.placed or false) ~= (other.placed or false) then
			return false, string.format("piece %d: %.4f,%.4f %s vs %.4f,%.4f %s", i, piece.x, piece.y,
				tostring(piece.placed), other.x, other.y, tostring(other.placed))
		end
	end
	return true
end

-- Codec ---------------------------------------------------------------------------

local alice = newClient("Alice", "Smith")
local ns = alice.ns
local sample = ns:SampleCode()
local decoder = ns:NewDecoder()
check(decoder:Feed(sample) and decoder:IsComplete(), "sample picture decodes (" .. #sample .. " chars)")
check(decoder.w == 128 and decoder.h == 96, "sample picture is 128x96")
local reencoded = {}
for idx = 0, decoder.w * decoder.h - 1 do
	reencoded[idx] = decoder.pixels[idx]
end
local palette = {}
for i = 0, decoder.colors - 1 do
	local c = decoder.palette[i]
	palette[i + 1] = { math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5) }
end
check(ns:EncodeImage(decoder.w, decoder.h, palette, reencoded) == sample, "decode then encode round-trips exactly")

local partial = ns:NewDecoder()
local levels = {}
for i = 1, #sample, 50 do
	assert(partial:Feed(sample:sub(i, i + 49)))
	levels[partial.level] = levels[partial.level] or i
end
check(levels[1] and levels[2] and levels[3] and levels[1] < levels[2] and levels[2] < levels[3],
	string.format("picture sharpens in stages (blurry after %d chars, medium %d, full %d)", levels[1], levels[2], levels[3]))
check(not ns:NewDecoder():Feed("TTPZ1:junk!!"), "rejects a damaged code")

if EXTRA_CODE_FILE then
	local f = assert(io.open(EXTRA_CODE_FILE))
	local code = f:read("*a"):gsub("%s", "")
	f:close()
	local d = ns:NewDecoder()
	local ok, err = d:Feed(code)
	check(ok and d:IsComplete(), string.format("tool code decodes: %dx%d, %d colors, %d chars %s", d.w or 0, d.h or 0,
		d.colors or 0, #code, err or ""))
	sample = code
end

-- Multiplayer ---------------------------------------------------------------------

local bob = newClient("Bob", "Jones")
local cara = newClient("Cara")
login(alice)
login(bob)
run(6)

local hostOk, hostErr = alice.ns:HostSession(sample, "Test Picture", 24, "GUILD")
check(hostOk, "Alice hosts a puzzle " .. tostring(hostErr or ""))
local hostSession = sessionOf(alice)
check(alice.ns.active == hostSession and alice.ns:IsBoardShown(), "host joins and sees the board")

run(1)
local function countPlayers(session)
	local n = 0
	for _ in pairs(session.players) do n = n + 1 end
	return n
end
check(countPlayers(hostSession) == 1, "a host alone counts as one puzzler")
alice.ns:MovePiece(hostSession, 4, 0.05, 0.05, "d")
run(1)
check(not alice.ns:IsHeldByOther(hostSession.pieces[4]), "your own moves never look held by someone else")
alice.ns:MovePiece(hostSession, 4, 0.05, 0.05, "r")
run(1)
local bobSession = sessionOf(bob)
local bobButton = bob.env.TurkeyTickleUIPuzzleMinimapButton
check(bobSession ~= nil and #bob.popups == 0, "Bob hears about the puzzle without a popup while it loads")

local started = now
local reached = {}
run(400, function()
	local level = bobSession.decoder.level
	if level > 0 and not reached[level] then
		reached[level] = now - started
	end
	if not reached.label and bobButton.label._text:match("%%") then
		reached.label = bobButton.label._text
	end
	return bobSession.decoder:IsComplete()
end)
check(reached.label ~= nil and bobButton.glow._shown, "Bob's minimap button glows and counts up while loading (" .. tostring(reached.label) .. ")")
check(#bob.popups == 1 and bobButton.label._text:match("Ready"), "Bob gets a ready popup and a Ready button once it's loaded")
bob.ns:JoinSession(bob.popups[1].data)
check(bobButton.label._text == "" and not bobButton.glow._shown, "the button calms down once Bob opens the puzzle")
check(bobSession.decoder:IsComplete(), string.format("Bob receives the whole picture (preview %.1fs, medium %.1fs, full %.1fs)",
	reached[1] or -1, reached[2] or -1, reached[3] or -1))
local identical = true
for idx = 0, hostSession.decoder.w * hostSession.decoder.h - 1 do
	if bobSession.decoder.pixels[idx] ~= hostSession.decoder.pixels[idx] then
		identical = false
	end
end
check(identical, "Bob's picture matches the host's")
local hostTextures, bobTextures = visibleTextures(alice), visibleTextures(bob)
check(hostTextures > 100 and hostTextures <= 8200 and bobTextures <= 8200,
	string.format("boards stay inside WoW's texture limit (host %d, Bob %d textures)", hostTextures, bobTextures))
check(samePieces(hostSession, bobSession), "pieces start in the same places for everyone")
local function describeShape(s)
	local parts = { string.format("%d,%d,%d,%d", s.x0, s.y0, s.x1, s.y1) }
	for _, k in ipairs(s.knobs) do
		parts[#parts + 1] = string.format("k%.6f,%.6f,%.6f,%d,%d", k.cx, k.cy, k.r, k.dx, k.dy)
	end
	for _, hole in ipairs(s.holes) do
		parts[#parts + 1] = string.format("h%.6f,%.6f,%.6f", hole.cx, hole.cy, hole.r)
	end
	return table.concat(parts, " ")
end
local sameShapes, shaped = true, 0
for i = 1, #hostSession.pieces do
	local s = hostSession.shapes[i]
	if describeShape(s) ~= describeShape(bobSession.shapes[i]) then
		sameShapes = false
	end
	shaped = shaped + ((#s.knobs + #s.holes > 0) and 1 or 0)
end
check(sameShapes, "everyone cuts the same jigsaw shapes")
check(shaped == #hostSession.pieces, "every piece has knobs or holes, none are plain rectangles")
local tiles, bounded = true, true
local w, h = hostSession.decoder.w, hostSession.decoder.h
for y = 0.25, h, 0.5 do
	for x = 0.25, w, 0.5 do
		local covering = 0
		for i = 1, #hostSession.pieces do
			if alice.ns:PieceContains(hostSession, i, x, y) then
				covering = covering + 1
				local x0, y0, x1, y1 = alice.ns:PieceRect(hostSession, i)
				bounded = bounded and x >= x0 and x < x1 and y >= y0 and y < y1
			end
		end
		tiles = tiles and covering == 1
	end
end
check(tiles, "the pieces cover the picture exactly once")
check(bounded, "every piece stays inside its frame")
print(string.format("     %d messages sent, %d throttled and retried", stats.sent, stats.throttled))

bob.ns:MovePiece(bobSession, 1, 0.1, 0.2, "d")
run(0.5)
check(hostSession.pieces[1].holder == bob.full, "host sees Bob holding piece 1")
bob.ns:MovePiece(bobSession, 1, 0.15, 0.25, "d")
bob.ns:MovePiece(bobSession, 1, 0.3, 0.4, "r")
run(1)
check(math.abs(hostSession.pieces[1].x - 0.3) < 1e-3 and hostSession.pieces[1].holder == nil, "host sees where Bob dropped piece 1")

local hx, hy = alice.ns:HomePosition(hostSession, 2)
check(alice.ns:IsNearHome(hostSession, 2, hx + 0.002, hy), "a piece near its spot counts as placed")
alice.ns:MovePiece(hostSession, 2, hx, hy, "p")
run(1)
check(bobSession.pieces[2].placed, "Bob sees the host place piece 2")

alice.ns:MovePiece(hostSession, 3, 0.5, 0.5, "d")
bob.ns:MovePiece(bobSession, 3, 0.6, 0.6, "d")
run(1)
check(hostSession.pieces[3].holder == alice.full and bobSession.pieces[3].holder == alice.full,
	"a grab at the same moment goes to the same player on both screens")
alice.ns:MovePiece(hostSession, 3, 0.5, 0.5, "r")
run(1)

-- Bob snaps piece b onto piece a, then the host moves them as one.
local ga, gb = 5, 6
check((ga - 1) % hostSession.cols < hostSession.cols - 1, "test pieces are side by side")
local function offsetOk(session, x, y)
	local ax, ay = alice.ns:HomePosition(session, ga)
	local bx, by = alice.ns:HomePosition(session, gb)
	local a, b = session.pieces[ga], session.pieces[gb]
	return math.abs(a.x - x) < 1e-3 and math.abs(a.y - y) < 1e-3
		and math.abs(b.x - a.x - (bx - ax)) < 1e-3 and math.abs(b.y - a.y - (by - ay)) < 1e-3
end
bob.ns:MovePiece(bobSession, ga, 0.1, 0.1, "r")
local ax, ay = bob.ns:HomePosition(bobSession, ga)
local bx, by = bob.ns:HomePosition(bobSession, gb)
local nearX, nearY = 0.1 + bx - ax + 0.002, 0.1 + by - ay
local neighbor, sx, sy = bob.ns:FindSnap(bobSession, gb, nearX, nearY)
check(neighbor == ga, "a piece dropped next to its neighbor finds it")
check(not bob.ns:FindSnap(bobSession, gb, nearX + 0.2, nearY), "a piece dropped far away doesn't snap")
bob.ns:MovePiece(bobSession, gb, sx, sy, "r")
bob.ns:LinkPieces(bobSession, gb, ga)
run(1)
check(#alice.ns:GroupMembers(hostSession, ga) == 2 and offsetOk(hostSession, 0.1, 0.1),
	"host sees Bob's two pieces snapped together")
alice.ns:MovePiece(hostSession, gb, 0.4, 0.5, "r")
run(1)
check(offsetOk(bobSession, 0.4 - (bx - ax), 0.5 - (by - ay)), "moving one piece of a group moves the whole group")

check(not hostSession.ghost and not bobSession.ghost, "the picture under the pieces is off by default")
bob.ns:SetGhost(bobSession, true)
run(1)
check(not hostSession.ghost and not bobSession.ghost, "only the host can turn on the picture under the pieces")
alice.ns:SetGhost(hostSession, true)
run(1)
check(hostSession.ghost and bobSession.ghost, "the host turns the picture under the pieces on for everyone")

-- Cara logs in late and catches up.
login(cara)
run(8)
local caraSession = sessionOf(cara)
check(caraSession ~= nil, "Cara hears about the puzzle after logging in")
run(400, function()
	return caraSession.decoder:IsComplete()
end)
run(1)
check(caraSession.decoder:IsComplete() and #cara.popups == 1, "Cara loads the picture before opening it and gets a ready popup")
cara.ns:JoinSession(caraSession)
run(1)
check(samePieces(hostSession, caraSession), "Cara's pieces match the host's")
check(caraSession.ghost, "Cara gets the host's picture setting")
check(#cara.ns:GroupMembers(caraSession, gb) == 2, "Cara catches up on which pieces are snapped together")

local hx, hy = bob.ns:HomePosition(bobSession, gb)
bob.ns:MovePiece(bobSession, gb, hx, hy, "p")
run(1)
check(hostSession.pieces[ga].placed and caraSession.pieces[ga].placed, "placing a group places every piece in it")

for i, piece in ipairs(bobSession.pieces) do
	if not piece.placed then
		local x, y = bob.ns:HomePosition(bobSession, i)
		bob.ns:MovePiece(bobSession, i, x, y, "p")
	end
end
run(30, function()
	return alice.ns:IsComplete(hostSession) and cara.ns:IsComplete(caraSession)
end)
check(alice.ns:IsComplete(hostSession) and bob.ns:IsComplete(bobSession) and cara.ns:IsComplete(caraSession),
	"everyone sees the puzzle finished")
check(hostSession.placedBy["Bob Jones"] == #hostSession.pieces - 1 and hostSession.placedBy["Alice Smith"] == 1, "credit goes to whoever placed each piece")

alice.ns:EndSession()
run(2)
check(next(bob.ns.sessions) == nil and next(cara.ns.sessions) == nil, "ending the puzzle closes it for everyone")

check(#errors == 0, "no Lua errors")
print("done")
