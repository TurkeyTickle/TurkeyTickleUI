-- Runs several copies of TurkeyTickleUI_Puzzle against a fake guild channel with the client's
-- addon message throttle, then checks they all end up with the same picture and pieces.
--   luajit tests/harness_puzzle.lua TurkeyTickleUI_Puzzle [image code file] [--legacy OLD_ADDON_DIR]
-- With --legacy, also plays against a copy of an older release (tests/puzzle_compat.sh makes one).
local positional, LEGACY_DIR = {}, nil
do
	local i = 1
	while arg[i] do
		if arg[i] == "--legacy" then
			LEGACY_DIR = arg[i + 1]
			i = i + 1
		else
			positional[#positional + 1] = arg[i]
		end
		i = i + 1
	end
end
local ADDON_DIR = positional[1] or "TurkeyTickleUI_Puzzle"
local EXTRA_CODE_FILE = positional[2]
local function tocFiles(dir)
	local files = {}
	for line in io.lines(dir .. "/TurkeyTickleUI_Puzzle.toc") do
		if line:match("%.lua%s*$") then
			files[#files + 1] = line:gsub("%s+$", "")
		end
	end
	return files
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
local function newClient(name, surname, dir)
	dir = dir or ADDON_DIR
	local client = { name = name, full = surname and (name .. " " .. surname) or name, ns = {}, popups = {}, tokens = {},
		refill = now, frames = {}, textures = {}, printed = {}, sent = {} }
	local env = setmetatable({}, { __index = _G })
	client.env = env
	env.print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[i] = tostring(select(i, ...))
		end
		local line = table.concat(parts, " "):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
		table.insert(client.printed, line)
		print(string.format("     [%s] %s", name, line))
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
	env.StaticPopup_Hide = function(which)
		for _, popup in ipairs(client.popups) do
			if popup.which == which then
				popup.hidden = true
			end
		end
	end
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
	env.C_AddOns = { GetAddOnMetadata = function() return "0.2.0" end }
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
			table.insert(client.sent, { text = text, chatType = chatType, target = target })
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

	for _, file in ipairs(tocFiles(dir)) do
		local chunk = assert(loadfile(dir .. "/" .. file))
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

local function printedSince(client, mark, text)
	for i = mark + 1, #client.printed do
		if client.printed[i]:find(text, 1, true) then
			return true
		end
	end
	return false
end

-- Messages a client sent since `mark` that start with `start` (and, if given, went to `target`).
local function sentSince(client, mark, start, target)
	local found = {}
	for i = mark + 1, #client.sent do
		local m = client.sent[i]
		if m.text:sub(1, #start) == start and (not target or m.target == target) then
			found[#found + 1] = m
		end
	end
	return found
end

local function loadedFor(client, id)
	local session = client.ns.sessions[id]
	return session and session.decoder:IsComplete() and session
end

local function samePieces(a, b)
	for i, piece in ipairs(a.pieces) do
		local other = b.pieces[i]
		if math.abs(piece.x - other.x) > 1e-9 or math.abs(piece.y - other.y) > 1e-9 or (piece.placed or false) ~= (other.placed or false)
			or (piece.turn or 0) ~= (other.turn or 0) then
			return false, string.format("piece %d: %.4f,%.4f %s %d vs %.4f,%.4f %s %d", i, piece.x, piece.y,
				tostring(piece.placed), piece.turn or 0, other.x, other.y, tostring(other.placed), other.turn or 0)
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

local plainMark = #alice.sent
local hostOk, hostErr = alice.ns:HostSession(sample, "Test Picture", 24, "GUILD")
check(hostOk, "Alice hosts a puzzle " .. tostring(hostErr or ""))
local hostSession = sessionOf(alice)
check(hostSession.needs == 1 and #sentSince(alice, plainMark, "S:") == 1 and #sentSince(alice, plainMark, "A:") == 0,
	"a puzzle without turned pieces is set up the way 0.1.0 understands")
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
check(bob.popups[1].hidden, "opening the puzzle closes the ready popup")
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

-- Turned pieces.
local turnMark = #alice.sent
check(alice.ns:HostSession(sample, "Turny", 24, "GUILD", false, true), "Alice hosts a puzzle with turned pieces")
local turnHost = sessionOf(alice)
local turnSetup = sentSince(alice, turnMark, "A:")[1]
check(turnHost.needs == 2 and turnSetup and turnSetup.text:find(":2:0.2.0:0.2.0:", 1, true)
	and #sentSince(alice, turnMark, "S:") == 0, "a puzzle with turned pieces says it needs 0.2.0, and which version the host has")
run(400, function()
	local s = sessionOf(bob)
	return s and s.decoder:IsComplete()
end)
local turnBob = sessionOf(bob)
bob.ns:JoinSession(turnBob)
run(1)
check(turnHost.rotate and turnBob.rotate, "everyone knows the pieces turn")
local turnCounts = { [0] = 0, 0, 0, 0 }
for _, piece in ipairs(turnHost.pieces) do
	turnCounts[piece.turn] = turnCounts[piece.turn] + 1
end
check(turnCounts[0] < #turnHost.pieces and samePieces(turnHost, turnBob),
	string.format("pieces start turned, the same way for everyone (%d/%d/%d/%d)", turnCounts[0], turnCounts[1], turnCounts[2], turnCounts[3]))

local bns = bob.ns
local fw, fh = bns:PieceSize(turnBob, 1, 0)
local tw, th = bns:PieceSize(turnBob, 1, 1)
local pw, ph = bns:PlaySize(turnBob)
check(math.abs(tw * pw - fh * ph) < 1e-9 and math.abs(th * ph - fw * pw) < 1e-9, "a quarter turn swaps a piece's width and height")
local x, y, t = 0.3, 0.3, 0
for _ = 1, 4 do
	x, y = bns:TurnedPosition(turnBob, 1, t, x, y, 0.35, 0.32)
	t = (t + 1) % 4
end
check(math.abs(x - 0.3) < 1e-9 and math.abs(y - 0.3) < 1e-9, "four quarter turns about a point come back where they started")

-- Turning a group about a point moves each member as if it turned alone about that point. Upright
-- offsets come from home positions, which are rounded to the 1/4000 grid positions travel on.
local ta, tb = 7, 8
local groupOk = true
for turn = 0, 3 do
	local ax0, ay0 = 0.3, 0.4
	local ox, oy = bns:GroupOffset(turnBob, ta, tb, turn)
	local ax1, ay1 = bns:TurnedPosition(turnBob, ta, turn, ax0, ay0, 0.33, 0.37)
	local bx1, by1 = bns:TurnedPosition(turnBob, tb, turn, ax0 + ox, ay0 + oy, 0.33, 0.37)
	local nx, ny = bns:GroupOffset(turnBob, ta, tb, (turn + 1) % 4)
	groupOk = groupOk and math.abs(bx1 - ax1 - nx) < 1 / 4000 and math.abs(by1 - ay1 - ny) < 1 / 4000
end
check(groupOk, "a group keeps its shape through every turn")

local hx, hy = bns:HomePosition(turnBob, 2)
check(not bns:IsNearHome(turnBob, 2, hx, hy, 1) and bns:IsNearHome(turnBob, 2, hx, hy, 0),
	"only an upright piece drops into its spot")
bns:MovePiece(turnBob, 3, 0.2, 0.2, "r", 3)
run(1)
check(turnHost.pieces[3].turn == 3 and math.abs(turnHost.pieces[3].x - 0.2) < 1e-3, "the host sees Bob turn a piece")
bns:MovePiece(turnBob, 3, 0.2, 0.2, "r", 0)
run(1)
check(turnHost.pieces[3].turn == 0, "turning a piece upright reaches the host")

-- Neighbors only snap when they're turned the same way.
bns:MovePiece(turnBob, ta, 0.1, 0.1, "r", 2)
local ox, oy = bns:GroupOffset(turnBob, tb, ta, 2)
local nearX, nearY = 0.1 - ox + 0.002, 0.1 - oy
check(not bns:FindSnap(turnBob, tb, nearX, nearY, 1), "neighbors turned different ways don't snap")
local neighbor, sx, sy = bns:FindSnap(turnBob, tb, nearX, nearY, 2)
check(neighbor == ta, "neighbors turned the same way snap")
bns:MovePiece(turnBob, tb, sx, sy, "r", 2)
bns:LinkPieces(turnBob, tb, ta)
run(1)
local hostA, hostB = turnHost.pieces[ta], turnHost.pieces[tb]
local gx, gy = alice.ns:GroupOffset(turnHost, ta, tb, 2)
check(hostA.turn == 2 and hostB.turn == 2 and math.abs(hostB.x - hostA.x - gx) < 1e-3 and math.abs(hostB.y - hostA.y - gy) < 1e-3,
	"the host sees the turned pair snapped together")
alice.ns:MovePiece(turnHost, ta, 0.3, 0.3, "r", 1)
run(1)
local bx, by = bns:GroupOffset(turnBob, ta, tb, 1)
check(turnBob.pieces[tb].turn == 1 and math.abs(turnBob.pieces[tb].x - 0.3 - bx) < 1e-3, "turning one piece turns its whole group")

local dan = newClient("Dan")
login(dan)
run(8)
local turnDan = sessionOf(dan)
run(400, function()
	return turnDan and turnDan.decoder:IsComplete()
end)
dan.ns:JoinSession(turnDan)
run(2)
check(turnDan.rotate and samePieces(turnHost, turnDan), "Dan catches up on how every piece is turned")

-- Eve's guild isn't known yet when she first asks who's hosting, so she asks again later.
local eve = newClient("Eve")
local eveInGuild = false
eve.env.IsInGuild = function() return eveInGuild end
login(eve)
run(8)
check(next(eve.ns.sessions) == nil, "Eve can't ask her guild before the game says she's in it")
eveInGuild = true
run(16)
check(sessionOf(eve) ~= nil, "Eve asks again later and hears about the puzzle in progress")

-- Finn never asked (as if the answer got lost), so he joins by hand.
local finn = newClient("Finn")
finn.online = true
finn.fire("ADDON_LOADED", "TurkeyTickleUI_Puzzle")
check(next(finn.ns.sessions) == nil, "Finn doesn't know about the puzzle yet")
finn.ns:JoinSession(finn.ns:FindSession(""), "")
run(400, function()
	local s = finn.ns.active
	return s and s.decoder:IsComplete()
end)
run(2)
local turnFinn = finn.ns.active
check(turnFinn ~= nil and finn.ns:IsBoardShown() and turnFinn.decoder:IsComplete(),
	"/ttpz join finds the puzzle in progress, opens it and loads the picture")
check(samePieces(turnHost, turnFinn), "Finn catches up on every piece")

-- Versions. 0.1.0 asks who's hosting without saying its version, and can't play turned pieces.
local mark, sentMark = #alice.printed, #alice.sent
alice.fire("CHAT_MSG_ADDON", "TTPuzzle1", "H", "GUILD", "Olaf Old")
run(1)
check(printedSince(alice, mark, "Olaf Old can't join Turny: they have Turkey Tickle UI Puzzle 0.1.0, and this puzzle needs 0.2.0 or newer."),
	"the host hears that a player on 0.1.0 can't join, and what they need")
check(#sentSince(alice, sentMark, "", "Olaf Old") == 0, "the host doesn't send 0.1.0 a puzzle it can't read")
mark = #alice.printed
alice.fire("CHAT_MSG_ADDON", "TTPuzzle1", "V:" .. turnHost.id .. ":1:0.1.0", "WHISPER", "Olaf Old")
run(12)
alice.fire("CHAT_MSG_ADDON", "TTPuzzle1", "H", "GUILD", "Olaf Old")
run(1)
check(not printedSince(alice, mark, "Olaf"), "the host only hears about each player once")

-- 0.1.0 joining mid-picture asks for it from the top; that only gets it the setup, which it ignores.
sentMark = #alice.sent
alice.fire("CHAT_MSG_ADDON", "TTPuzzle2", "Q:" .. turnHost.id .. ":0:1", "WHISPER", "Olaf Old")
run(1)
check(#sentSince(alice, sentMark, "A:", "Olaf Old") == 1 and #sentSince(alice, sentMark, "D:") == 0
	and #sentSince(alice, sentMark, "P:") == 0, "an addon too old for the puzzle doesn't make the host resend the picture")

-- A newer host's puzzle that needs a protocol we don't have.
mark, sentMark = #bob.printed, #bob.sent
local future = "A:zzzz:9:0.9.0:0.9.3:G:5:5:10:123:grx:Future: the sequel"
bob.fire("CHAT_MSG_ADDON", "TTPuzzle2", future, "GUILD", "Zed Zeta")
run(1)
check(bob.ns.sessions.zzzz == nil and bob.ns.blocked.zzzz ~= nil, "a puzzle that needs a newer addon isn't opened")
local blockedText = "Zed Zeta's puzzle Future: the sequel needs Turkey Tickle UI Puzzle 0.9.0 or newer. Zed Zeta has 0.9.3 and you have "
	.. "0.2.0: update to join."
check(printedSince(bob, mark, blockedText), "the player hears which version the host has, which they have, and what to update to")
local told = sentSince(bob, sentMark, "V:zzzz:2:0.2.0", "Zed Zeta")
check(#told == 1 and told[1].chatType == "WHISPER", "the host is told the player's version")
mark = #bob.printed
bob.fire("CHAT_MSG_ADDON", "TTPuzzle2", future, "WHISPER", "Zed Zeta")
run(1)
check(not printedSince(bob, mark, "Zed Zeta's puzzle"), "hearing about it again doesn't repeat the message")
bob.ns:PrintStatus()
check(printedSince(bob, mark, blockedText), "/ttpz status repeats it")
mark = #bob.printed
bob.ns:JoinSession(nil, "zed zeta")
run(1)
bob.fire("CHAT_MSG_ADDON", "TTPuzzle2", future, "WHISPER", "Zed Zeta")
run(8)
check(printedSince(bob, mark, blockedText) and not printedSince(bob, mark, "No puzzles found"),
	"/ttpz join zed zeta explains why it can't join instead of finding nothing")
bob.fire("CHAT_MSG_ADDON", "TTPuzzle2", "E:zzzz", "GUILD", "Zed Zeta")
check(bob.ns.blocked.zzzz == nil, "the message goes away when the host ends that puzzle")
mark = #bob.printed
bob.fire("CHAT_MSG_ADDON", "TTPuzzle3", "M:" .. turnBob.id .. ":9:9999:400:400:r:1:newfield:more", "GUILD", "Zed Zeta")
check(turnBob.pieces[9].seq == 9999 and turnBob.pieces[9].turn == 1, "fields a newer addon adds to the end of a message are ignored")

for i, piece in ipairs(turnBob.pieces) do
	if not piece.placed then
		local px, py = bns:HomePosition(turnBob, i)
		bns:MovePiece(turnBob, i, px, py, "p")
	end
end
run(30, function()
	return alice.ns:IsComplete(turnHost) and dan.ns:IsComplete(turnDan)
end)
local upright = true
for _, piece in ipairs(turnHost.pieces) do
	upright = upright and piece.turn == 0
end
check(alice.ns:IsComplete(turnHost) and upright, "placed pieces end up upright")

alice.ns:ShowHost()
local hostDialog = alice.env.TurkeyTickleUIPuzzleHost
hostDialog.pasted = sample
hostDialog.name:SetText("Again")
hostDialog.start._scripts.OnClick()
check(alice.ns.active ~= turnHost and alice.ns.active.title == "Again", "hosting from the host window starts the new puzzle")
run(1)
bob.ns:LeaveSession()
bob.ns:Toggle()
local bobList = bob.env.TurkeyTickleUIPuzzleHost
local firstRow = bobList.rows[1]
check(bobList:IsShown() and bobList.listView:IsShown() and not bobList.hostView:IsShown(),
	"opening the puzzle outside one shows the list of puzzles")
check(firstRow:IsShown() and firstRow.session and firstRow.session.title == "Again" and firstRow.join:GetText() == "Join",
	"the list shows the newest puzzle in the guild first, with a join button")
firstRow.join._scripts.OnClick()
check(bob.ns.active == firstRow.session and bob.ns:IsBoardShown() and not bobList:IsShown(),
	"joining from the list opens the puzzle")
bob.ns:LeaveSession()
bob.ns:ShowPuzzles()
bobList.listView._scripts.OnUpdate(bobList.listView, 1)
check(firstRow:IsShown() and firstRow.join:GetText() == "Join", "the list refreshes itself while it's open")
bob.ns:ShowHost()
check(bobList.hostView:IsShown() and not bobList.listView:IsShown(), "the host button shows the host form")
bobList:Hide()
alice.ns:ShowHost()
check(hostDialog.pasted == "" and hostDialog.name:GetText() == "",
	"the host window forgets the last picture once it's started, so it can't be hosted again by accident")
alice.ns:EndSession()
run(2)

-- Hosting for a party outside one asks first, then starts a puzzle just for the host.
alice.ns.db.channel = "GROUP"
alice.ns:ShowHost()
hostDialog.pasted = sample
hostDialog.name:SetText("Solo")
hostDialog.start._scripts.OnClick()
check(alice.popups[#alice.popups].which == "TURKEYTICKLEUI_PUZZLE_ALONE" and hostDialog:IsShown() and alice.ns.active == nil,
	"hosting for a party outside one asks whether to puzzle alone")
local soloMark = #alice.sent
alice.env.StaticPopupDialogs.TURKEYTICKLEUI_PUZZLE_ALONE.OnAccept()
local solo = alice.ns.active
check(solo and solo.title == "Solo" and solo.channel == "P" and alice.ns:IsBoardShown() and not hostDialog:IsShown(),
	"puzzling alone starts the puzzle and opens the board")
run(5)
local soloSent = 0
for i = soloMark + 1, #alice.sent do
	soloSent = soloSent + (alice.sent[i].text:find(solo.id, 1, true) and 1 or 0)
end
check(soloSent == 0, "a puzzle alone sends nothing")
alice.env.IsInGroup = function() return true end
bob.env.IsInGroup = function() return true end
bob.fire("GROUP_JOINED")
run(400, function()
	return loadedFor(bob, solo.id)
end)
check(loadedFor(bob, solo.id), "someone who joins the party later hears about the puzzle and loads it")
alice.ns:EndSession()
alice.env.IsInGroup = function() return false end
bob.env.IsInGroup = function() return false end
alice.ns.db.channel = "GUILD"
run(2)

-- An older release in the same guild ----------------------------------------------

if LEGACY_DIR then
	for _, client in ipairs(clients) do
		client.online = client == alice or client == bob
	end
	local olga = newClient("Olga", "Old", LEGACY_DIR)
	local oldProtocol = olga.ns.PROTOCOL or 1
	print(string.format("-- against %s (protocol %d)", LEGACY_DIR, oldProtocol))
	login(olga)
	run(8)

	-- A puzzle everyone can play, from a new host.
	check(alice.ns:HostSession(sample, "Shared", 24, "GUILD"), "Alice hosts a puzzle without turned pieces")
	local shared = alice.ns.active
	run(400, function()
		return loadedFor(olga, shared.id) and loadedFor(bob, shared.id)
	end)
	local oldShared, bobShared = loadedFor(olga, shared.id), loadedFor(bob, shared.id)
	check(oldShared and bobShared, "the older addon loads a new host's puzzle")
	olga.ns:JoinSession(oldShared)
	bob.ns:JoinSession(bobShared)
	run(1)
	check(samePieces(shared, oldShared), "the older addon starts with the same pieces")
	olga.ns:MovePiece(oldShared, 1, 0.1, 0.2, "r")
	local hx, hy = alice.ns:HomePosition(shared, 2)
	alice.ns:MovePiece(shared, 2, hx, hy, "p")
	run(1)
	check(math.abs(shared.pieces[1].x - 0.1) < 1e-3 and math.abs(bobShared.pieces[1].x - 0.1) < 1e-3,
		"new addons see the older addon's moves")
	check(oldShared.pieces[2].placed, "the older addon sees the host place a piece")

	local oscar = newClient("Oscar", "Old", LEGACY_DIR)
	login(oscar)
	run(400, function()
		return loadedFor(oscar, shared.id)
	end)
	run(2)
	local oscarShared = loadedFor(oscar, shared.id)
	check(oscarShared and samePieces(shared, oscarShared), "an older addon logging in late catches up from a new host")
	oscar.online = false
	alice.ns:EndSession()
	run(2)
	check(olga.ns.sessions[shared.id] == nil, "the older addon sees the new host end the puzzle")

	-- A puzzle hosted by the older addon.
	check(olga.ns:HostSession(sample, "Old host", 24, "GUILD"), "the older addon hosts a puzzle")
	local oldHosted = olga.ns.active
	run(400, function()
		return loadedFor(bob, oldHosted.id)
	end)
	local bobOld = loadedFor(bob, oldHosted.id)
	check(bobOld and not bobOld.rotate, "a new addon loads the older addon's puzzle")
	bob.ns:JoinSession(bobOld)
	run(1)
	bob.ns:MovePiece(bobOld, 3, 0.3, 0.3, "r")
	hx, hy = bob.ns:HomePosition(bobOld, 4)
	bob.ns:MovePiece(bobOld, 4, hx, hy, "p")
	olga.ns:MovePiece(oldHosted, 5, 0.6, 0.1, "r")
	run(1)
	check(samePieces(oldHosted, bobOld) and oldHosted.pieces[4].placed, "moves go both ways with an older host")
	olga.ns:EndSession()
	run(2)

	-- Turned pieces need protocol 2.
	local sentMark, mark = #alice.sent, #alice.printed
	check(alice.ns:HostSession(sample, "Turny again", 24, "GUILD", false, true), "Alice hosts a puzzle with turned pieces")
	local turny = alice.ns.active
	run(400, function()
		return loadedFor(bob, turny.id) and (oldProtocol < 2 or loadedFor(olga, turny.id))
	end)
	if oldProtocol >= 2 then
		local oldTurny = loadedFor(olga, turny.id)
		olga.ns:JoinSession(oldTurny)
		run(2)
		check(oldTurny and oldTurny.rotate and samePieces(turny, oldTurny), "the older addon plays turned pieces")
	else
		check(olga.ns.sessions[turny.id] == nil, "the older addon doesn't open a puzzle it can't play")
		check(#sentSince(olga, 0, "Q:" .. turny.id) > 0 and #sentSince(alice, sentMark, "D:" .. turny.id) == turny.chunkCount,
			"the picture goes out once, even when an older addon that heard part of it asks for the rest")
		olga.ns:Send("H", "GUILD")
		run(1)
		check(printedSince(alice, mark, "Olga Old can't join Turny again: they have Turkey Tickle UI Puzzle 0.1.0"),
			"the host hears that the older addon can't join")
	end
	alice.ns:EndSession()
	run(2)
end

-- Many cuts. Knobs pushed into one piece near a corner can overlap; the smaller is cut around the
-- bigger, so every cut still covers the picture exactly once.
local quiet = alice.env.print
alice.env.print = function() end
local cuts, rivals, badCut = 0, 0, nil
for round = 1, 15 do
	for _, count in ipairs({ 24, 48, 100 }) do
		alice.ns:HostSession(sample, "Cut " .. round, count, "GUILD")
		local s = alice.ns.active
		cuts = cuts + 1
		for _, shape in ipairs(s.shapes) do
			for _, k in ipairs(shape.knobs) do
				rivals = rivals + #k.rivals
			end
		end
		for y = 0.5, s.decoder.h, 1 do
			for x = 0.5, s.decoder.w, 1 do
				local covering = 0
				for i = 1, #s.pieces do
					if alice.ns:PieceContains(s, i, x, y) then
						covering = covering + 1
					end
				end
				if covering ~= 1 and not badCut then
					badCut = string.format("%d pieces, seed %d: (%.1f, %.1f) is in %d pieces", #s.pieces, s.seed, x, y, covering)
				end
			end
		end
	end
end
alice.ns:EndSession()
alice.env.print = quiet
check(rivals > 0, string.format("some cuts have knobs that would overlap (%d in %d cuts)", rivals, cuts))
check(not badCut, "every cut covers the picture exactly once" .. (badCut and (": " .. badCut) or ""))

check(#errors == 0, "no Lua errors")
print("done")
