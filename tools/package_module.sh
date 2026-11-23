#!/bin/sh
# Packages one module as a standalone addon with the BigWigs packager, for its own CurseForge
# listing. The suite's .pkgmeta packages every module together; this writes a .pkgmeta for just one.
#   tools/package_module.sh <packager release.sh> <Module> [packager options...]
# e.g. tools/package_module.sh release.sh Puzzle -p 123456
#      -> .release/standalone/Puzzle/TurkeyTickleUI_Puzzle-<version>.zip
# A CHANGELOG.md at the top of the repository becomes the module's changelog.
set -e
packager=$(realpath "$1")
name=$2
module=TurkeyTickleUI_$name
shift 2
cd "$(dirname "$0")/.."
[ -d "$module" ] || { echo "No module folder $module" >&2; exit 1; }

pkgmeta=.pkgmeta-$module
trap 'rm -f "$pkgmeta"' EXIT
{
	echo "package-as: $module"
	echo
	echo "move-folders:"
	echo "  $module/$module: $module"
	echo
	echo "manual-changelog:"
	echo "  filename: CHANGELOG.md"
	echo "  markup-type: markdown"
	echo
	echo "ignore:"
	for path in *; do
		[ "$path" = "$module" ] || echo "  - $path"
	done
} > "$pkgmeta"

bash "$packager" -m "$pkgmeta" -r "$PWD/.release/standalone/$name" "$@"
