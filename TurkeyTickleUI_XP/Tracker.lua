local _, ns = ...

ns.SAMPLE_SECONDS = 30
ns.SPARK_SECONDS = 60 * 60
local MIN_SECONDS = 60
local TREND_CHANGE = 0.05

-- The sparkline's oldest point looks back one rate window (30 minutes at most).
local KEEP_SECONDS = ns.SPARK_SECONDS + 30 * 60 + ns.SAMPLE_SECONDS

function ns:AtMaxLevel()
	if IsPlayerAtEffectiveMaxLevel then
		return IsPlayerAtEffectiveMaxLevel()
	end
	return (UnitXPMax("player") or 0) == 0
end

local function readXP()
	return UnitXP("player") or 0, UnitXPMax("player") or 0, UnitLevel("player") or 1
end

function ns:ResetSession()
	local xp, max, level = readXP()
	local now = GetTime()
	self.char.session = {
		start = now,
		gained = 0,
		samples = { { now, 0 } },
		lastXP = xp,
		lastMax = max,
		lastLevel = level,
	}
	self.session = self.char.session
	self:Refresh()
end

function ns:StartSession(isReload)
	if isReload and type(self.char.session) == "table" and self.char.session.samples then
		self.session = self.char.session
		self:RecordXP()
	else
		self:ResetSession()
	end
end

-- XP going down means the bar wrapped into a new level, even if UnitLevel hasn't caught up yet.
function ns:RecordXP()
	local s = self.session
	if not s then
		return
	end
	local xp, max, level = readXP()
	if level > s.lastLevel or xp < s.lastXP then
		s.gained = s.gained + math.max(0, s.lastMax - s.lastXP) + xp
		s.lastLevel = math.max(level, s.lastLevel + 1)
	else
		s.gained = s.gained + xp - s.lastXP
	end
	s.lastXP, s.lastMax = xp, max
end

function ns:Tick()
	local s = self.session
	if not s or self:AtMaxLevel() then
		return
	end
	local now = GetTime()
	tinsert(s.samples, { now, s.gained })
	while s.samples[2] and s.samples[2][1] <= now - KEEP_SECONDS do
		tremove(s.samples, 1)
	end
	self:Refresh()
end

-- The latest sample taken at or before t (the oldest one if none are).
local function sampleAt(s, t)
	local best = s.samples[1]
	for _, sample in ipairs(s.samples) do
		if sample[1] > t then
			break
		end
		best = sample
	end
	return best
end

local function rate(from, to)
	local seconds = to[1] - from[1]
	if seconds < MIN_SECONDS then
		return nil
	end
	return (to[2] - from[2]) / seconds * 3600
end

local function windowSeconds()
	return ns.db.windowMinutes * 60
end

function ns:RecentRate()
	local s = self.session
	if not s then
		return nil
	end
	local now = GetTime()
	return rate(sampleAt(s, now - windowSeconds()), { now, s.gained })
end

function ns:AverageRate()
	local s = self.session
	if not s then
		return nil
	end
	return rate({ s.start, 0 }, { GetTime(), s.gained })
end

-- "up", "down" or "flat" against the window before this one; nil until the session is two windows old.
function ns:Trend()
	local s = self.session
	local window = windowSeconds()
	local now = GetTime()
	if not s or now - s.start < window * 2 then
		return nil
	end
	local recent = self:RecentRate()
	local before = rate(sampleAt(s, now - window * 2), sampleAt(s, now - window))
	if not recent or not before then
		return nil
	end
	if before == 0 then
		return recent > 0 and "up" or "flat"
	end
	local change = (recent - before) / before
	if change > TREND_CHANGE then
		return "up"
	elseif change < -TREND_CHANGE then
		return "down"
	end
	return "flat"
end

-- Seconds to the next level at the recent rate, or the session average when nothing's come in lately.
function ns:TimeToLevel()
	local s = self.session
	if not s then
		return nil
	end
	local recent, average = self:RecentRate(), self:AverageRate()
	local perHour = recent and recent > 0 and recent or average
	if not perHour or perHour <= 0 then
		return nil
	end
	return math.max(0, s.lastMax - s.lastXP) / perHour * 3600
end

-- The recent rate as it stood at each sample over the last hour, oldest first.
function ns:SparkPoints()
	local s = self.session
	local points = {}
	if not s then
		return points
	end
	local now = GetTime()
	local window = windowSeconds()
	for _, sample in ipairs(s.samples) do
		if sample[1] >= now - self.SPARK_SECONDS and sample[1] < now then
			local value = rate(sampleAt(s, sample[1] - window), sample)
			if value then
				tinsert(points, value)
			end
		end
	end
	local recent = self:RecentRate()
	if recent then
		tinsert(points, recent)
	end
	return points
end

function ns:ShortNumber(n)
	if n >= 1e6 then
		return format("%.1fm", n / 1e6)
	elseif n >= 1e4 then
		return format("%.1fk", n / 1e3)
	elseif n >= 1e3 then
		return format("%.2fk", n / 1e3)
	end
	return format("%d", n)
end

function ns:Duration(seconds)
	local minutes = math.floor(seconds / 60 + 0.5)
	if minutes < 1 then
		return "<1m"
	elseif minutes < 60 then
		return minutes .. "m"
	end
	return format("%dh %dm", math.floor(minutes / 60), minutes % 60)
end
