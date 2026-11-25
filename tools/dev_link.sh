#!/bin/sh
# Links a "_Dev" copy of every module into the game's AddOns folder, so the repository can be run
# alongside the CurseForge install; enable one set or the other in the in-game AddOns list.
# Each copy is a folder under .dev/ of symlinks into the module plus a generated .toc, so Lua edits
# show up after a /reload. Run it again after changing any module's .toc, then restart the game.
#   tools/dev_link.sh [AddOns folder]
set -e
cd "$(dirname "$0")/.."
repo=$PWD
addons=${1:-${TTUI_ADDONS:-"$HOME/Games/battlenet/drive_c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns"}}
[ -d "$addons" ] || { echo "No AddOns folder at $addons" >&2; exit 1; }

dev=$repo/.dev
rm -rf "$dev"
mkdir -p "$dev"

modules=
interface=
for toc in TurkeyTickleUI_*/TurkeyTickleUI_*.toc; do
	module=${toc%%/*}
	[ "$toc" = "$module/$module.toc" ] || continue
	modules="$modules $module"
	[ -n "$interface" ] || interface=$(sed -n 's/^## Interface: //p' "$toc")

	target=$dev/${module}_Dev
	mkdir "$target"
	for path in "$module"/*; do
		case $path in *.toc) continue ;; esac
		ln -s "$repo/$path" "$target/"
	done
	sed -e 's/^## Title: /## Title: |cffff5555[DEV]|r /' \
		-e 's/^## Version: .*/## Version: dev/' \
		-e 's/^## Category: .*/## Category: Turkey Tickle UI (Dev)/' \
		-e 's/^## Group: .*/## Group: TurkeyTickleUI_Dev/' \
		-e "s/Interface\\\\AddOns\\\\$module\\\\/Interface\\\\AddOns\\\\${module}_Dev\\\\/" \
		"$toc" > "$target/${module}_Dev.toc"
done

# Both copies of a module share global names, so the second to load overwrites the first.
guard=$dev/TurkeyTickleUI_DevGuard
mkdir "$guard"
cat > "$guard/TurkeyTickleUI_DevGuard.toc" <<EOF
## Interface: $interface
## Title: |cffff5555[DEV]|r Turkey Tickle UI: Dev Guard
## Notes: Warns at login when a module's release and dev copies are both enabled.
## Version: dev
## Category: Turkey Tickle UI (Dev)
## Group: TurkeyTickleUI_Dev

DevGuard.lua
EOF
{
	echo "local MODULES = {"
	for module in $modules; do
		echo "	\"$module\","
	done
	echo "}"
	cat <<'EOF'

local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
	for _, name in ipairs(MODULES) do
		if isLoaded(name) and isLoaded(name .. "_Dev") then
			print("|cffff5555Turkey Tickle UI:|r " .. name .. " and " .. name
				.. "_Dev are both enabled. Disable one and reload.")
		end
	end
end)
EOF
} > "$guard/DevGuard.lua"

for module in $modules TurkeyTickleUI_DevGuard; do
	case $module in
		*DevGuard) name=$module ;;
		*)
			name=${module}_Dev
			# Links left by the old setup, which ran the repository under the release name.
			if [ -L "$addons/$module" ]; then
				rm "$addons/$module"
				echo "Removed old link $module"
			fi
			;;
	esac
	if [ -e "$addons/$name" ] && [ ! -L "$addons/$name" ]; then
		echo "Skipping $name: a real folder is already there" >&2
		continue
	fi
	ln -sfn "$dev/$name" "$addons/$name"
	echo "Linked $name"
done
