local ADDON, ns = ...

-- Messages (fields split on ":", the last field may contain anything but "|"):
--   S:id:channel:cols:rows:chunks:seed:ghost:title   a puzzle exists (channel G = guild, P = group)
--   G:id:ghost                                 the host turned the picture under the pieces on (1) or off (0)
--   D:id:index:text                            a chunk of the image code
--   M:id:piece:seq:x:y:state                   a piece and its group moved (d = held, r = let go, p = placed)
--   L:id:a:b                                   pieces a and b were snapped together, joining their groups
--   J:id                                       someone opened the puzzle
--   Q:id:have:snapshot                         whisper to the host: send me chunks after `have`
--   P:id:first:pieces                          piece positions for someone catching up
--   H                                          anyone hosting? (sent after logging in)
--   E:id                                       the host ended the puzzle
-- Positions are fractions of the play area, sent as 0-4000. Every move bumps the piece's
-- seq; the higher seq wins, and on a tie the alphabetically first player wins.

local COORD = 4000
ns.MARGIN_X = 0.6 -- play area margins, in picture widths / heights
ns.MARGIN_Y = 0.35
local HOLD_TIMEOUT = 15
local STALL_SECONDS = 6
local ASK_COOLDOWN = 8
local ANSWER_COOLDOWN = 4
local SNAPSHOT_PIECES = 24

ns.sessions = {}
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
		local k = { cx = cx, cy = cy, r = radius, dx = dx, dy = dy, edge = edge,
			x0 = math.floor(cx - radius), y0 = math.floor(cy - radius), x1 = math.ceil(cx + radius), y1 = math.ceil(cy + radius) }
		if dx > 0 then k.x0 = edge elseif dx < 0 then k.x1 = edge end
		if dy > 0 then k.y0 = edge elseif dy < 0 then k.y1 = edge end
		tinsert(shapes[fromCell].knobs, k)
		tinsert(shapes[intoCell].holes, { cx = cx, cy = cy, r = radius })
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

-- How close counts as lined up, in picture pixels.
local function snapTolerance(session)
	local d = session.decoder
	return math.max(2, math.min(d.w / session.cols, d.h / session.rows) * 0.25)
end

function ns:IsNearHome(session, i, fx, fy)
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

local function moveGroup(session, i, x, y, seq, by, holder)
	local members = ns:GroupMembers(session, i)
	if #members > 1 and not session.shapes then
		members = { i }
	end
	local hx, hy
	if session.shapes then
		hx, hy = ns:HomePosition(session, i)
	end
	for _, j in ipairs(members) do
		local piece = session.pieces[j]
		if j == i then
			piece.x, piece.y = x, y
		else
			local jx, jy = ns:HomePosition(session, j)
			piece.x, piece.y = x + jx - hx, y + jy - hy
		end
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
				setPlaced(session, other, true, nil)
			end
			return
		end
		if not anchor or piece.seq > session.pieces[anchor].seq then
			anchor = j
		end
	end
	local piece = session.pieces[anchor]
	moveGroup(session, anchor, piece.x, piece.y, piece.seq, piece.by, piece.holder)
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
function ns:FindSnap(session, i, fx, fy)
	local cols = session.cols
	local pw, ph = self:PlaySize(session)
	local tolerance = snapTolerance(session)
	local hx, hy = self:HomePosition(session, i)
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
			if other and not inGroup[n] and not other.placed and not self:IsHeldByOther(other) then
				local nx, ny = self:HomePosition(session, n)
				local sx, sy = other.x - (nx - hx), other.y - (ny - hy)
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
		local x0, y0, x1, y1 = ns:PieceRect(session, i)
		local fw, fh = (x1 - x0) / pw, (y1 - y0) / ph
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

local function applySetup(session, cols, rows, chunks, seed, title, channel)
	if session.pieces then
		return
	end
	session.cols, session.rows, session.chunkCount, session.seed = cols, rows, chunks, seed
	session.title, session.channel = title, channel
	session.pieces = {}
	for i = 1, cols * rows do
		session.pieces[i] = { x = 0, y = 0, seq = 0 }
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
	local text = format("S:%s:%s:%d:%d:%d:%d:%d:%s", session.id, session.channel, session.cols, session.rows,
		session.chunkCount, session.seed, session.ghost and 1 or 0, session.title)
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
			.. (piece.placed and "p" or "f") .. ns:EncodeNumber(math.min(piece.seq, 262143), 3)
			.. ns:EncodeNumber(ns:GroupMembers(session, i)[1], 2)
		if #parts == SNAPSHOT_PIECES or i == #session.pieces then
			ns:Send(format("P:%s:%d:%s", session.id, first, table.concat(parts)), "WHISPER", target)
			first = i + 1
			wipe(parts)
		end
	end
end

local function ask(session, snapshot)
	session.lastAsk = GetTime()
	ns:Send(format("Q:%s:%d:%d", session.id, session.contiguous, snapshot and 1 or 0), "WHISPER", session.master)
end

-- Hosting -------------------------------------------------------------------------

function ns:PiecesGrid(w, h, count)
	local cols = math.max(2, math.floor(math.sqrt(count * w / h) + 0.5))
	local rows = math.max(2, math.floor(count / cols + 0.5))
	cols = math.min(cols, math.floor(w / 6))
	rows = math.min(rows, math.floor(h / 6))
	return cols, rows
end

function ns:HostSession(code, title, pieceCount, channel, ghost)
	local decoder = self:NewDecoder()
	local ok, err = decoder:Feed(code)
	if not ok then
		return false, err
	elseif not decoder:IsComplete() then
		return false, "The image code is cut off. Copy the whole thing."
	end
	local chatType = channel == "GUILD" and "GUILD" or "GROUP"
	if not self:CanSendTo(chatType) then
		return false, chatType == "GUILD" and "You're not in a guild." or "You're not in a party or raid."
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
	applySetup(session, cols, rows, chunks, math.random(1, 2147483646), title, chatType == "GUILD" and "G" or "P")
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
	self:Print(format("Puzzle started for your %s: %d pieces, sending the picture (about %s).",
		chatType == "GUILD" and "guild" or "group", cols * rows, self:FormatDuration(self:EstimateSendSeconds(#code))))
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

function ns:JoinSession(session)
	if not session then
		self:Print("There's no puzzle to join. Type /ttpz host to start one.")
		return
	end
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
		self:ShowHost()
	end
end

-- Called for every local change to a piece: drag updates, drops and snaps.
function ns:MovePiece(session, i, fx, fy, state)
	local piece = session.pieces[i]
	if piece.placed then
		return
	end
	local me = self:PlayerName()
	local members = self:GroupMembers(session, i)
	local seq = 0
	for _, j in ipairs(members) do
		seq = math.max(seq, session.pieces[j].seq)
	end
	local x, y = quantize(fx) / COORD, quantize(fy) / COORD
	if state == "p" then
		x, y = self:HomePosition(session, i)
	end
	moveGroup(session, i, x, y, seq + 1, me, state == "d" and me or nil)
	if state == "p" then
		for _, j in ipairs(members) do
			setPlaced(session, session.pieces[j], true, me)
		end
	end
	self:Broadcast(session, format("M:%s:%d:%d:%d:%d:%s", session.id, i, piece.seq, quantize(piece.x),
		quantize(piece.y), state), { key = state == "d" and ("M" .. session.id .. i) or nil })
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

function receive.S(sender, f)
	local id, channel, cols, rows, chunks, seed = f[2], f[3], tonumber(f[4]), tonumber(f[5]), tonumber(f[6]), tonumber(f[7])
	if not (id and cols and rows and chunks and seed) or cols * rows > 400 or chunks > 1000 then
		return
	end
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
	applySetup(session, cols, rows, chunks, seed, (f[9] or ""):gsub("|", ""), channel == "G" and "G" or "P")
	if sender == session.master then
		session.ghost = f[8] == "1"
		if not isNew and session == ns.active then
			ns:RefreshBoard()
		end
	end
	if isNew then
		-- Heard about it after it started: catch up now so it's ready by the time they open it.
		if f.channel == "WHISPER" and not lastAnswered["?" .. id] then
			ask(session, true)
		end
		ns:AnnounceSession(session)
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
	moveGroup(session, i, quantize(x / COORD) / COORD, quantize(y / COORD) / COORD, seq, sender,
		state == "d" and sender or nil)
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
			piece.seq, piece.by = seq, sender
			piece.x, piece.y = x / COORD, y / COORD
			setPlaced(session, piece, data:sub(pos + 4, pos + 4) == "p", nil)
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
	for _, session in pairs(ns.sessions) do
		if session.isMaster and session.channel == channel then
			sendSetup(session, "WHISPER", sender)
		end
	end
end

function receive.E(sender, f)
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

local FIELD_COUNTS = { S = 9, G = 3, L = 4, D = 4, M = 7, J = 2, Q = 4, P = 4, H = 1, E = 2 }

function ns:OnMessage(text, channel, sender)
	local kind = text:sub(1, 1)
	local handler = receive[kind]
	if not handler then
		return
	end
	local fields = split(text, FIELD_COUNTS[kind])
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
	if not next(self.sessions) then
		self:Print("No puzzles right now. Type /ttpz host to start one.")
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

function ns.handlers.PLAYER_ENTERING_WORLD(isInitialLogin, isReloadingUi)
	if ns.helloSent then
		return
	end
	ns.helloSent = true
	C_Timer.NewTicker(2, checkStalls)
	C_Timer.After(5, function()
		if ns:CanSendTo("GUILD") then
			ns:Send("H", "GUILD")
		end
		if ns:CanSendTo("GROUP") then
			ns:Send("H", "GROUP")
		end
	end)
end
