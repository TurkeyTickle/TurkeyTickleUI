local ADDON, ns = ...

-- Pictures are big for addon messages, so sends go through a queue that paces them.
-- The client throttles each prefix (a burst of 10, then about one a second), so sends
-- rotate across several prefixes. A shared bytes-per-second cap keeps the total under
-- what the server tolerates, the same budget ChatThrottleLib uses.
local PREFIXES = { "TTPuzzle1", "TTPuzzle2", "TTPuzzle3", "TTPuzzle4" }
local PREFIX_BURST = 10
local PREFIX_PER_SECOND = 1
local BYTES_PER_SECOND = 800
local BURST_BYTES = 2000
local MESSAGE_OVERHEAD = 40
local PUMP_INTERVAL = 0.1

ns.MAX_PAYLOAD = 240

local isPrefix = {}
for _, prefix in ipairs(PREFIXES) do
	isPrefix[prefix] = true
end

local Result = Enum and Enum.SendAddonMessageResult or {}
local SUCCESS = Result.Success or 0
local THROTTLED = {
	[Result.AddonMessageThrottle or 3] = true,
	[Result.ChannelThrottle or 8] = true,
}

local urgent, bulk = {}, {}
local pendingByKey = {}
local tokens = {}
local bytes = BURST_BYTES
local lastRefill
local nextPrefix = 1
local ticker

local function refill()
	local now = GetTime()
	local elapsed = now - (lastRefill or now)
	lastRefill = now
	bytes = math.min(BURST_BYTES, bytes + elapsed * BYTES_PER_SECOND)
	for _, prefix in ipairs(PREFIXES) do
		tokens[prefix] = math.min(PREFIX_BURST, (tokens[prefix] or PREFIX_BURST) + elapsed * PREFIX_PER_SECOND)
	end
end

local function pickPrefix()
	for i = 0, #PREFIXES - 1 do
		local index = (nextPrefix + i - 1) % #PREFIXES + 1
		local prefix = PREFIXES[index]
		if tokens[prefix] >= 1 then
			nextPrefix = index % #PREFIXES + 1
			return prefix
		end
	end
end

local function send(prefix, item)
	local ok, result = pcall(C_ChatInfo.SendAddonMessage, prefix, item.text, item.chatType, item.target)
	if not ok then
		return "error"
	end
	if result == nil or result == true or result == SUCCESS then
		return "sent"
	end
	return THROTTLED[result] and "throttled" or "error"
end

local function pump()
	refill()
	while true do
		local queue = #urgent > 0 and urgent or #bulk > 0 and bulk or nil
		if not queue then
			ticker:Cancel()
			ticker = nil
			return
		end
		local item = queue[1]
		local cost = #item.text + MESSAGE_OVERHEAD
		if bytes < cost then
			return
		end
		local prefix = pickPrefix()
		if not prefix then
			return
		end
		local status = send(prefix, item)
		if status == "throttled" then
			tokens[prefix] = 0
			return
		end
		table.remove(queue, 1)
		if item.key then
			pendingByKey[item.key] = nil
		end
		if status == "sent" then
			tokens[prefix] = tokens[prefix] - 1
			bytes = bytes - cost
		end
	end
end

-- chatType "GROUP" resolves to the raid or party at send time.
local function resolveChannel(chatType)
	if chatType ~= "GROUP" then
		return chatType
	end
	if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
		return "INSTANCE_CHAT"
	elseif IsInRaid() then
		return "RAID"
	elseif IsInGroup() then
		return "PARTY"
	end
end

function ns:CanSendTo(chatType)
	if chatType == "GUILD" then
		return IsInGuild() and true or false
	end
	return resolveChannel(chatType) ~= nil
end

-- Messages with the same key replace each other while queued, so a fast-moving piece
-- only ever has its latest position waiting to go out.
function ns:Send(text, chatType, target, opts)
	chatType = resolveChannel(chatType)
	if not chatType or not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then
		return false
	end
	local key = opts and opts.key
	if key and pendingByKey[key] then
		local item = pendingByKey[key]
		item.text, item.chatType, item.target = text, chatType, target
		return true
	end
	local item = { text = text, chatType = chatType, target = target, key = key }
	if key then
		pendingByKey[key] = item
	end
	tinsert(opts and opts.bulk and bulk or urgent, item)
	if not ticker then
		ticker = C_Timer.NewTicker(PUMP_INTERVAL, pump)
		pump()
	end
	return true
end

function ns:QueuedBulk()
	return #bulk
end

function ns:EstimateSendSeconds(chars)
	local messages = math.ceil(chars / self.MAX_PAYLOAD)
	local byBytes = math.max(0, chars + messages * MESSAGE_OVERHEAD - BURST_BYTES) / BYTES_PER_SECOND
	local byPrefix = math.max(0, messages - PREFIX_BURST * #PREFIXES) / (PREFIX_PER_SECOND * #PREFIXES)
	return math.max(byBytes, byPrefix)
end

function ns:FormatDuration(seconds)
	seconds = math.ceil(seconds)
	if seconds < 60 then
		return format("%d seconds", math.max(1, seconds))
	end
	return format("%d min %d s", math.floor(seconds / 60), seconds % 60)
end

function ns:InitComm()
	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
		for _, prefix in ipairs(PREFIXES) do
			C_ChatInfo.RegisterAddonMessagePrefix(prefix)
		end
	end
end

function ns.handlers.CHAT_MSG_ADDON(prefix, text, channel, sender)
	if not isPrefix[prefix] or not sender or ns:IsMe(sender) then
		return
	end
	ns:OnMessage(text, channel, ns:Canonical(sender))
end
