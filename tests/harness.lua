-- Minimal fake WoW environment: every widget method is a no-op that returns a stub.
local function stub()
	local s = {}
	return setmetatable(s, {
		__index = function(t, k)
			local f = function(self, _, _, template)
				if k == "GetFont" then return "font", 10 end
				if k == "GetFrameLevel" or k == "GetWidth" then return 1 end
				if k == "IsShown" or k == "IsPlaying" or k == "IsForbidden" then return false end
				if k == "GetMinMaxValues" then return 0, 1 end
				if k == "GetScript" then return function() end end
				if k == "GetID" then return 1 end
				if k == "CreateFontString" then
					local fs = stub()
					local hasFont = template ~= nil
					fs.SetFont = function() hasFont = true end
					fs.SetFontObject = function() hasFont = true end
					local function check() if not hasFont then error("FontString: Font not set", 2) end end
					fs.SetText = check
					fs.SetFormattedText = check
					return fs
				end
				return stub()
			end
			rawset(t, k, f)
			return f
		end,
	})
end

local frames = {}
function CreateFrame(kind, name, parent, template)
	local f = stub()
	table.insert(frames, f)
	local scripts = {}
	f.SetScript = function(self, k, fn) scripts[k] = fn end
	f.GetScript = function(self, k) return scripts[k] or function() end end
	f.scripts = scripts
	return f
end
function Mixin(o, ...) for _, m in ipairs({...}) do for k, v in pairs(m) do o[k] = v end end return o end
function geterrorhandler() return function(e) print("LUA ERROR: " .. tostring(e)) print(debug.traceback()) end end
function issecretvalue() return false end
strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
tinsert = table.insert
format = string.format
SlashCmdList = {}
GameTooltip = stub()
GameTooltip_Hide = function() end
STANDARD_TEXT_FONT = "font"
RAID_CLASS_COLORS = { HUNTER = { r = 0.67, g = 0.83, b = 0.45 } }
SOUNDKIT = { RAID_WARNING = 8959 }
C_Timer = { After = function(_, fn) fn() end, NewTicker = function() return { Cancel = function() end } end }
C_AddOns = { GetAddOnMetadata = function() return "0.1.0" end }
C_Texture = { GetAtlasInfo = function() return nil end }
Settings = { RegisterCanvasLayoutCategory = function() return stub() end, RegisterAddOnCategory = function() end }
local nameplate = stub()
nameplate.UnitFrame = stub()
rawset(nameplate, "ForeverPlate", false)
rawset(nameplate, "namePlateUnitToken", "nameplate1")
rawset(nameplate.UnitFrame, "foreverPlatesHooked", false)
C_NamePlate = { GetNamePlateForUnit = function() return nameplate end, GetNamePlates = function() return { nameplate } end }
C_UnitAuras = { GetDebuffDataByIndex = function() return nil end }
function UnitIsUnit(a, b) return false end
function UnitCanAttack() return true end
function UnitName() return "Mob" end
function UnitLevel() return 10 end
function UnitClassification() return "elite" end
function UnitHealth() return 50 end
function UnitHealthMax() return 100 end
function UnitIsPlayer() return false end
function UnitIsFriend() return false end
function UnitAffectingCombat() return true end
function UnitExists() return true end
THREAT = { false, 1, 90, 120 }
function UnitDetailedThreatSituation() return unpack(THREAT) end
function UnitThreatSituation() return THREAT[2] end
function UnitReaction() return 2 end
function UnitClass() return "Hunter", "HUNTER" end
function UnitIsTapDenied() return false end
function GetCreatureDifficultyColor() return { r = 1, g = 1, b = 0 } end
C_PlayerInfo = { GetContentDifficultyCreatureForPlayer = function() return 2 end }
function GetDifficultyColor() return { r = 0.25, g = 0.75, b = 0.25 } end
function GetRaidTargetIndex() return nil end
function UnitCastingInfo() return nil end
function UnitChannelInfo() return nil end
function GetTime() return 100 end
function InCombatLockdown() return false end
function GetCVar() return "41" end
function SetCVar() end
function PlaySound(id) print("PlaySound", id) end

local ns = {}
for _, file in ipairs({ "Core.lua", "Plate.lua", "Config.lua" }) do
	local chunk = assert(loadfile(arg[1] .. "/" .. file))
	chunk("ForeverPlates", ns)
end

local driver = ns.driver
local fire = function(...) driver.scripts.OnEvent(driver, ...) end
fire("ADDON_LOADED", "ForeverPlates")
fire("PLAYER_ENTERING_WORLD")
fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
print("styled:", ns.plates.nameplate1 ~= nil)
fire("PLAYER_REGEN_DISABLED")
fire("UNIT_THREAT_LIST_UPDATE", "nameplate1")
THREAT = { true, 3, 100, 100 }
fire("UNIT_THREAT_LIST_UPDATE", "nameplate1")
fire("UNIT_HEALTH", "nameplate1")
fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
SlashCmdList.FOREVERPLATES("threat")
print("done")
