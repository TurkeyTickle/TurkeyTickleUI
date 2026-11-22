local ADDON, ns = ...

local WINDOW_WIDTH, WINDOW_HEIGHT = 900, 660
local CANVAS_WIDTH, CANVAS_HEIGHT = 864, 548
local SEND_INTERVAL = 0.25
local SETTLE_SPEED = 12
local TEXTURES_PER_FRAME = 4000
local HELD_BY_ME = { 1.0, 0.82, 0.0 }
local HELD_BY_OTHER = { 1.0, 0.45, 0.1 }
local EDGE = { 0, 0, 0, 0.6 }
local EDGE_WIDTH = 1.5 -- outline thickness, in board units
local SEAM = 0.75 -- holes are cut this much smaller, so placed neighbors' antialiased edges overlap
local MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\Media\\"
local MASK_SCALE = 64 / 60 -- mask texture size over its circle's diameter
local ZOOM_STEP = 1.15 -- per mouse wheel notch
local MAX_ZOOM = 4
local MIN_WIDTH, MIN_HEIGHT = 700, 420 -- narrower and the checkbox runs into the buttons

local window, viewport, canvas
local pieceFrames = {}
local drag
local boardW, boardH, pixelScale = 1, 1, 1
local topLevel = 0
local renderQueue = {}

function ns:GamepadUI()
	if self.gamepadUI == nil then
		local types = Enum and Enum.InputDeviceInterfaceType
		local style = C_InputInterfaceStyle
		self.gamepadUI = types and types.Gamepad and style and style.GetCurrentStyle
			and style.GetCurrentStyle() == types.Gamepad or false
	end
	return self.gamepadUI
end

-- Drawing -------------------------------------------------------------------------

local function newTexture(owner, layer)
	local tex = owner:CreateTexture(nil, layer or "ARTWORK")
	if tex.SetSnapToPixelGrid then
		tex:SetSnapToPixelGrid(false)
		tex:SetTexelSnappingBias(0)
	end
	return tex
end

-- Texture pools live on their owner frame under `key`; unused ones are hidden, never destroyed.
local function pooled(owner, key, used, layer)
	local pool = owner[key]
	if not pool then
		pool = {}
		owner[key] = pool
	end
	local tex = pool[used]
	if not tex then
		tex = newTexture(owner, layer)
		pool[used] = tex
	end
	return tex
end

local function hideUnused(owner, key, used)
	for k = used + 1, #(owner[key] or {}) do
		owner[key][k]:Hide()
	end
end

local function place(tex, x, y, width, height, scale)
	tex:ClearAllPoints()
	tex:SetPoint("TOPLEFT", x * scale, -y * scale)
	tex:SetSize(width * scale, height * scale)
	tex:Show()
end

-- Strips --------------------------------------------------------------------------
-- WoW stops drawing the entire interface somewhere under 20,000 textures, and a picture drawn one
-- texture per color run needs far more. So the picture is cut into horizontal gradient strips that
-- follow its colors within a tolerance, identical strips in consecutive rows merge into one, and of
-- the cuts that fit the board's budget, the one closest to the picture wins. Long smeared strips look
-- worse than slightly bigger blocks, and the error says so.

local BOARD_TEXTURES = 8000
local GHOST_TEXTURES = 1500
local MAX_STRIP = 48
local STEPS = { 1, 2, 3, 4, 5, 6, 8, 12, 16 }
local TOLERANCES = { 0, 0.03, 0.06, 0.1, 0.14, 0.2 }

local function clamp(value, low, high)
	return value < low and low or value > high and high or value
end

-- WoW gives a texture at most this many masks.
local MAX_MASKS = 3

local function holesOverlapping(holes, x0, y0, x1, y1)
	local found = {}
	for h, hole in ipairs(holes) do
		if x0 < hole.cx + hole.r and x1 > hole.cx - hole.r and y0 < hole.cy + hole.r and y1 > hole.cy - hole.r then
			found[#found + 1] = h
		end
	end
	return found
end

-- Splits a rectangle of whole picture pixels in halves until each part overlaps at most MAX_MASKS
-- holes. Parts are { x0, y0, x1, y1, holes = { hole indices } }.
local function splitForMasks(holes, x0, y0, x1, y1, out)
	out = out or {}
	local found = holesOverlapping(holes, x0, y0, x1, y1)
	local w, h = x1 - x0, y1 - y0
	if #found <= MAX_MASKS or (w < 2 and h < 2) then
		for k = #found, MAX_MASKS + 1, -1 do
			found[k] = nil
		end
		out[#out + 1] = { x0 = x0, y0 = y0, x1 = x1, y1 = y1, holes = found }
	elseif w >= h then
		local mid = x0 + math.floor(w / 2)
		splitForMasks(holes, x0, y0, mid, y1, out)
		splitForMasks(holes, mid, y0, x1, y1, out)
	else
		local mid = y0 + math.floor(h / 2)
		splitForMasks(holes, x0, y0, x1, mid, out)
		splitForMasks(holes, x0, mid, x1, y1, out)
	end
	return out
end

-- The rectangles strips are cut from: the whole picture for the ghost, otherwise each piece's cell
-- (in parts, so no strip needs too many hole masks) and its knobs' boxes. Masks round them off
-- into the piece's shape.
local function stripRegions(session, ghost)
	local d = session.decoder
	if ghost then
		return { { group = 1, x0 = 0, y0 = 0, x1 = d.w, y1 = d.h } }
	end
	local regions = {}
	for i = 1, #session.pieces do
		local s = ns:PieceShape(session, i)
		for _, part in ipairs(splitForMasks(s.holes, s.x0, s.y0, s.x1, s.y1)) do
			part.group = i
			regions[#regions + 1] = part
		end
		for k, knob in ipairs(s.knobs) do
			regions[#regions + 1] = { group = i, knob = k, x0 = knob.x0, y0 = knob.y0, x1 = knob.x1, y1 = knob.y1 }
		end
	end
	return regions
end

-- Cuts the regions into strips, grouped by piece (or all in group 1 for the ghost). Each strip is
-- { x0, y0, x1, y1, r, g, b, dr, dg, db, region }: the color at the first pixel's center and the
-- change per pixel. Returns nil as soon as the cut needs more than `budget` strips.
local function cutStrips(session, step, tolerance, budget, regions)
	local d = session.decoder
	local w, pixels, palette = d.w, d.pixels, d.palette
	local groups, count = {}, 0
	local above, row = {}, {}
	step = math.max(step, ns.LEVEL_STEPS[d.level])
	for _, region in ipairs(regions) do
		local list = groups[region.group]
		if not list then
			list = {}
			groups[region.group] = list
		end
		wipe(above)
		for y = region.y0, region.y1 - 1 do
			local base = (y - y % step) * w
			local x = region.x0
			while x < region.x1 do
				local first = palette[pixels[base + x - x % step]]
				local r, g, b = first[1], first[2], first[3]
				local lowR, highR, lowG, highG, lowB, highB = -1, 1, -1, 1, -1, 1
				local x1 = x + 1
				while x1 < region.x1 and x1 - x < MAX_STRIP do
					local c = palette[pixels[base + x1 - x1 % step]]
					local dist = x1 - x
					local nlR, nhR = math.max(lowR, (c[1] - tolerance - r) / dist), math.min(highR, (c[1] + tolerance - r) / dist)
					local nlG, nhG = math.max(lowG, (c[2] - tolerance - g) / dist), math.min(highG, (c[2] + tolerance - g) / dist)
					local nlB, nhB = math.max(lowB, (c[3] - tolerance - b) / dist), math.min(highB, (c[3] + tolerance - b) / dist)
					if nlR > nhR or nlG > nhG or nlB > nhB then
						break
					end
					lowR, highR, lowG, highG, lowB, highB = nlR, nhR, nlG, nhG, nlB, nhB
					x1 = x1 + 1
				end
				local dr, dg, db = 0, 0, 0
				if x1 - x > 1 then
					local last = palette[pixels[base + (x1 - 1) - (x1 - 1) % step]]
					local span = x1 - x - 1
					dr = clamp((last[1] - r) / span, lowR, highR)
					dg = clamp((last[2] - g) / span, lowG, highG)
					db = clamp((last[3] - b) / span, lowB, highB)
				end
				local key = format("%d:%d:%.3f:%.3f:%.3f:%.4f:%.4f:%.4f", x, x1, r, g, b, dr, dg, db)
				local strip = above[key]
				if strip then
					strip[4] = y + 1
				else
					count = count + 1
					if count > budget then
						return nil
					end
					strip = { x, y, x1, y + 1, r, g, b, dr, dg, db, region }
					list[#list + 1] = strip
				end
				row[key] = strip
				x = x1
			end
			above, row = row, above
			wipe(row)
		end
	end
	return groups, count
end

-- Average color error of a cut against the picture that has arrived so far.
local function cutError(session, groups)
	local d = session.decoder
	local w, pixels, palette = d.w, d.pixels, d.palette
	local level = ns.LEVEL_STEPS[d.level]
	local total = 0
	for _, list in pairs(groups) do
		for _, strip in ipairs(list) do
			local x0, y0, x1, y1, r, g, b, dr, dg, db = unpack(strip)
			for y = y0, y1 - 1 do
				local base = (y - y % level) * w
				for x = x0, x1 - 1 do
					local c, t = palette[pixels[base + x - x % level]], x - x0
					total = total + math.abs(r + dr * t - c[1]) + math.abs(g + dg * t - c[2]) + math.abs(b + db * t - c[3])
				end
			end
		end
	end
	return total
end

local function chooseCut(session, budget, ghost)
	local key = format("%s:%d:%d", ghost and "ghost" or "pieces", session.decoder.level, budget)
	session.cuts = session.cuts or {}
	if session.cuts[key] then
		return session.cuts[key]
	end
	local regions = stripRegions(session, ghost)
	local best, bestError, worse = nil, math.huge, 0
	for _, step in ipairs(STEPS) do
		for _, tolerance in ipairs(TOLERANCES) do
			local groups = cutStrips(session, step, tolerance, budget, regions)
			if groups then
				local err = cutError(session, groups)
				if err < bestError then
					best, bestError, worse = groups, err, 0
				else
					worse = worse + 1
				end
				break
			end
		end
		if worse >= 2 then
			break
		end
	end
	best = best or cutStrips(session, 32, 1, math.huge, regions)
	session.cuts[key] = best
	return best
end

-- Masks -----------------------------------------------------------------------------
-- Knob masks keep only a circle and hole masks cut one out, so piece edges are smooth curves at
-- any size instead of following the picture's pixels.

local function pooledMask(frame, key, k, file, wrap)
	local pool = frame[key]
	if not pool then
		pool = {}
		frame[key] = pool
	end
	local mask = pool[k]
	if not mask then
		mask = frame:CreateMaskTexture()
		mask:SetTexture(MEDIA .. file, wrap, wrap)
		pool[k] = mask
	end
	return mask
end

-- (x, y) is the circle's center in board units from the frame's top left corner.
local function placeCircle(mask, frame, x, y, radius)
	local size = math.max(radius, 0.5) * 2 * MASK_SCALE
	mask:ClearAllPoints()
	mask:SetPoint("CENTER", frame, "TOPLEFT", x, -y)
	mask:SetSize(size, size)
end

local function setMasks(tex, masks)
	local current = tex.masks
	if not current then
		current = {}
		tex.masks = current
	end
	for k = #current, 1, -1 do
		tex:RemoveMaskTexture(current[k])
		current[k] = nil
	end
	for k, mask in ipairs(masks) do
		tex:AddMaskTexture(mask)
		current[k] = mask
	end
end

local leftColor, rightColor
local stripMasks = {}

-- Paints strips onto owner, whose top left corner is picture pixel (originX, originY).
local function drawStrips(owner, strips, originX, originY, scale)
	if not leftColor then
		leftColor, rightColor = CreateColor(0, 0, 0, 1), CreateColor(0, 0, 0, 1)
	end
	local shape = owner.shape
	for k, strip in ipairs(strips) do
		local x0, y0, x1, y1, r, g, b, dr, dg, db, region = unpack(strip)
		local tex = pooled(owner, "textures", k)
		local far = x1 - x0 - 0.5
		tex:SetColorTexture(1, 1, 1)
		leftColor:SetRGB(clamp(r - dr / 2, 0, 1), clamp(g - dg / 2, 0, 1), clamp(b - db / 2, 0, 1))
		rightColor:SetRGB(clamp(r + dr * far, 0, 1), clamp(g + dg * far, 0, 1), clamp(b + db * far, 0, 1))
		tex:SetGradient("HORIZONTAL", leftColor, rightColor)
		place(tex, x0 - originX, y0 - originY, x1 - x0, y1 - y0, scale)
		wipe(stripMasks)
		if shape and region.knob then
			stripMasks[1] = owner.knobMasks[region.knob]
		elseif shape then
			for _, h in ipairs(region.holes) do
				local hole = shape.holes[h]
				if x0 < hole.cx + hole.r and x1 > hole.cx - hole.r and y0 < hole.cy + hole.r and y1 > hole.cy - hole.r then
					stripMasks[#stripMasks + 1] = owner.holeMasks[h]
				end
			end
		end
		setMasks(tex, stripMasks)
	end
	hideUnused(owner, "textures", #strips)
	return #strips
end

-- Places a piece's masks and draws its outline: the same shape grown by EDGE_WIDTH, behind it.
local function drawShape(frame, shape, scale)
	local ox, oy = frame.x0, frame.y0
	local holeEdges, used = {}, 0
	for k, hole in ipairs(shape.holes) do
		local x, y, r = (hole.cx - ox) * scale, (hole.cy - oy) * scale, hole.r * scale
		placeCircle(pooledMask(frame, "holeMasks", k, "Hole", "CLAMP"), frame, x, y, r - SEAM)
		holeEdges[k] = pooledMask(frame, "holeEdgeMasks", k, "Hole", "CLAMP")
		placeCircle(holeEdges[k], frame, x, y, r - EDGE_WIDTH)
	end
	for _, part in ipairs(splitForMasks(shape.holes, shape.x0, shape.y0, shape.x1, shape.y1)) do
		local masks = {}
		for k, h in ipairs(part.holes) do
			masks[k] = holeEdges[h]
		end
		used = used + 1
		local body = pooled(frame, "outline", used, "BACKGROUND")
		place(body, part.x0 - ox, part.y0 - oy, part.x1 - part.x0, part.y1 - part.y0, scale)
		setMasks(body, masks)
	end
	-- The band outside the cell. Where a hole crosses an edge, a wider circle around it cuts the
	-- band exactly as wide as the hole is at that edge, so the hole stays open.
	local left, top = (shape.x0 - ox) * scale, (shape.y0 - oy) * scale
	local right, bottom = (shape.x1 - ox) * scale, (shape.y1 - oy) * scale
	local e = EDGE_WIDTH
	local bands = {
		{ left - e, top - e, right + e, top, axis = "y", edge = top },
		{ left - e, bottom, right + e, bottom + e, axis = "y", edge = bottom },
		{ left - e, top, left, bottom, axis = "x", edge = left },
		{ right, top, right + e, bottom, axis = "x", edge = right },
	}
	for b, band in ipairs(bands) do
		local masks = {}
		for k, hole in ipairs(shape.holes) do
			local x, y, r = (hole.cx - ox) * scale, (hole.cy - oy) * scale, hole.r * scale - SEAM
			local d = math.abs((band.axis == "x" and x or y) - band.edge)
			if d < r and #masks < MAX_MASKS then
				local mask = pooledMask(frame, "bandMasks", (b - 1) * MAX_MASKS + #masks + 1, "Hole", "CLAMP")
				placeCircle(mask, frame, x, y, math.sqrt(r * r + e * (2 * d + e)))
				masks[#masks + 1] = mask
			end
		end
		used = used + 1
		local tex = pooled(frame, "outline", used, "BACKGROUND")
		place(tex, band[1], band[2], band[3] - band[1], band[4] - band[2], 1)
		setMasks(tex, masks)
	end
	for k, knob in ipairs(shape.knobs) do
		local x, y, r = (knob.cx - ox) * scale, (knob.cy - oy) * scale, knob.r * scale
		placeCircle(pooledMask(frame, "knobMasks", k, "Knob", "CLAMPTOBLACKADDITIVE"), frame, x, y, r)
		local edgeMask = pooledMask(frame, "knobEdgeMasks", k, "Knob", "CLAMPTOBLACKADDITIVE")
		placeCircle(edgeMask, frame, x, y, r + EDGE_WIDTH)
		-- Only the part past the grown cell, which the body outline already covers.
		local reach = r + EDGE_WIDTH
		local x0, y0, x1, y1 = x - reach, y - reach, x + reach, y + reach
		local edgeX, edgeY = (knob.edge - ox) * scale, (knob.edge - oy) * scale
		if knob.dx > 0 then x0 = edgeX + EDGE_WIDTH elseif knob.dx < 0 then x1 = edgeX - EDGE_WIDTH end
		if knob.dy > 0 then y0 = edgeY + EDGE_WIDTH elseif knob.dy < 0 then y1 = edgeY - EDGE_WIDTH end
		used = used + 1
		local tex = pooled(frame, "outline", used, "BACKGROUND")
		place(tex, x0, y0, x1 - x0, y1 - y0, 1)
		setMasks(tex, { edgeMask })
	end
	hideUnused(frame, "outline", used)
	frame.outlineCount = used
	frame.textureCount = used + 2 * (#shape.knobs + #shape.holes)
end

local function clearRegion(owner)
	hideUnused(owner, "textures", 0)
end

-- Even within the budget, thousands of textures are painted a few jobs per frame.
local function renderSome()
	local budget = TEXTURES_PER_FRAME
	while budget > 0 and #renderQueue > 0 do
		local job = table.remove(renderQueue, 1)
		budget = budget - drawStrips(job.owner, job.strips, job.x0, job.y0, pixelScale)
	end
end

-- View ----------------------------------------------------------------------------
-- The board is drawn once at a fixed size and scaled to fit the viewport, times the zoom. The pan
-- is the canvas center's offset from the viewport center, in viewport units.

local view = { zoom = 1, x = 0, y = 0 }
local pan

local function clampPan(offset, size, room)
	if size <= room then
		return 0
	end
	local limit = (size - room) / 2
	return clamp(offset, -limit, limit)
end

local function applyView()
	local vw, vh = viewport:GetSize()
	if not (view.session and vw and vw > 0 and vh > 0) then
		return
	end
	local scale = math.min(vw / boardW, vh / boardH) * view.zoom
	view.x = clampPan(view.x, boardW * scale, vw)
	view.y = clampPan(view.y, boardH * scale, vh)
	canvas:SetScale(scale)
	canvas:ClearAllPoints()
	canvas:SetPoint("CENTER", viewport, "CENTER", view.x / scale, view.y / scale)
end

local function viewportCursor()
	local x, y = GetCursorPosition()
	local scale = viewport:GetEffectiveScale()
	local vw, vh = viewport:GetSize()
	return x / scale - viewport:GetLeft() - vw / 2, y / scale - viewport:GetBottom() - vh / 2
end

local function zoomAt(delta)
	local zoom = clamp(view.zoom * ZOOM_STEP ^ delta, 1, MAX_ZOOM)
	local mx, my = viewportCursor()
	local ratio = zoom / view.zoom
	view.x, view.y = mx - (mx - view.x) * ratio, my - (my - view.y) * ratio
	view.zoom = zoom
	applyView()
end

local function updatePan()
	if not IsMouseButtonDown("RightButton") then
		pan = nil
		viewport:SetScript("OnUpdate", nil)
		return
	end
	local x, y = viewportCursor()
	view.x, view.y = pan.x + x - pan.cx, pan.y + y - pan.cy
	applyView()
end

local function startPan()
	local x, y = viewportCursor()
	pan = { cx = x, cy = y, x = view.x, y = view.y }
	viewport:SetScript("OnUpdate", updatePan)
end

-- Pieces --------------------------------------------------------------------------

local function nextLevel()
	topLevel = topLevel + 1
	if topLevel > 5000 then
		topLevel = 1
	end
	return canvas:GetFrameLevel() + 10 + topLevel
end

local function setOutline(frame, color)
	for k = 1, frame.outlineCount or 0 do
		local tex = frame.outline[k]
		if color then
			tex:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
		end
		tex:SetShown(color ~= nil)
	end
end

local function cursorPosition()
	local x, y = GetCursorPosition()
	local scale = canvas:GetEffectiveScale()
	return (x / scale - canvas:GetLeft()) / boardW, (canvas:GetTop() - y / scale) / boardH
end

local function placeFrame(frame, fx, fy)
	frame.fx, frame.fy = fx, fy
	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", canvas, "TOPLEFT", fx * boardW, -fy * boardH)
end

-- Piece frames are rectangles, but a click only counts inside a piece's shape.
local function pieceAtCursor(session)
	local cx, cy = cursorPosition()
	local best
	for i, frame in ipairs(pieceFrames) do
		local piece = session.pieces[i]
		if frame:IsShown() and piece and not piece.placed then
			local x = frame.x0 + (cx - frame.fx) * boardW / pixelScale
			local y = frame.y0 + (cy - frame.fy) * boardH / pixelScale
			if ns:PieceContains(session, i, x, y)
				and (not best or frame:GetFrameLevel() > best:GetFrameLevel()) then
				best = frame
			end
		end
	end
	return best
end

-- Dragging one piece drags its whole group. Members sit at fixed offsets from the dragged piece,
-- and the group's bounding box stays on the board.
local function beginDrag(frame)
	local session = ns.active
	local piece = session and session.pieces[frame.index]
	if not piece or piece.placed or ns:IsHeldByOther(piece) then
		return
	end
	local hx, hy = ns:HomePosition(session, frame.index)
	local cx, cy = cursorPosition()
	drag = { session = session, frame = frame, dx = cx - piece.x, dy = cy - piece.y, sentAt = GetTime(),
		members = {}, inGroup = {}, x0 = 0, y0 = 0, x1 = 1, y1 = 1 }
	for _, j in ipairs(ns:GroupMembers(session, frame.index)) do
		local member = pieceFrames[j]
		local jx, jy = ns:HomePosition(session, j)
		local ox, oy = jx - hx, jy - hy
		drag.members[#drag.members + 1] = { frame = member, ox = ox, oy = oy }
		drag.inGroup[j] = true
		drag.x0, drag.y0 = math.max(drag.x0, -ox), math.max(drag.y0, -oy)
		drag.x1, drag.y1 = math.min(drag.x1, 1 - ox - member.fw), math.min(drag.y1, 1 - oy - member.fh)
		member:SetFrameLevel(nextLevel())
	end
	ns:MovePiece(session, frame.index, piece.x, piece.y, "d")
end

local function dragTarget()
	local cx, cy = cursorPosition()
	return clamp(cx - drag.dx, drag.x0, drag.x1), clamp(cy - drag.dy, drag.y0, drag.y1)
end

local function placeDragged(fx, fy)
	for _, member in ipairs(drag.members) do
		placeFrame(member.frame, fx + member.ox, fy + member.oy)
	end
end

local function endDrag()
	if not drag then
		return
	end
	local session, index = drag.session, drag.frame.index
	local fx, fy = dragTarget()
	local x0, y0, x1, y1 = drag.x0, drag.y0, drag.x1, drag.y1
	drag = nil
	if ns.active ~= session then
		return
	end
	if ns:IsNearHome(session, index, fx, fy) then
		ns:MovePiece(session, index, fx, fy, "p")
		ns:PlaySound("IG_ABILITY_ICON_DROP")
		return
	end
	local neighbor, sx, sy = ns:FindSnap(session, index, fx, fy)
	if neighbor and sx >= x0 and sx <= x1 and sy >= y0 and sy <= y1 then
		ns:MovePiece(session, index, sx, sy, "r")
		ns:LinkPieces(session, index, neighbor)
		ns:PlaySound("IG_ABILITY_ICON_DROP")
	else
		ns:MovePiece(session, index, fx, fy, "r")
	end
end

function ns:IsDragging(session, i)
	return drag ~= nil and drag.session == session and drag.inGroup[i] == true
end

function ns:CancelDrag()
	drag = nil
end

local function createPieceFrame()
	local frame = CreateFrame("Frame", nil, canvas)
	frame:Hide()
	frame:EnableMouse(true)
	frame.holder = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
	frame.holder:SetPoint("BOTTOM", frame, "TOP", 0, 1)
	frame:SetScript("OnMouseDown", function(_, button)
		if button == "RightButton" then
			startPan()
			return
		end
		local target = button == "LeftButton" and viewport:IsMouseOver() and ns.active and pieceAtCursor(ns.active)
		if target then
			beginDrag(target)
		end
	end)
	frame:SetScript("OnMouseUp", function(_, button)
		if button == "LeftButton" then
			endDrag()
		end
	end)
	return frame
end

local function updatePieceState(frame, piece)
	if piece.placed then
		frame:EnableMouse(false)
		frame:SetFrameLevel(canvas:GetFrameLevel() + 3)
		setOutline(frame, nil)
		frame.holder:SetText("")
		return
	end
	frame:EnableMouse(true)
	if ns:IsHeldByOther(piece) then
		setOutline(frame, HELD_BY_OTHER)
		frame.holder:SetText(ns:ShortName(piece.holder))
	elseif drag and drag.inGroup[frame.index] then
		setOutline(frame, HELD_BY_ME)
		frame.holder:SetText("")
	else
		setOutline(frame, EDGE)
		frame.holder:SetText("")
	end
end

local function updateStatus()
	local session = ns.active
	if not (window and session) then
		return
	end
	local decoder = session.decoder
	local total = session.pieces and #session.pieces or 0
	local players = 0
	for _ in pairs(session.players) do
		players = players + 1
	end
	local text = format("Placed |cffffffff%d / %d|r     Puzzlers |cffffffff%d|r     Host |cffffffff%s|r",
		session.placedCount, total, players, ns:ShortName(session.master))
	if not decoder:IsComplete() then
		text = text .. format("     Picture |cffffffff%d%%|r", math.floor(decoder:Progress() * 100))
	end
	window.status:SetText(text)
	window.loading:SetShown(decoder.level == 0)
	window.loading:SetFormattedText("Receiving the picture from %s...  %d%%", ns:ShortName(session.master),
		math.floor(decoder:Progress() * 100))
	window.endButton:SetShown(session.isMaster)
	local complete = ns:IsComplete(session)
	window.banner:SetShown(complete)
	if complete then
		window.banner.text:SetText(ns:CompletionText(session))
	end
end

local function layout()
	local session = ns.active
	local decoder = session.decoder
	for _, frame in ipairs(pieceFrames) do
		frame:Hide()
	end
	window.ghost:Hide()
	window.target:Hide()
	wipe(renderQueue)
	if decoder.level == 0 or not session.pieces then
		updateStatus()
		return
	end
	local pw, ph = ns:PlaySize(session)
	pixelScale = math.min(CANVAS_WIDTH / pw, CANVAS_HEIGHT / ph)
	boardW, boardH = pw * pixelScale, ph * pixelScale
	canvas:SetSize(boardW, boardH)
	if view.session ~= session then
		view.session, view.zoom, view.x, view.y = session, 1, 0, 0
	end
	applyView()

	local target = window.target
	target:ClearAllPoints()
	target:SetPoint("TOPLEFT", canvas, "TOPLEFT", decoder.w * ns.MARGIN_X * pixelScale, -decoder.h * ns.MARGIN_Y * pixelScale)
	target:SetSize(decoder.w * pixelScale, decoder.h * pixelScale)
	target:Show()
	if window.ghost.session ~= session then
		window.ghost.session = session
		clearRegion(window.ghost)
	end
	window.ghost:SetShown(session.ghost)

	for i, piece in ipairs(session.pieces) do
		local frame = pieceFrames[i] or createPieceFrame()
		pieceFrames[i] = frame
		frame.index = i
		local x0, y0, x1, y1 = ns:PieceRect(session, i)
		frame.x0, frame.y0, frame.x1, frame.y1 = x0, y0, x1, y1
		frame.fw, frame.fh = (x1 - x0) / pw, (y1 - y0) / ph
		frame:SetSize((x1 - x0) * pixelScale, (y1 - y0) * pixelScale)
		if frame.session ~= session then
			frame.shape = ns:PieceShape(session, i)
			clearRegion(frame)
			drawShape(frame, frame.shape, pixelScale)
			frame.session = session
		end
		placeFrame(frame, piece.x, piece.y)
		if not piece.placed then
			frame:SetFrameLevel(nextLevel())
		end
		updatePieceState(frame, piece)
		frame:Show()
	end
	local budget = BOARD_TEXTURES
	for i = 1, #session.pieces do
		budget = budget - pieceFrames[i].textureCount
	end
	if session.ghost then
		local strips = chooseCut(session, GHOST_TEXTURES, true)
		tinsert(renderQueue, { owner = window.ghost, strips = strips[1] or {}, x0 = 0, y0 = 0 })
		budget = budget - #(strips[1] or {})
	end
	local groups = chooseCut(session, budget)
	for i, frame in ipairs(pieceFrames) do
		if i <= #session.pieces then
			tinsert(renderQueue, { owner = frame, strips = groups[i] or {}, x0 = frame.x0, y0 = frame.y0 })
		end
	end
	renderSome()
	updateStatus()
end

local function onUpdate(_, elapsed)
	local session = ns.active
	if not session or not session.pieces then
		return
	end
	if #renderQueue > 0 then
		renderSome()
	end
	if drag then
		local fx, fy = dragTarget()
		placeDragged(fx, fy)
		if GetTime() - drag.sentAt >= SEND_INTERVAL then
			drag.sentAt = GetTime()
			ns:MovePiece(session, drag.frame.index, fx, fy, "d")
		end
	end
	local t = math.min(1, elapsed * SETTLE_SPEED)
	for i, piece in ipairs(session.pieces) do
		local frame = pieceFrames[i]
		if frame and frame:IsShown() and not (drag and drag.inGroup[i]) then
			local dx, dy = piece.x - frame.fx, piece.y - frame.fy
			if dx ~= 0 or dy ~= 0 then
				if math.abs(dx) * boardW < 0.5 and math.abs(dy) * boardH < 0.5 then
					placeFrame(frame, piece.x, piece.y)
				else
					placeFrame(frame, frame.fx + dx * t, frame.fy + dy * t)
				end
			end
		end
	end
end

-- Window --------------------------------------------------------------------------

local function createButton(parent, label, width, onClick)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width, 22)
	button:SetText(label)
	button:SetScript("OnClick", onClick)
	return button
end

local function createSizeGrip()
	if window.SetResizeBounds then
		window:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT)
	elseif window.SetMinResize then
		window:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
	end
	window:SetResizable(true)
	local grip = CreateFrame("Button", nil, window)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -4, 4)
	grip:SetFrameLevel(window:GetFrameLevel() + 10)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetScript("OnMouseDown", function(_, button)
		if button == "LeftButton" then
			grip.sizing = true
			window:StartSizing("BOTTOMRIGHT")
		end
	end)
	grip:SetScript("OnMouseUp", function()
		if grip.sizing then
			grip.sizing = nil
			window:StopMovingOrSizing()
			ns.db.width, ns.db.height = math.floor(window:GetWidth() + 0.5), math.floor(window:GetHeight() + 0.5)
		end
	end)
	grip:SetScript("OnHide", grip:GetScript("OnMouseUp"))
end

local function createWindow()
	window = CreateFrame("Frame", "TurkeyTickleUIPuzzleBoard", UIParent, "PortraitFrameTemplate")
	-- The gamepad interface's menus also close UISpecialFrames, from secure code.
	if not ns:GamepadUI() then
		tinsert(UISpecialFrames, "TurkeyTickleUIPuzzleBoard")
	end
	window:SetSize(math.max(MIN_WIDTH, ns.db.width or WINDOW_WIDTH), math.max(MIN_HEIGHT, ns.db.height or WINDOW_HEIGHT))
	window:SetPoint("CENTER")
	window:SetFrameStrata("HIGH")
	window:SetToplevel(true)
	window:SetClampedToScreen(true)
	window:SetMovable(true)
	window:EnableMouse(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStop", window.StopMovingOrSizing)
	createSizeGrip()
	if window.SetPortraitToAsset then
		window:SetPortraitToAsset("Interface\\Icons\\INV_Misc_Note_02")
	elseif window.GetPortrait and window:GetPortrait() then
		window:GetPortrait():SetTexture("Interface\\Icons\\INV_Misc_Note_02")
	end

	window.endButton = createButton(window, "End puzzle", 100, function()
		ns:EndSession()
	end)
	window.endButton:SetPoint("TOPRIGHT", -16, -32)
	local leave = createButton(window, "Leave", 80, function()
		ns:LeaveSession()
	end)
	leave:SetPoint("RIGHT", window.endButton, "LEFT", -4, 0)
	local host = createButton(window, "Host new", 90, function()
		ns:ShowHost()
	end)
	host:SetPoint("RIGHT", leave, "LEFT", -4, 0)

	local ghost = CreateFrame("CheckButton", nil, window, "UICheckButtonTemplate")
	ghost:SetSize(24, 24)
	ghost:SetPoint("TOPLEFT", 60, -31)
	ghost.label = ghost:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	ghost.label:SetPoint("LEFT", ghost, "RIGHT", 2, 1)
	ghost:SetScript("OnClick", function(self)
		if ns.active then
			ns:SetGhost(ns.active, self:GetChecked() and true or false)
		end
	end)
	window.ghostToggle = ghost

	local inset = CreateFrame("Frame", nil, window, "InsetFrameTemplate")
	inset:SetPoint("TOPLEFT", 12, -60)
	inset:SetPoint("BOTTOMRIGHT", -12, 36)
	inset:EnableMouse(true)
	-- Drags propagate up from the play area, so a click that misses a piece would move the window.
	window:SetScript("OnDragStart", function(self)
		if not inset:IsMouseOver() then
			self:StartMoving()
		end
	end)

	viewport = CreateFrame("Frame", nil, inset)
	viewport:SetPoint("TOPLEFT", 3, -3)
	viewport:SetPoint("BOTTOMRIGHT", -3, 3)
	viewport:SetClipsChildren(true)
	viewport:EnableMouse(true)
	viewport:EnableMouseWheel(true)
	viewport:SetScript("OnMouseWheel", function(_, delta)
		zoomAt(delta)
	end)
	viewport:SetScript("OnMouseDown", function(_, button)
		if button == "RightButton" then
			startPan()
		end
	end)
	viewport:SetScript("OnSizeChanged", applyView)

	canvas = CreateFrame("Frame", nil, viewport)
	canvas:SetPoint("CENTER")
	canvas:SetSize(CANVAS_WIDTH, CANVAS_HEIGHT)
	canvas:SetScript("OnUpdate", onUpdate)
	local background = canvas:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints()
	background:SetColorTexture(0.09, 0.075, 0.06)

	local target = CreateFrame("Frame", nil, canvas)
	target:SetFrameLevel(canvas:GetFrameLevel() + 1)
	local outline = target:CreateTexture(nil, "BACKGROUND")
	outline:SetPoint("TOPLEFT", -2, 2)
	outline:SetPoint("BOTTOMRIGHT", 2, -2)
	outline:SetColorTexture(0.55, 0.42, 0.2, 0.8)
	local fill = target:CreateTexture(nil, "BORDER")
	fill:SetAllPoints()
	fill:SetColorTexture(0.16, 0.14, 0.11)
	window.target = target

	window.ghost = CreateFrame("Frame", nil, target)
	window.ghost:SetAllPoints()
	window.ghost:SetFrameLevel(canvas:GetFrameLevel() + 2)
	window.ghost:SetAlpha(0.22)

	window.loading = viewport:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	window.loading:SetPoint("CENTER")

	window.status = window:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	window.status:SetPoint("BOTTOMLEFT", 18, 13)

	local banner = CreateFrame("Frame", nil, viewport, "BackdropTemplate")
	banner:SetSize(420, 110)
	banner:SetPoint("TOP", 0, -12)
	banner:SetFrameLevel(canvas:GetFrameLevel() + 6000)
	banner:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	banner:SetBackdropColor(0, 0, 0, 0.85)
	banner.title = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	banner.title:SetPoint("TOP", 0, -14)
	banner.title:SetText("Puzzle complete!")
	banner.text = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	banner.text:SetPoint("TOP", banner.title, "BOTTOM", 0, -10)
	banner.text:SetWidth(390)
	banner:EnableMouse(true)
	banner:SetScript("OnMouseDown", banner.Hide)
	window.banner = banner

	window:SetScript("OnHide", function()
		if drag then
			endDrag()
		end
	end)
end

function ns:ShowBoard()
	if not window then
		createWindow()
	end
	window:SetScale(self.db.scale / 100)
	window:Show()
	self:RefreshBoard()
end

function ns:HideBoard()
	if window then
		window:Hide()
	end
end

function ns:IsBoardShown()
	return window ~= nil and window:IsShown()
end

function ns:RefreshBoard()
	if not self:IsBoardShown() then
		return
	end
	window:SetScale(self.db.scale / 100)
	local session = self.active
	if not session then
		window:Hide()
		return
	end
	if window.SetTitle then
		window:SetTitle(session.title or "Jigsaw")
	end
	local toggle = window.ghostToggle
	toggle:SetChecked(session.ghost)
	toggle:SetEnabled(session.isMaster)
	toggle.label:SetFontObject(session.isMaster and "GameFontHighlightSmall" or "GameFontDisableSmall")
	toggle.label:SetText(session.isMaster and "Show the picture under the pieces"
		or "Show the picture under the pieces (the host decides)")
	layout()
end

-- Session callbacks ---------------------------------------------------------------

function ns:OnImageLevel(session)
	if session == self.active then
		self:RefreshBoard()
	end
end

function ns:OnStatusChanged(session)
	if session == self.active and self:IsBoardShown() then
		updateStatus()
	end
end

function ns:OnPieceChanged(session, i, fromRemote)
	if session ~= self.active or not self:IsBoardShown() then
		return
	end
	local frame = pieceFrames[i]
	local piece = session.pieces[i]
	if not frame or not frame:IsShown() then
		return
	end
	if fromRemote and not piece.placed then
		frame:SetFrameLevel(nextLevel())
	elseif not fromRemote and not (drag and drag.inGroup[i]) then
		placeFrame(frame, piece.x, piece.y)
	end
	updatePieceState(frame, piece)
	updateStatus()
end

function ns:CompletionText(session)
	local ranking = {}
	for name, count in pairs(session.placedBy) do
		ranking[#ranking + 1] = { name = name, count = count }
	end
	table.sort(ranking, function(a, b)
		return a.count > b.count or a.count == b.count and a.name < b.name
	end)
	local parts = {}
	for i = 1, math.min(5, #ranking) do
		parts[i] = format("%s |cffffffff%d|r", ranking[i].name, ranking[i].count)
	end
	if #parts == 0 then
		return format("%d pieces", #session.pieces)
	end
	return "Pieces placed:  " .. table.concat(parts, ",  ")
end

function ns:OnComplete(session, celebrate)
	if session.completeShown then
		return
	end
	session.completeShown = true
	if session == self.active then
		if celebrate then
			self:PlaySound("LEVELUP")
		end
		self:Print(format("|cffffd100%s|r is complete! %s", session.title, self:CompletionText(session)))
		updateStatus()
	end
end
