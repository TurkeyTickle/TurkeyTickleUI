local ADDON, ns = ...

local EDGE_PADDING = 10
local LOADING_COLOR = { 0.4, 0.7, 1.0 }
local READY_COLOR = { 1.0, 0.82, 0.0 }

local button
local refreshPending

-- The puzzle the button is about: newest one someone else is hosting that you haven't opened.
local function pendingSession()
	local best
	for _, session in pairs(ns.sessions) do
		if session ~= ns.active and not session.isMaster and (not best or session.created > best.created) then
			best = session
		end
	end
	return best
end

local function hostedSession()
	for _, session in pairs(ns.sessions) do
		if session.isMaster then
			return session
		end
	end
end

local function sendProgress(session)
	local chunks = session.chunkCount or 0
	if chunks == 0 then
		return 1
	end
	return 1 - math.min(ns:QueuedBulk(), chunks) / chunks
end

local function position()
	local angle = math.rad(ns.db.minimapAngle)
	local radius = Minimap:GetWidth() / 2 + EDGE_PADDING
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function followCursor()
	local mx, my = Minimap:GetCenter()
	local scale = Minimap:GetEffectiveScale()
	local cx, cy = GetCursorPosition()
	ns.db.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx)) % 360
	position()
end

local function showTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:SetText("Turkey Tickle UI: Puzzle", 1, 1, 1)
	local any = false
	for _, session in pairs(ns.sessions) do
		any = true
		local state
		if session.isMaster then
			local sent = sendProgress(session)
			state = sent < 1 and format("|cff66b3ffsending %d%%|r", math.floor(sent * 100)) or "|cff40ff40you're hosting|r"
		elseif not session.decoder:IsComplete() then
			state = format("|cff66b3ffloading %d%%|r", math.floor(session.decoder:Progress() * 100))
		elseif session == ns.active then
			state = format("|cff40ff40playing, %d/%d placed|r", session.placedCount, #session.pieces)
		else
			state = "|cffffd100ready to play!|r"
		end
		GameTooltip:AddDoubleLine(format("%s |cff9d9d9d(%s)|r", session.title or "?", ns:ShortName(session.master)), state, 1, 0.82, 0)
	end
	if not any then
		GameTooltip:AddLine("No puzzles right now.", 0.7, 0.7, 0.7)
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("|cffffffffClick|r to open the puzzle", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("|cffffffffRight-click|r to host a puzzle", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("|cffffffffDrag|r to move this button", 0.8, 0.8, 0.8)
	GameTooltip:Show()
end

local function createButton()
	button = CreateFrame("Button", "TurkeyTickleUIPuzzleMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetSize(20, 20)
	background:SetPoint("TOPLEFT", 7, -5)
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	button.icon = button:CreateTexture(nil, "ARTWORK")
	button.icon:SetSize(17, 17)
	button.icon:SetPoint("TOPLEFT", 7, -6)
	button.icon:SetTexture(ns.ICON_SMALL)
	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

	button.glow = button:CreateTexture(nil, "OVERLAY", nil, 1)
	button.glow:SetSize(58, 58)
	button.glow:SetPoint("CENTER", button.icon)
	button.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	button.glow:SetBlendMode("ADD")
	button.glow:Hide()
	local pulse = button.glow:CreateAnimationGroup()
	pulse:SetLooping("BOUNCE")
	local fade = pulse:CreateAnimation("Alpha")
	fade:SetFromAlpha(1)
	fade:SetToAlpha(0.15)
	fade:SetDuration(0.7)
	button.pulse = pulse

	button.label = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	button.label:SetPoint("BOTTOM", button.icon, "BOTTOM", 0, -6)

	button:SetScript("OnClick", function(_, mouse)
		if mouse == "RightButton" then
			ns:ShowHost()
		elseif pendingSession() then
			ns:JoinSession(pendingSession())
		else
			ns:Toggle()
		end
	end)
	button:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", followCursor)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	button:SetScript("OnEnter", showTooltip)
	button:SetScript("OnLeave", GameTooltip_Hide)
	position()
end

local function setGlow(color)
	if not color then
		button.glow:Hide()
		button.pulse:Stop()
		return
	end
	button.glow:SetVertexColor(color[1], color[2], color[3])
	button.glow:Show()
	if not button.pulse:IsPlaying() then
		button.pulse:Play()
	end
end

function ns:UpdateMinimap()
	if not self.db.minimap then
		if button then
			button:Hide()
		end
		return
	end
	if not button then
		createButton()
	end
	button:Show()
	local pending, hosted = pendingSession(), hostedSession()
	if pending and not pending.decoder:IsComplete() then
		setGlow(LOADING_COLOR)
		button.label:SetFormattedText("%d%%", math.floor(pending.decoder:Progress() * 100))
	elseif pending then
		setGlow(READY_COLOR)
		button.label:SetText("|cffffd100Ready|r")
	elseif hosted and sendProgress(hosted) < 1 then
		setGlow(nil)
		button.label:SetFormattedText("%d%%", math.floor(sendProgress(hosted) * 100))
		-- Nothing reports the send queue draining, so check back while it does.
		if not refreshPending then
			refreshPending = true
			C_Timer.After(1, function()
				refreshPending = false
				ns:UpdateMinimap()
			end)
		end
	else
		setGlow(nil)
		button.label:SetText("")
	end
	if GameTooltip:GetOwner() == button then
		showTooltip(button)
	end
end
