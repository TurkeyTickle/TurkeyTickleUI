local ADDON, ns = ...

-- Messages (fields split on ":"; the last field of S, A and D may contain anything but "|"):
--   S:id:channel:cols:rows:chunks:seed:ghost:title   a puzzle anyone can play (channel G = guild, P = group)
--   A:id:needs:release:version:channel:cols:rows:chunks:seed:flags:title
--                                              a puzzle that needs protocol `needs`, first spoken by addon
--                                              `release`; the host has addon `version`. Flags: g = the
--                                              picture under the pieces is on, r = pieces turn
--   G:id:ghost                                 the host turned the picture under the pieces on (1) or off (0)
--   D:id:index:text                            a chunk of the image code
--   M:id:piece:seq:x:y:state[:turn]            a piece and its group moved (d = held, r = let go, p = placed),
--                                              turned 1-3 quarters clockwise (left off when upright)
--   L:id:a:b                                   pieces a and b were snapped together, joining their groups
--   J:id                                       someone opened the puzzle
--   Q:id:have:snapshot[:protocol]              whisper to the host: send me chunks after `have`
--   P:id:first:pieces                          piece positions for someone catching up
--   H[:protocol:version]                       anyone hosting? (sent after logging in)
--   V:id:protocol:version                      whisper to the host: my addon is too old for this puzzle
--   E:id                                       the host ended the puzzle
-- Positions are fractions of the play area, sent as 0-4000, of a piece's top left corner as turned.
-- Every move bumps the piece's seq; the higher seq wins, and on a tie the alphabetically first
-- player wins.
--
-- Compatibility. A protocol is a set of messages; each one adds what older addons can't follow. A
-- puzzle needs the oldest protocol with every feature it uses, so anyone at that protocol or newer
-- can play it, whatever their version. Puzzles that need protocol 1 must only send what 0.1.0
-- understands: S to set up, Q, H and the rest with nothing appended. Puzzles that need more set up
-- with A, which 0.1.0 ignores. A's fields never change (new settings go in its flags), so an addon
-- too old to play can still tell its player what to update to. Every message bar S, A and D can
-- grow new fields at the end, which older addons ignore. Anything an older addon would get wrong
-- needs a new protocol: add its first release to PROTOCOL_RELEASES and raise puzzleNeeds.

local COORD = 4000
local SNAPSHOT_TURNS = "fghi" -- a loose piece's state in a snapshot, by turn; placed pieces are "p"
ns.MARGIN_X = 0.6 -- play area margins, in picture widths / heights
ns.MARGIN_Y = 0.35
local HOLD_TIMEOUT = 15
local STALL_SECONDS = 6
local ASK_COOLDOWN = 8
local ANSWER_COOLDOWN = 4
local SNAPSHOT_PIECES = 24
local HELLO_DELAYS = { 5, 20, 60 } -- seconds after logging in to ask who's hosting, while nobody has
local LOOK_SECONDS = 6 -- how long /ttpz join waits for a host to answer

-- The first addon release to speak each protocol.
local PROTOCOL_RELEASES = { "0.1.0", "0.2.0" }
ns.PROTOCOL = #PROTOCOL_RELEASES

-- Turned pieces need protocol 2.
local function puzzleNeeds(rotate)
	return rotate and 2 or 1
end

ns.sessions = {}
ns.blocked = {} -- puzzles we heard about but are too old to play, by id
ns.active = nil

local lastAnswered = {}

local function split(text, count)
	local fields = {}
	local pos = 1
	for _ = 1, count - 1 do
		local stop = text:find(":", pos, true)
		if not stop then
			break
		end
		fields[#fields + 1] = text:sub(pos, stop - 1)
		pos = stop + 1
	end
	fields[#fields + 1] = text:sub(pos)
	return fields
end

local function quantize(f)
	return math.floor(math.max(0, math.min(1, f)) * COORD + 0.5)
end

local function newId()
	local id = {}
	for i = 1, 4 do
		id[i] = ns:EncodeNumber(math.random(0, 63), 1)
	end
	return table.concat(id)
end

-- Seeded so every client scatters the pieces the same way.
local function random(session)
	session.rng = session.rng * 16807 % 2147483647
	return session.rng / 2147483647
end

local function channelOf(session)
	return session.channel == "G" and "GUILD" or "GROUP"
end

function ns:Broadcast(session, text, opts)
	return self:Send(text, channelOf(session), nil, opts)
end

-- Geometry ----------------------------------------------------------------------

function ns:PlaySize(session)
	local d = session.decoder
	return d.w * (1 + 2 * self.MARGIN_X), d.h * (1 + 2 * self.MARGIN_Y)
end

-- Jigsaw shapes. Every inner edge gets a round knob on a narrow neck, sticking out of one of
-- the two pieces into the other. Built from the seed, so every client cuts the same shapes.
local KNOB_MIN, KNOB_SPREAD = 0.16, 0.06 -- knob radius, as a fraction of the smaller piece side
local KNOB_REACH = 0.75 -- how far past the edge the knob's center sits, in radii
local KNOB_SLIDE = 0.2 -- how far a knob can wander from the middle of its edge

local function buildShapes(session)
	local d = session.decoder
	local w, h, cols, rows = d.w, d.h, session.cols, session.rows
	local colX, rowY = {}, {}
	for c = 0, cols do
		colX[c] = math.floor(c * w / cols)
	end
	for r = 0, rows do
		rowY[r] = math.floor(r * h / rows)
	end
	-- A piece is its cell, minus the circles of its neighbors' knobs, plus the parts of its own
	-- knobs' circles past its edge. Each knob's box is that part, rounded out to whole pixels.
	local shapes = {}
	for r = 0, rows - 1 do
		for c = 0, cols - 1 do
			shapes[r * cols + c + 1] = { x0 = colX[c], y0 = rowY[r], x1 = colX[c + 1], y1 = rowY[r + 1], knobs = {}, holes = {} }
		end
	end

	session.rng = session.seed % 2147483646 + 1
	local function knob(fromCell, intoCell, cx, cy, radius, dx, dy, edge)
		local k = { cx = cx, cy = cy, r = radius, dx = dx, dy = dy, edge = edge, from = fromCell, rivals = {},
			x0 = math.floor(cx - radius), y0 = math.floor(cy - radius), x1 = math.ceil(cx + radius), y1 = math.ceil(cy + radius) }
		if dx > 0 then k.x0 = edge elseif dx < 0 then k.x1 = edge end
		if dy > 0 then k.y0 = edge elseif dy < 0 then k.y1 = edge end
		tinsert(shapes[fromCell].knobs, k)
		tinsert(shapes[intoCell].holes, { cx = cx, cy = cy, r = radius, knob = k })
	end
	for r = 0, rows - 1 do
		for c = 0, cols - 1 do
			local cell = r * cols + c + 1
			local cellW, cellH = colX[c + 1] - colX[c], rowY[r + 1] - rowY[r]
			if c < cols - 1 then
				local radius = (KNOB_MIN + KNOB_SPREAD * random(session)) * math.min(cellW, cellH, colX[c + 2] - colX[c + 1])
				local cy = (rowY[r] + rowY[r + 1]) / 2 + (random(session) - 0.5) * KNOB_SLIDE * cellH
				local out = random(session) < 0.5 and 1 or -1
				local from, into = cell, cell + 1
				if out < 0 then
					from, into = into, from
				end
				knob(from, into, colX[c + 1] + out * KNOB_REACH * radius, cy, radius, out, 0, colX[c + 1])
			end
			if r < rows - 1 then
				local radius = (KNOB_MIN + KNOB_SPREAD * random(session)) * math.min(cellW, cellH, rowY[r + 2] - rowY[r + 1])
				local cx = (colX[c] + colX[c + 1]) / 2 + (random(session) - 0.5) * KNOB_SLIDE * cellW
				local out = random(session) < 0.5 and 1 or -1
				local from, into = cell, cell + cols
				if out < 0 then
					from, into = into, from
				end
				knob(from, into, cx, rowY[r + 1] + out * KNOB_REACH * radius, radius, 0, out, rowY[r + 1])
			end
		end
	end

	-- Two knobs pushed into one cell near a corner can overlap. The bigger one (or, the same size,
	-- the one from the lower cell) keeps the overlap and the other is cut around it. Knob boxes and
	-- bounds stay as 0.1.0 cuts them, so every version still puts pieces in the same places.
	for _, s in ipairs(shapes) do
		for a = 1, #s.holes - 1 do
			for b = a + 1, #s.holes do
				local ka, kb = s.holes[a].knob, s.holes[b].knob
				if (ka.cx - kb.cx) ^ 2 + (ka.cy - kb.cy) ^ 2 < (ka.r + kb.r) ^ 2 then
					local aWins = ka.r > kb.r or ka.r == kb.r and ka.from < kb.from
					local winner, loser = ka, kb
					if not aWins then
						winner, loser = kb, ka
					end
					tinsert(loser.rivals, winner)
				end
			end
		end
	end

	local bounds = {}
	for i, s in ipairs(shapes) do
		local b = { s.x0, s.y0, s.x1, s.y1 }
		for _, k in ipairs(s.knobs) do
			b[1], b[2] = math.min(b[1], k.x0), math.min(b[2], k.y0)
			b[3], b[4] = math.max(b[3], k.x1), math.max(b[4], k.y1)
		end
		bounds[i] = b
	end
	session.shapes, session.bounds = shapes, bounds
end

-- Picture pixel bounds of piece i, knobs included: x0, y0 inclusive, x1, y1 exclusive.
function ns:PieceRect(session, i)
	local b = session.bounds[i]
	return b[1], b[2], b[3], b[4]
end

function ns:PieceShape(session, i)
	return session.shapes[i]
end

-- Whether piece i covers the point (x, y), in picture pixels.
function ns:PieceContains(session, i, x, y)
	local s = session.shapes[i]
	for _, k in ipairs(s.knobs) do
		local beyond = k.dx ~= 0 and (x - k.edge) * k.dx > 0 or k.dy ~= 0 and (y - k.edge) * k.dy > 0
		if beyond and (x - k.cx) ^ 2 + (y - k.cy) ^ 2 <= k.r * k.r then
			for _, rival in ipairs(k.rivals) do
				if (x - rival.cx) ^ 2 + (y - rival.cy) ^ 2 <= rival.r * rival.r then
					return false
				end
			end
			return true
		end
	end
	if x < s.x0 or x >= s.x1 or y < s.y0 or y >= s.y1 then
		return false
	end
	for _, hole in ipairs(s.holes) do
		if (x - hole.cx) ^ 2 + (y - hole.cy) ^ 2 <= hole.r * hole.r then
			return false
		end
	end
	return true
end

function ns:HomePosition(session, i)
	local x0, y0 = self:PieceRect(session, i)
	local d = session.decoder
	local pw, ph = self:PlaySize(session)
	return quantize((d.w * self.MARGIN_X + x0) / pw) / COORD, quantize((d.h * self.MARGIN_Y + y0) / ph) / COORD
end

-- Turns are quarter turns clockwise, 0-3, about the picture's origin. A piece's turned top left
-- corner, in picture pixels.
local function turnedCorner(session, i, turn)
	local x0, y0, x1, y1 = ns:PieceRect(session, i)
	if turn == 1 then
		return -y1, x0
	elseif turn == 2 then
		return -x1, -y1
	elseif turn == 3 then
		return y0, -x1
	end
	return x0, y0
end

-- Piece i's frame size when turned, in fractions of the play area.
function ns:PieceSize(session, i, turn)
	local x0, y0, x1, y1 = self:PieceRect(session, i)
	local w, h = x1 - x0, y1 - y0
	if turn % 2 == 1 then
		w, h = h, w
	end
	local pw, ph = self:PlaySize(session)
	return w / pw, h / ph
end

-- Where piece j's top left sits relative to piece i's in their group, turned.
function ns:GroupOffset(session, i, j, turn)
	if turn == 0 then
		local hx, hy = self:HomePosition(session, i)
		local jx, jy = self:HomePosition(session, j)
		return jx - hx, jy - hy
	end
	local pw, ph = self:PlaySize(session)
	local ax, ay = turnedCorner(session, i, turn)
	local bx, by = turnedCorner(session, j, turn)
	return (bx - ax) / pw, (by - ay) / ph
end

-- Where piece i's top left goes, from (fx, fy), when its group turns one more quarter clockwise
-- from `turn` about (px, py).
function ns:TurnedPosition(session, i, turn, fx, fy, px, py)
	local pw, ph = self:PlaySize(session)
	local _, h = self:PieceSize(session, i, turn)
	local tx, ty, cx, cy = fx * pw, fy * ph, px * pw, py * ph
	return (cx + cy - ty - h * ph) / pw, (cy + tx - cx) / ph
end

-- How close counts as lined up, in picture pixels.
local function snapTolerance(session)
	local d = session.decoder
	return math.max(2, math.min(d.w / session.cols, d.h / session.rows) * 0.25)
end

-- `turn` defaults to the piece's own; only an upright piece goes home.
function ns:IsNearHome(session, i, fx, fy, turn)
	if (turn or session.pieces[i].turn) ~= 0 then
		return false
	end
	local hx, hy = self:HomePosition(session, i)
	local pw, ph = self:PlaySize(session)
	local dx, dy = math.abs(fx - hx) * pw, math.abs(fy - hy) * ph
	local tolerance = snapTolerance(session)
	return dx <= tolerance and dy <= tolerance
end

local function setPlaced(session, piece, placed, by)
	if (piece.placed or false) == placed then
		return
	end
	piece.placed = placed
	session.placedCount = session.placedCount + (placed and 1 or -1)
	if placed and by then
		local name = ns:ShortName(by)
		session.placedBy[name] = (session.placedBy[name] or 0) + 1
	end
end

-- Groups --------------------------------------------------------------------------
-- Pieces snapped together form a group that moves as one. Members keep their home offsets from
-- each other, so any member's position fixes the whole group's. Every member shares the
-- group's seq. Joining groups is order-independent, so every client ends up with the same ones.

-- Sorted piece indices; singletons get a fresh { i }.
function ns:GroupMembers(session, i)
	return session.pieces[i].group or { i }
end

local function moveGroup(session, i, x, y, turn, seq, by, holder)
	local members = ns:GroupMembers(session, i)
	if #members > 1 and not session.shapes then
		members = { i }
	end
	for _, j in ipairs(members) do
		local piece = session.pieces[j]
		if j == i then
			piece.x, piece.y = x, y
		else
			local ox, oy = ns:GroupOffset(session, i, j, turn)
			piece.x, piece.y = x + ox, y + oy
		end
		piece.turn = turn
		piece.seq, piece.by = seq, by
		piece.holder, piece.heldAt = holder, GetTime()
	end
end

-- Lines a group up behind its most recently moved member, and places all of it if any of it is.
local function normalizeGroup(session, members)
	if #members < 2 or not session.shapes then
		return
	end
	local anchor
	for _, j in ipairs(members) do
		local piece = session.pieces[j]
		if piece.placed then
			for _, k in ipairs(members) do
				local other = session.pieces[k]
				other.x, other.y = ns:HomePosition(session, k)
				other.turn = 0
				setPlaced(session, other, true, nil)
			end
			return
		end
		if not anchor or piece.seq > session.pieces[anchor].seq then
			anchor = j
		end
	end
	local piece = session.pieces[anchor]
	moveGroup(session, anchor, piece.x, piece.y, piece.turn, piece.seq, piece.by, piece.holder)
end

local function link(session, a, b)
	local groupA, groupB = ns:GroupMembers(session, a), ns:GroupMembers(session, b)
	for _, j in ipairs(groupA) do
		if j == b then
			return false
		end
	end
	local merged = {}
	for _, j in ipairs(groupA) do
		merged[#merged + 1] = j
	end
	for _, j in ipairs(groupB) do
		merged[#merged + 1] = j
	end
	table.sort(merged)
	for _, j in ipairs(merged) do
		session.pieces[j].group = merged
	end
	normalizeGroup(session, merged)
	return true
end

-- The loose neighbor piece i's group lines up with when i is at (fx, fy), and where i snaps to.
-- Only neighbors turned the same way line up; `turn` defaults to the group's own.
function ns:FindSnap(session, i, fx, fy, turn)
	local cols = session.cols
	local pw, ph = self:PlaySize(session)
	local tolerance = snapTolerance(session)
	turn = turn or session.pieces[i].turn
	local members = self:GroupMembers(session, i)
	local inGroup = {}
	for _, j in ipairs(members) do
		inGroup[j] = true
	end
	local best, bestDistance, bestX, bestY
	for _, j in ipairs(members) do
		local col = (j - 1) % cols
		local neighbors = { col > 0 and j - 1, col < cols - 1 and j + 1, j - cols, j + cols }
		for k = 1, 4 do
			local n = neighbors[k]
			local other = n and session.pieces[n]
			if other and not inGroup[n] and not other.placed and other.turn == turn and not self:IsHeldByOther(other) then
				local ox, oy = self:GroupOffset(session, i, n, turn)
				local sx, sy = other.x - ox, other.y - oy
				local dx, dy = math.abs(fx - sx) * pw, math.abs(fy - sy) * ph
				if dx <= tolerance and dy <= tolerance and (not best or dx + dy < bestDistance) then
					best, bestDistance, bestX, bestY = n, dx + dy, sx, sy
				end
			end
		end
	end
	return best, bestX, bestY
end

function ns:LinkPieces(session, a, b)
	if link(session, a, b) then
		self:Broadcast(session, format("L:%s:%d:%d", session.id, a, b))
		for _, j in ipairs(self:GroupMembers(session, a)) do
			self:OnPieceChanged(session, j)
		end
	end
end

local function scatter(session)
	local d = session.decoder
	local pw, ph = ns:PlaySize(session)
	local picX0, picY0 = d.w * ns.MARGIN_X / pw, d.h * ns.MARGIN_Y / ph
	local picX1, picY1 = picX0 + d.w / pw, picY0 + d.h / ph
	buildShapes(session)
	session.rng = session.seed
	for i, piece in ipairs(session.pieces) do
		local turn = session.rotate and math.floor(random(session) * 4) % 4 or 0
		local fw, fh = ns:PieceSize(session, i, turn)
		local fx, fy
		for _ = 1, 30 do
			fx, fy = random(session) * (1 - fw), random(session) * (1 - fh)
			if fx + fw < picX0 or fx > picX1 or fy + fh < picY0 or fy > picY1 then
				break
			end
		end
		-- Moves can arrive before the picture's size is known; those positions win.
		if piece.seq == 0 then
			piece.x, piece.y = quantize(fx) / COORD, quantize(fy) / COORD
			piece.turn = turn
		end
	end
	for i, piece in ipairs(session.pieces) do
		if piece.group and piece.group[1] == i then
			normalizeGroup(session, piece.group)
		end
	end
end

-- Sessions ------------------------------------------------------------------------

local function createSession(id, master)
	local session = {
		id = id,
		master = master,
		isMaster = master == ns:PlayerName(),
		chunks = {},
		contiguous = 0,
		decoder = ns:NewDecoder(),
		players = {},
		placedBy = {},
		placedCount = 0,
		lastData = 0,
		lastAsk = 0,
		created = GetTime(),
	}
	session.players[ns:ShortName(master)] = true
	ns.sessions[id] = session
	return session
end

local function applySetup(session, cols, rows, chunks, seed, title, channel, rotate)
	if session.pieces then
		return
	end
	session.cols, session.rows, session.chunkCount, session.seed = cols, rows, chunks, seed
	session.title, session.channel, session.rotate = title, channel, rotate
	session.needs = puzzleNeeds(rotate)
	session.pieces = {}
	for i = 1, cols * rows do
		session.pieces[i] = { x = 0, y = 0, turn = 0, seq = 0 }
	end
end

local function onImageProgress(session)
	local level = session.decoder.level
	if session.decoder.w and not session.scattered then
		session.scattered = true
		scatter(session)
	end
	if level ~= session.shownLevel then
		session.shownLevel = level
		ns:OnImageLevel(session)
	end
	if session.decoder:IsComplete() and not session.ready then
		session.ready = true
		if not session.isMaster then
			ns:AnnounceReady(session)
		end
	end
	ns:OnStatusChanged(session)
	ns:UpdateMinimap()
end

local function addChunk(session, index, text)
	if index < 1 or index > (session.chunkCount or 0) or session.chunks[index] then
		return
	end
	session.chunks[index] = text
	session.lastData = GetTime()
	local advanced = false
	while session.chunks[session.contiguous + 1] do
		session.contiguous = session.contiguous + 1
		local ok, err = session.decoder:Feed(session.chunks[session.contiguous])
		if not ok then
			ns:Print(format("Couldn't read %s's picture: %s", ns:ShortName(session.master), err))
			return
		end
		advanced = true
	end
	if advanced then
		onImageProgress(session)
	end
end

local function removeSession(session)
	ns.sessions[session.id] = nil
	if ns.active == session then
		ns.active = nil
		ns:HideBoard()
	end
	ns:UpdateMinimap()
end

function ns:IsComplete(session)
	return session.pieces and session.placedCount == #session.pieces
end

local function sendSetup(session, chatType, target)
	local text
	if session.needs == 1 then
		text = format("S:%s:%s:%d:%d:%d:%d:%d:%s", session.id, session.channel, session.cols, session.rows,
			session.chunkCount, session.seed, session.ghost and 1 or 0, session.title)
	else
		text = format("A:%s:%d:%s:%s:%s:%d:%d:%d:%d:%s:%s", session.id, session.needs, PROTOCOL_RELEASES[session.needs],
			ns.VERSION, session.channel, session.cols, session.rows, session.chunkCount, session.seed,
			(session.ghost and "g" or "") .. (session.rotate and "r" or ""), session.title)
	end
	ns:Send(text, chatType, target)
end

-- Chunks go to the whole channel, keyed so overlapping catch-up requests share one copy.
local function sendChunks(session, first)
	for i = first, session.chunkCount do
		ns:Broadcast(session, format("D:%s:%d:%s", session.id, i, session.chunks[i]),
			{ bulk = true, key = "D" .. session.id .. i })
	end
end

local function sendSnapshot(session, target)
	local parts = {}
	local first = 1
	for i, piece in ipairs(session.pieces) do
		parts[#parts + 1] = ns:EncodeNumber(quantize(piece.x), 2) .. ns:EncodeNumber(quantize(piece.y), 2)
			.. (piece.placed and "p" or SNAPSHOT_TURNS:sub(piece.turn + 1, piece.turn + 1))
			.. ns:EncodeNumber(math.min(piece.seq, 262143), 3)
			.. ns:EncodeNumber(ns:GroupMembers(session, i)[1], 2)
		if #parts == SNAPSHOT_PIECES or i == #session.pieces then
			ns:Send(format("P:%s:%d:%s", session.id, first, table.concat(parts)), "WHISPER", target)
			first = i + 1
			wipe(parts)
		end
	end
end

-- A host of a puzzle that needs protocol 1 may be 0.1.0, which can't read a Q with more fields.
local function ask(session, snapshot)
	session.lastAsk = GetTime()
	local text = format("Q:%s:%d:%d", session.id, session.contiguous, snapshot and 1 or 0)
	if session.needs > 1 then
		text = text .. ":" .. ns.PROTOCOL
	end
	ns:Send(text, "WHISPER", session.master)
end

-- Tells the host, once per player, who can't play their puzzle and what they need.
local function noteTooOld(session, sender, protocol, version)
	session.tooOld = session.tooOld or {}
	local name = ns:ShortName(sender)
	if session.tooOld[name] or protocol >= session.needs then
		return
	end
	session.tooOld[name] = true
	ns:Print(format("%s can't join |cffffd100%s|r: they have Turkey Tickle UI Puzzle %s, and this puzzle needs %s "
		.. "or newer.", name, session.title, ns:VersionName(version), PROTOCOL_RELEASES[session.needs]))
end

function ns:Hello(chatType, target)
	return self:Send(format("H:%d:%s", self.PROTOCOL, self.VERSION), chatType, target)
end

-- Hosting -------------------------------------------------------------------------

function ns:PiecesGrid(w, h, count)
	local cols = math.max(2, math.floor(math.sqrt(count * w / h) + 0.5))
	local rows = math.max(2, math.floor(count / cols + 0.5))
	cols = math.min(cols, math.floor(w / 6))
	rows = math.min(rows, math.floor(h / 6))
	return cols, rows
end

-- A party / raid puzzle can start `alone`, outside a group; whoever joins the group later asks
-- who's hosting and catches up. Without `alone`, that fails with a third result, "noGroup".
function ns:HostSession(code, title, pieceCount, channel, ghost, rotate, alone)
	local decoder = self:NewDecoder()
	local ok, err = decoder:Feed(code)
	if not ok then
		return false, err
	elseif not decoder:IsComplete() then
		return false, "The image code is cut off. Copy the whole thing."
	end
	local chatType = channel == "GUILD" and "GUILD" or "GROUP"
	local solo = not self:CanSendTo(chatType)
	if solo and chatType == "GUILD" then
		return false, "You're not in a guild."
	elseif solo and not alone then
		return false, "You're not in a party or raid.", "noGroup"
	end
	for _, other in pairs(self.sessions) do
		if other.isMaster then
			self:Broadcast(other, "E:" .. other.id)
			removeSession(other)
		end
	end

	local session = createSession(newId(), self:PlayerName())
	local cols, rows = self:PiecesGrid(decoder.w, decoder.h, pieceCount)
	title = (title or ""):gsub("|", ""):sub(1, 40)
	if title == "" then
		title = "Jigsaw"
	end
	local chunks = math.ceil(#code / self.MAX_PAYLOAD)
	applySetup(session, cols, rows, chunks, math.random(1, 2147483646), title, chatType == "GUILD" and "G" or "P",
		rotate and true or false)
	session.ghost = ghost and true or false
	for i = 1, chunks do
		session.chunks[i] = code:sub((i - 1) * self.MAX_PAYLOAD + 1, i * self.MAX_PAYLOAD)
	end
	session.contiguous = chunks
	session.decoder = decoder
	onImageProgress(session)

	sendSetup(session, chatType)
	sendChunks(session, 1)
	self:JoinSession(session)
	if solo then
		self:Print(format("Puzzle started just for you: %d pieces. Anyone who joins your party can play along.",
			cols * rows))
	else
		self:Print(format("Puzzle started for your %s: %d pieces, sending the picture (about %s).",
			chatType == "GUILD" and "guild" or "group", cols * rows, self:FormatDuration(self:EstimateSendSeconds(#code))))
	end
	return true
end

function ns:EndSession()
	local session = self.active
	if not session then
		self:Print("You're not in a puzzle.")
	elseif not session.isMaster then
		self:Print("Only the host can end the puzzle. Use /ttpz leave to stop playing.")
	else
		self:Broadcast(session, "E:" .. session.id)
		removeSession(session)
		self:Print("Puzzle ended.")
	end
end

function ns:SetGhost(session, ghost)
	if not session.isMaster or session.ghost == ghost then
		return
	end
	session.ghost = ghost
	self:Broadcast(session, format("G:%s:%d", session.id, ghost and 1 or 0))
	if session == self.active then
		self:RefreshBoard()
	end
end

-- Playing -------------------------------------------------------------------------

function ns:FindSession(masterName)
	masterName = masterName and masterName ~= "" and masterName:lower()
	local best
	for _, session in pairs(self.sessions) do
		if masterName then
			if self:ShortName(session.master):lower() == masterName then
				return session
			end
		elseif not best or session.created > best.created then
			best = session
		end
	end
	if masterName then
		return nil
	end
	return self.active or best
end

-- Without a session, asks around for puzzles in progress and joins the first one that answers
-- (hosted by `masterName`, if given).
function ns:JoinSession(session, masterName)
	if not session then
		if not self:LookForPuzzles() then
			self:Print("There's no puzzle to join. Type /ttpz host to start one.")
			return
		end
		local wanted = { name = masterName and masterName ~= "" and masterName:lower() }
		self.joinWanted = wanted
		self:Print("Looking for puzzles in progress in your guild and group...")
		C_Timer.After(LOOK_SECONDS, function()
			if self.joinWanted == wanted then
				self.joinWanted = nil
				self:Print("No puzzles found. Type /ttpz host to start one.")
			end
		end)
		return
	end
	self.joinWanted = nil
	StaticPopup_Hide("TURKEYTICKLEUI_PUZZLE_READY")
	self.active = session
	session.players[self:ShortName(self:PlayerName())] = true
	if not session.joined then
		session.joined = true
		self:Broadcast(session, "J:" .. session.id)
	end
	local flowing = GetTime() - session.lastData < STALL_SECONDS
	if not session.isMaster and not session.decoder:IsComplete() and not flowing then
		ask(session, false)
	end
	self:ShowBoard()
	self:UpdateMinimap()
end

function ns:LeaveSession()
	if self.active then
		self.active = nil
		self:HideBoard()
		self:UpdateMinimap()
		self:Print("Left the puzzle. Type /ttpz join to come back.")
	end
end

function ns:Toggle()
	if self:IsBoardShown() then
		self:HideBoard()
	elseif self.active then
		self:ShowBoard()
	elseif next(self.sessions) then
		self:JoinSession(self:FindSession())
	else
		-- Any puzzle that answers gets announced, with a popup once it's loaded.
		self:LookForPuzzles()
		self:ShowHost()
	end
end

-- Called for every local change to a piece: drag updates, drops, snaps and turns. `turn`
-- defaults to the piece's own. A `quiet` move isn't sent; the next one carries it.
function ns:MovePiece(session, i, fx, fy, state, turn, quiet)
	local piece = session.pieces[i]
	if piece.placed then
		return
	end
	turn = turn or piece.turn
	local me = self:PlayerName()
	local members = self:GroupMembers(session, i)
	local seq = 0
	for _, j in ipairs(members) do
		seq = math.max(seq, session.pieces[j].seq)
	end
	local x, y = quantize(fx) / COORD, quantize(fy) / COORD
	if state == "p" then
		x, y = self:HomePosition(session, i)
		turn = 0
	end
	moveGroup(session, i, x, y, turn, seq + 1, me, state == "d" and me or nil)
	if state == "p" then
		for _, j in ipairs(members) do
			setPlaced(session, session.pieces[j], true, me)
		end
	end
	if not quiet then
		local text = format("M:%s:%d:%d:%d:%d:%s", session.id, i, piece.seq, quantize(piece.x), quantize(piece.y), state)
		if turn ~= 0 then
			text = text .. ":" .. turn
		end
		self:Broadcast(session, text, { key = state == "d" and ("M" .. session.id .. i) or nil })
	end
	for _, j in ipairs(members) do
		self:OnPieceChanged(session, j)
	end
	if state == "p" and self:IsComplete(session) then
		self:OnComplete(session, true)
	end
end

function ns:IsHeldByOther(piece)
	return piece.holder and piece.holder ~= self:PlayerName() and GetTime() - piece.heldAt < HOLD_TIMEOUT
end

local function isNewer(piece, seq, by)
	if seq ~= piece.seq then
		return seq > piece.seq
	end
	return by < (piece.by or "")
end

-- Receiving -----------------------------------------------------------------------

local receive = {}

local function setup(sender, f, id, channel, cols, rows, chunks, seed, ghost, rotate, title)
	cols, rows, chunks, seed = tonumber(cols), tonumber(rows), tonumber(chunks), tonumber(seed)
	if not (id and cols and rows and chunks and seed) or cols * rows > 400 or chunks > 1000 then
		return
	end
	ns.blocked[id] = nil
	local session = ns.sessions[id]
	local isNew = not session
	if isNew then
		for _, other in pairs(ns.sessions) do
			if other.master == sender then
				removeSession(other)
			end
		end
		session = createSession(id, sender)
	end
	applySetup(session, cols, rows, chunks, seed, (title or ""):gsub("|", ""), channel == "G" and "G" or "P", rotate)
	if sender == session.master then
		session.ghost = ghost
		if not isNew and session == ns.active then
			ns:RefreshBoard()
		end
	end
	if isNew then
		-- Heard about it after it started: catch up now so it's ready by the time they open it. A Q
		-- sent before we knew the puzzle only gets this setup back from hosts past protocol 1.
		if f.channel == "WHISPER" and (session.needs > 1 or not lastAnswered["?" .. id]) then
			ask(session, true)
		end
		ns:AnnounceSession(session)
	end
end

function receive.S(sender, f)
	setup(sender, f, f[2], f[3], f[4], f[5], f[6], f[7], f[8] == "1", false, f[9])
end

function ns:BlockedText(info)
	local host = self:ShortName(info.master)
	return format("%s's puzzle |cffffd100%s|r needs Turkey Tickle UI Puzzle %s or newer. %s has %s and you have %s: "
		.. "update to join.", host, info.title, info.release, host, self:VersionName(info.version),
		self:VersionName(self.VERSION))
end

-- A puzzle that needs a newer protocol than ours: say what to update to, once, or again when the
-- player is looking for it.
local function blocked(sender, f, id, needs)
	local info = ns.blocked[id]
	local isNew = not info
	if isNew then
		info = { master = sender, needs = needs }
		ns.blocked[id] = info
		ns:Send(format("V:%s:%d:%s", id, ns.PROTOCOL, ns.VERSION), "WHISPER", sender)
	end
	info.release = (f[4] or "?"):gsub("|", "")
	info.version = (f[5] or "?"):gsub("|", "")
	info.title = (f[12] or "Jigsaw"):gsub("|", "")
	local wanted = ns.joinWanted
	local isWanted = wanted and (not wanted.name or ns:ShortName(sender):lower() == wanted.name)
	if isWanted then
		ns.joinWanted = nil
	end
	if isNew or isWanted then
		ns:Print(ns:BlockedText(info))
	end
end

function receive.A(sender, f)
	local id, needs = f[2], tonumber(f[3])
	if not (id and needs) then
		return
	elseif needs > ns.PROTOCOL then
		blocked(sender, f, id, needs)
		return
	end
	local flags = f[11] or ""
	setup(sender, f, id, f[6], f[7], f[8], f[9], f[10], flags:find("g", 1, true) ~= nil,
		flags:find("r", 1, true) ~= nil, f[12])
end

function receive.V(sender, f)
	local session = ns.sessions[f[2]]
	if session and session.isMaster then
		noteTooOld(session, sender, tonumber(f[3]) or 1, (f[4] or "?"):gsub("|", ""))
	end
end

function receive.D(sender, f)
	local session, index = ns.sessions[f[2]], tonumber(f[3])
	if not session then
		-- Joined mid-stream; ask the sender to start us from the top.
		if f.channel ~= "WHISPER" and not lastAnswered["?" .. f[2]] then
			lastAnswered["?" .. f[2]] = true
			ns:Send(format("Q:%s:0:1", f[2]), "WHISPER", sender)
		end
		return
	end
	if sender == session.master and index and f[4] then
		addChunk(session, index, f[4])
	end
end

function receive.M(sender, f)
	local session = ns.sessions[f[2]]
	local i, seq, x, y, state = tonumber(f[3]), tonumber(f[4]), tonumber(f[5]), tonumber(f[6]), f[7]
	local turn = math.floor(tonumber(f[8]) or 0) % 4
	local piece = session and session.pieces and i and session.pieces[i]
	if not (piece and seq and x and y) or piece.placed or not isNewer(piece, seq, sender) then
		return
	end
	local members = ns:GroupMembers(session, i)
	for _, j in ipairs(members) do
		if ns:IsDragging(session, j) then
			ns:CancelDrag()
		end
	end
	moveGroup(session, i, quantize(x / COORD) / COORD, quantize(y / COORD) / COORD, state == "p" and 0 or turn, seq,
		sender, state == "d" and sender or nil)
	session.players[ns:ShortName(sender)] = true
	if state == "p" then
		for _, j in ipairs(members) do
			local member = session.pieces[j]
			if session.shapes then
				member.x, member.y = ns:HomePosition(session, j)
			end
			setPlaced(session, member, true, sender)
		end
	end
	for _, j in ipairs(members) do
		ns:OnPieceChanged(session, j, true)
	end
	if state == "p" and ns:IsComplete(session) then
		ns:OnComplete(session, true)
	end
end

function receive.L(sender, f)
	local session, a, b = ns.sessions[f[2]], tonumber(f[3]), tonumber(f[4])
	local pieces = session and session.pieces
	if not (pieces and a and b and pieces[a] and pieces[b] and a ~= b) then
		return
	end
	for _, j in ipairs(ns:GroupMembers(session, a)) do
		if ns:IsDragging(session, j) then
			ns:CancelDrag()
		end
	end
	for _, j in ipairs(ns:GroupMembers(session, b)) do
		if ns:IsDragging(session, j) then
			ns:CancelDrag()
		end
	end
	if link(session, a, b) then
		for _, j in ipairs(ns:GroupMembers(session, a)) do
			ns:OnPieceChanged(session, j, true)
		end
		if ns:IsComplete(session) then
			ns:OnComplete(session, true)
		end
	end
end

function receive.J(sender, f)
	local session = ns.sessions[f[2]]
	if session then
		session.players[ns:ShortName(sender)] = true
		ns:OnStatusChanged(session)
	end
end

function receive.Q(sender, f)
	local session, have = ns.sessions[f[2]], tonumber(f[3]) or 0
	if not (session and session.isMaster) then
		return
	end
	-- Anyone not saying they can play only gets the setup: 0.1.0 asks after seeing chunks of a puzzle
	-- it can't play, and newer addons that hadn't heard of it ask again once they have.
	if (tonumber(f[5]) or 1) < session.needs then
		sendSetup(session, "WHISPER", sender)
		return
	end
	local now = GetTime()
	if now - (lastAnswered[sender] or -ANSWER_COOLDOWN) < ANSWER_COOLDOWN then
		return
	end
	lastAnswered[sender] = now
	sendSetup(session, "WHISPER", sender)
	if f[4] == "1" then
		sendSnapshot(session, sender)
	end
	sendChunks(session, math.max(1, have + 1))
end

function receive.P(sender, f)
	local session, first, data = ns.sessions[f[2]], tonumber(f[3]), f[4]
	if not (session and session.pieces and first and data and sender == session.master) then
		return
	end
	local changed = {}
	for n = 0, math.floor(#data / 10) - 1 do
		local i, pos = first + n, n * 10 + 1
		local piece = session.pieces[i]
		local x, y = ns:DecodeNumber(data, pos, 2), ns:DecodeNumber(data, pos + 2, 2)
		local seq = ns:DecodeNumber(data, pos + 5, 3)
		local root = ns:DecodeNumber(data, pos + 8, 2)
		if piece and x and y and seq and seq >= piece.seq and not piece.placed then
			local state = data:sub(pos + 4, pos + 4)
			piece.seq, piece.by = seq, sender
			piece.x, piece.y = x / COORD, y / COORD
			piece.turn = state ~= "p" and ((SNAPSHOT_TURNS:find(state, 1, true) or 1) - 1) or 0
			setPlaced(session, piece, state == "p", nil)
		end
		if piece and root and root ~= i and session.pieces[root] then
			link(session, root, i)
		end
		if piece then
			for _, j in ipairs(ns:GroupMembers(session, i)) do
				changed[j] = true
			end
		end
	end
	for j in pairs(changed) do
		ns:OnPieceChanged(session, j)
	end
	if ns:IsComplete(session) then
		ns:OnComplete(session, false)
	end
end

function receive.H(sender, f)
	local now = GetTime()
	if now - (lastAnswered["H" .. sender] or -10) < 10 then
		return
	end
	lastAnswered["H" .. sender] = now
	local channel = f.channel == "GUILD" and "G" or "P"
	-- 0.1.0 says hello without a protocol.
	local protocol, version = tonumber(f[2]) or 1, f[3] and f[3]:gsub("|", "") or PROTOCOL_RELEASES[1]
	for _, session in pairs(ns.sessions) do
		if session.isMaster and session.channel == channel then
			noteTooOld(session, sender, protocol, version)
			-- Newer addons that can't play still read the setup, to tell their player what to update to.
			if protocol > 1 or session.needs == 1 then
				sendSetup(session, "WHISPER", sender)
			end
		end
	end
end

function receive.E(sender, f)
	local info = ns.blocked[f[2]]
	if info and info.master == sender then
		ns.blocked[f[2]] = nil
	end
	local session = ns.sessions[f[2]]
	if session and session.master == sender then
		if ns.active == session then
			ns:Print(format("%s ended the puzzle.", ns:ShortName(sender)))
		end
		removeSession(session)
	end
end

function receive.G(sender, f)
	local session = ns.sessions[f[2]]
	if session and session.master == sender then
		session.ghost = f[3] == "1"
		if session == ns.active then
			ns:RefreshBoard()
		end
	end
end

-- Messages whose last field is free text; the rest split at every ":", so fields a newer addon
-- appends don't run into the ones we read.
local FIELD_COUNTS = { S = 9, A = 12, D = 4 }

function ns:OnMessage(text, channel, sender)
	local kind = text:sub(1, 1)
	local handler = receive[kind]
	if not handler then
		return
	end
	local fields = split(text, FIELD_COUNTS[kind] or math.huge)
	fields.channel = channel
	handler(sender, fields)
end

-- Joining prompts and catch-up ----------------------------------------------------

StaticPopupDialogs.TURKEYTICKLEUI_PUZZLE_READY = {
	text = "%s's jigsaw puzzle is ready:\n|cffffd100%s|r\n\nOpen it now?",
	button1 = "Open",
	button2 = "Later",
	OnAccept = function(self, data)
		ns:JoinSession(data)
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

function ns:AnnounceSession(session)
	local wanted = self.joinWanted
	if wanted and (not wanted.name or self:ShortName(session.master):lower() == wanted.name) then
		self:Print(format("Joining %s's puzzle: |cffffd100%s|r.", self:ShortName(session.master), session.title))
		self:JoinSession(session)
		return
	end
	self:Print(format("%s is starting a jigsaw puzzle: |cffffd100%s|r. Loading the picture; the puzzle button on "
		.. "your minimap lights up gold when it's ready.", self:ShortName(session.master), session.title))
	self:UpdateMinimap()
end

function ns:AnnounceReady(session)
	if self.active == session and self:IsBoardShown() then
		return
	end
	local who = self:ShortName(session.master)
	self:Print(format("|cffffd100%s|r is ready! Click the puzzle button on your minimap or type /ttpz join.", session.title))
	self:PlaySound("READY_CHECK")
	if self.db.prompt then
		StaticPopup_Show("TURKEYTICKLEUI_PUZZLE_READY", who, session.title, session)
	end
end

function ns:PrintStatus()
	for _, info in pairs(self.blocked) do
		self:Print(self:BlockedText(info))
	end
	if not next(self.sessions) then
		if not next(self.blocked) then
			self:Print("No puzzles right now. Type /ttpz host to start one.")
		end
		return
	end
	for _, session in pairs(self.sessions) do
		self:Print(format("%s by %s: %d/%d pieces placed, picture %d%%%s", session.title or "?",
			self:ShortName(session.master), session.placedCount, session.pieces and #session.pieces or 0,
			math.floor(session.decoder:Progress() * 100), self.active == session and " (playing)" or ""))
	end
end

local function checkStalls()
	local now = GetTime()
	for _, session in pairs(ns.sessions) do
		if not session.isMaster and not session.decoder:IsComplete() and now - session.lastData > STALL_SECONDS
			and now - session.lastAsk > ASK_COOLDOWN then
			ask(session, false)
		end
	end
end

-- Asks the guild and group who's hosting; hosts whisper their puzzles back, and we catch up from
-- there. Returns whether anyone could be asked.
function ns:LookForPuzzles()
	local asked = false
	for _, chatType in ipairs({ "GUILD", "GROUP" }) do
		if self:CanSendTo(chatType) then
			self:Hello(chatType)
			asked = true
		end
	end
	return asked
end

function ns.handlers.PLAYER_ENTERING_WORLD(isInitialLogin, isReloadingUi)
	if ns.helloSent then
		return
	end
	ns.helloSent = true
	C_Timer.NewTicker(2, checkStalls)
	-- Guild membership often isn't known yet a few seconds in, so ask again later if nobody answered.
	for _, delay in ipairs(HELLO_DELAYS) do
		C_Timer.After(delay, function()
			if not next(ns.sessions) then
				ns:LookForPuzzles()
			end
		end)
	end
end

function ns.handlers.GROUP_JOINED()
	C_Timer.After(2, function()
		if ns:CanSendTo("GROUP") then
			ns:Hello("GROUP")
		end
	end)
end
