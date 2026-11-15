local ADDON, ns = ...

-- Image code format (tools/PuzzleImage writes the same thing):
--   "TTPZ1:" width(2) height(2) colors-1(1) palette(colors x 4) pixels
-- Numbers are base64 digits, most significant first. Each palette entry is a 24-bit RGB value.
-- Pixels are palette indices, one digit each, or "~" run color for run+3 repeats. They're
-- ordered coarse to fine (every 4th pixel, then every 2nd, then the rest) so a blurry
-- picture shows up after the first few messages and sharpens as the rest arrive.

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local RUN = "~"
local RUN_BYTE = RUN:byte()
local MIN_RUN = 3
local MAX_RUN = MIN_RUN + 63
local floor = math.floor

ns.CODE_TAG = "TTPZ1:"
ns.MIN_SIDE = 8
ns.MAX_SIDE = 320
ns.MAX_COLORS = 64
ns.LEVEL_STEPS = { 4, 2, 1 }

local digitValue, valueDigit = {}, {}
for i = 1, #ALPHABET do
	digitValue[ALPHABET:byte(i)] = i - 1
	valueDigit[i - 1] = ALPHABET:sub(i, i)
end

function ns:EncodeNumber(value, digits)
	local out = {}
	for i = digits, 1, -1 do
		out[i] = valueDigit[value % 64]
		value = floor(value / 64)
	end
	return table.concat(out)
end

function ns:DecodeNumber(text, pos, digits)
	local value = 0
	for i = pos, pos + digits - 1 do
		local digit = digitValue[text:byte(i) or -1]
		if not digit then
			return nil
		end
		value = value * 64 + digit
	end
	return value
end

-- Pixel indices (0-based, row-major) in send order, and where each level ends.
function ns:PixelOrder(w, h)
	local order, levelEnds = {}, {}
	local coarser
	for level, step in ipairs(self.LEVEL_STEPS) do
		for y = 0, h - 1, step do
			for x = 0, w - 1, step do
				if not coarser or x % coarser ~= 0 or y % coarser ~= 0 then
					order[#order + 1] = y * w + x
				end
			end
		end
		levelEnds[level] = #order
		coarser = step
	end
	return order, levelEnds
end

-- palette: { { r, g, b }, ... } with 0-255 channels. pixels: [y * w + x] = 0-based palette index.
function ns:EncodeImage(w, h, palette, pixels)
	local out = { self.CODE_TAG, self:EncodeNumber(w, 2), self:EncodeNumber(h, 2), valueDigit[#palette - 1] }
	for _, c in ipairs(palette) do
		out[#out + 1] = self:EncodeNumber(c[1] * 65536 + c[2] * 256 + c[3], 4)
	end
	local order = self:PixelOrder(w, h)
	local i = 1
	while i <= #order do
		local color = pixels[order[i]]
		local run = 1
		while i + run <= #order and run < MAX_RUN and pixels[order[i + run]] == color do
			run = run + 1
		end
		if run >= MIN_RUN then
			out[#out + 1] = RUN .. valueDigit[run - MIN_RUN] .. valueDigit[color]
		else
			run = 1
			out[#out + 1] = valueDigit[color]
		end
		i = i + run
	end
	return table.concat(out)
end

-- Decoder ---------------------------------------------------------------------
-- Fed the code in pieces as messages arrive; decodes as far as the text allows.

local Decoder = {}
Decoder.__index = Decoder

function ns:NewDecoder()
	return setmetatable({ text = "", pos = 1, decoded = 0, level = 0 }, Decoder)
end

-- Only the undecoded tail is kept, so big pictures don't rebuild the whole code per chunk.
function Decoder:Feed(text)
	if self.w then
		self.text = self.text:sub(self.pos) .. text
		self.pos = 1
	else
		self.text = self.text .. text
	end
	return self:Advance()
end

function Decoder:ReadHeader()
	local text, tagLen = self.text, #ns.CODE_TAG
	if #text < tagLen + 5 then
		return true
	end
	if text:sub(1, tagLen) ~= ns.CODE_TAG then
		return false, "That isn't a puzzle image code."
	end
	local w = ns:DecodeNumber(text, tagLen + 1, 2)
	local h = ns:DecodeNumber(text, tagLen + 3, 2)
	local colors = ns:DecodeNumber(text, tagLen + 5, 1)
	if not (w and h and colors) then
		return false, "The image code is damaged."
	end
	if w < ns.MIN_SIDE or h < ns.MIN_SIDE or w > ns.MAX_SIDE or h > ns.MAX_SIDE then
		return false, format("Pictures must be %d to %d pixels on each side.", ns.MIN_SIDE, ns.MAX_SIDE)
	end
	colors = colors + 1
	local paletteStart = tagLen + 6
	local pixelStart = paletteStart + colors * 4
	if #text < pixelStart - 1 then
		return true
	end
	local palette = {}
	for i = 0, colors - 1 do
		local v = ns:DecodeNumber(text, paletteStart + i * 4, 4)
		if not v then
			return false, "The image code is damaged."
		end
		palette[i] = { floor(v / 65536) / 255, floor(v / 256) % 256 / 255, v % 256 / 255 }
	end
	self.w, self.h, self.colors, self.palette = w, h, colors, palette
	self.order, self.levelEnds = ns:PixelOrder(w, h)
	self.total = #self.order
	self.pixels = {}
	self.pos = pixelStart
	return true
end

function Decoder:Advance()
	if self.failed then
		return false, self.failed
	end
	if not self.w then
		local ok, err = self:ReadHeader()
		if not ok then
			self.failed = err
			return false, err
		end
		if not self.w then
			return true
		end
	end
	local text, len = self.text, #self.text
	local pos, decoded, total, colors = self.pos, self.decoded, self.total, self.colors
	local pixels, order = self.pixels, self.order
	while pos <= len and decoded < total do
		local byte = text:byte(pos)
		local run, color = 1, nil
		if byte == RUN_BYTE then
			if pos + 2 > len then
				break
			end
			run = (digitValue[text:byte(pos + 1)] or -99) + MIN_RUN
			color = digitValue[text:byte(pos + 2)]
			pos = pos + 3
		else
			color = digitValue[byte]
			pos = pos + 1
		end
		if run < MIN_RUN and run ~= 1 or not color or color >= colors or decoded + run > total then
			self.failed = "The image code is damaged."
			return false, self.failed
		end
		for _ = 1, run do
			decoded = decoded + 1
			pixels[order[decoded]] = color
		end
	end
	self.pos, self.decoded = pos, decoded
	for level, last in ipairs(self.levelEnds) do
		if decoded >= last then
			self.level = level
		end
	end
	return true
end

function Decoder:IsComplete()
	return self.total ~= nil and self.decoded >= self.total
end

function Decoder:Progress()
	return self.total and self.decoded / self.total or 0
end

-- Palette index for (x, y) at the sharpest level that has fully arrived.
function Decoder:ColorAt(x, y)
	local step = ns.LEVEL_STEPS[self.level]
	return self.pixels[(y - y % step) * self.w + (x - x % step)]
end

-- Built-in picture so hosts can try the addon without the image tool -------------

function ns:SampleCode()
	local w, h = 128, 96
	local palette, lookup, pixels = {}, {}, {}
	local function color(r, g, b)
		r, g, b = floor(r / 16) * 16, floor(g / 16) * 16, floor(b / 16) * 16
		local key = r * 65536 + g * 256 + b
		if not lookup[key] then
			if #palette >= self.MAX_COLORS then
				return 0
			end
			palette[#palette + 1] = { r, g, b }
			lookup[key] = #palette - 1
		end
		return lookup[key]
	end
	local function mix(a, b, t)
		return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t
	end
	local skyTop, skyLow = { 40, 50, 140 }, { 250, 170, 90 }
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local c
			local far = 52 + 8 * math.sin(x / 11) + 4 * math.sin(x / 4 + 1)
			local near = 66 + 7 * math.sin(x / 17 + 2) + 3 * math.sin(x / 6)
			local sun = math.sqrt((x - 92) ^ 2 + (y - 30) ^ 2)
			local canopy = math.sqrt((x - 28) ^ 2 + ((y - 50) * 1.2) ^ 2)
			if y >= near then
				local t = (y - near) / (h - near)
				c = color(mix({ 70, 150, 50 }, { 20, 70, 30 }, t))
				if (x * 7 + y * 13) % 23 == 0 then
					c = color(240, 220, 80)
				end
			elseif canopy < 15 then
				c = color(mix({ 60, 140, 60 }, { 20, 80, 40 }, canopy / 15))
			elseif x >= 26 and x <= 30 and y >= 56 then
				c = color(100, 60, 30)
			elseif y >= far then
				c = color(mix({ 110, 80, 140 }, { 70, 60, 110 }, (y - far) / 20))
			elseif sun < 13 then
				c = color(255, 240, 150)
			elseif sun < 17 then
				c = color(255, 200, 110)
			else
				local t = y / 60
				c = color(mix(skyTop, skyLow, t < 1 and t or 1))
			end
			pixels[y * w + x] = c
		end
	end
	return self:EncodeImage(w, h, palette, pixels)
end
