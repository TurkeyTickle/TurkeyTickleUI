local _, ns = ...

local WIDTH, HEIGHT = 170, 62
local GRAPH_HEIGHT = 18
local ARROWS = {
	up = { "Interface\\Buttons\\Arrow-Up-Up", 0.25, 1, 0.25 },
	down = { "Interface\\Buttons\\Arrow-Down-Up", 1, 0.3, 0.3 },
}

local frame
local lines = {}

local function savePoint(self)
	local point, _, relativePoint, x, y = self:GetPoint()
	local saved = ns.db.point
	saved.point, saved.relativePoint, saved.x, saved.y = point, relativePoint, x, y
end

local function placeFrame()
	frame:ClearAllPoints()
	local saved = ns.db.point
	if saved.point then
		frame:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x, saved.y)
	else
		frame:SetPoint("TOP", UIParent, "TOP", 0, -120)
	end
end

local function showTooltip(self)
	local s = ns.session
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
	GameTooltip:SetText("XP per hour", 1, 0.82, 0)
	if s then
		GameTooltip:AddDoubleLine("XP this session", BreakUpLargeNumbers and BreakUpLargeNumbers(s.gained) or s.gained, 1, 1, 1, 1, 1, 1)
		GameTooltip:AddDoubleLine("Session length", ns:Duration(GetTime() - s.start), 1, 1, 1, 1, 1, 1)
		GameTooltip:AddDoubleLine("XP to level", BreakUpLargeNumbers and BreakUpLargeNumbers(math.max(0, s.lastMax - s.lastXP))
			or math.max(0, s.lastMax - s.lastXP), 1, 1, 1, 1, 1, 1)
		GameTooltip:AddLine(format("Rate over the last %d minutes; the line shows the last hour.", ns.db.windowMinutes), 0.7, 0.7, 0.7, true)
	end
	GameTooltip:AddLine(" ")
	if not ns.db.locked then
		GameTooltip:AddLine("Drag: move", 0.5, 0.8, 1)
	end
	GameTooltip:AddLine("Right-click: reset session", 0.5, 0.8, 1)
	GameTooltip:AddLine("/ttxp: hide", 0.5, 0.8, 1)
	GameTooltip:Show()
end

function ns:CreateDisplay()
	if frame then
		return
	end
	frame = CreateFrame("Frame", "TurkeyTickleUIXPFrame", UIParent, "BackdropTemplate")
	self.frame = frame
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8x8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	frame:SetBackdropColor(0, 0, 0, 0.6)
	frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.8)
	placeFrame()

	frame.rate = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	frame.rate:SetPoint("TOPLEFT", 9, -8)
	frame.arrow = frame:CreateTexture(nil, "OVERLAY")
	frame.arrow:SetSize(16, 16)
	frame.arrow:SetPoint("LEFT", frame.rate, "RIGHT", 2, 0)
	frame.arrow:SetDesaturated(true)
	frame.detail = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.detail:SetPoint("TOPLEFT", frame.rate, "BOTTOMLEFT", 0, -3)

	frame.graph = CreateFrame("Frame", nil, frame)
	frame.graph:SetPoint("BOTTOMLEFT", 9, 6)
	frame.graph:SetPoint("BOTTOMRIGHT", -9, 6)
	frame.graph:SetHeight(GRAPH_HEIGHT)

	frame:SetScript("OnDragStart", function(self)
		if not ns.db.locked then
			self:StartMoving()
		end
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		savePoint(self)
	end)
	frame:SetScript("OnMouseUp", function(self, button)
		if button == "RightButton" then
			ns:ResetSession()
			ns:Print("Session reset.")
			if GameTooltip:IsOwned(self) then
				showTooltip(self)
			end
		end
	end)
	frame:SetScript("OnEnter", showTooltip)
	frame:SetScript("OnLeave", GameTooltip_Hide)
end

function ns:ApplySettings()
	if not frame then
		return
	end
	frame:SetScale(self.db.scale / 100)
end

function ns:ResetPosition()
	wipe(self.db.point)
	if frame then
		placeFrame()
	end
end

local function drawSparkline(points)
	local graph = frame.graph
	local width, height = WIDTH - 18, GRAPH_HEIGHT
	local top = 0
	for _, value in ipairs(points) do
		top = math.max(top, value)
	end
	local segments = #points - 1
	for i = 1, math.max(segments, #lines) do
		local line = lines[i]
		if i <= segments and top > 0 then
			if not line then
				line = graph:CreateLine(nil, "ARTWORK")
				line:SetThickness(1.5)
				line:SetColorTexture(1, 0.82, 0, 0.9)
				lines[i] = line
			end
			line:SetStartPoint("BOTTOMLEFT", graph, (i - 1) / segments * width, points[i] / top * height)
			line:SetEndPoint("BOTTOMLEFT", graph, i / segments * width, points[i + 1] / top * height)
			line:Show()
		elseif line then
			line:Hide()
		end
	end
end

function ns:Refresh()
	if not frame then
		return
	end
	local want = self.db.shown and not self:AtMaxLevel()
	frame:SetShown(want)
	if not want then
		return
	end

	local recent, average = self:RecentRate(), self:AverageRate()
	frame.rate:SetText(recent and (self:ShortNumber(recent) .. "/hr") or "--/hr")

	local arrow = ARROWS[self:Trend()]
	if arrow then
		frame.arrow:SetTexture(arrow[1])
		frame.arrow:SetVertexColor(arrow[2], arrow[3], arrow[4])
		frame.arrow:Show()
	else
		frame.arrow:Hide()
	end

	local toLevel = self:TimeToLevel()
	local level = (self.session and self.session.lastLevel or UnitLevel("player")) + 1
	frame.detail:SetText(format("avg %s  ·  %s to %d", average and self:ShortNumber(average) or "--",
		toLevel and self:Duration(toLevel) or "--", level))

	drawSparkline(self:SparkPoints())
end
