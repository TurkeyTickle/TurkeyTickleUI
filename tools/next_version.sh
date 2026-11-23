#!/bin/sh
# Prints the version for the next release and checks it can be released.
#   tools/next_version.sh patch|minor|major   raise the latest release tag (0.1.0 when there's none)
#   tools/next_version.sh 1.2.3[-beta.1]      use exactly this version
# Versions are plain semver tags with no "v". Tags with "alpha" or "beta" in them become
# alpha / beta files on CurseForge.
set -e
cd "$(dirname "$0")/.."

request=${1:-minor}
latest=$(git describe --tags --abbrev=0 --match '[0-9]*' 2>/dev/null || echo 0.1.0)

case $request in
	major | minor | patch)
		IFS=. read -r major minor patch <<-EOF
			${latest%%-*}
		EOF
		case $request in
			major) version="$((major + 1)).0.0" ;;
			minor) version="$major.$((minor + 1)).0" ;;
			patch) version="$major.$minor.$((patch + 1))" ;;
		esac
		;;
	*) version=$request ;;
esac

if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta)(\.[0-9]+)?)?$'; then
	echo "Not a release version: $version (want 1.2.3, 1.2.3-beta.1 or 1.2.3-alpha.1)" >&2
	exit 1
fi
if git rev-parse -q --verify "refs/tags/$version" >/dev/null; then
	echo "$version is already released" >&2
	exit 1
fi

# The Puzzle module names the first release of each protocol; this release can't predate the newest.
protocol_release=$(sed -n 's/^local PROTOCOL_RELEASES = {.*"\([^"]*\)" }$/\1/p' TurkeyTickleUI_Puzzle/Session.lua)
if [ -z "$protocol_release" ]; then
	echo "Couldn't find PROTOCOL_RELEASES in TurkeyTickleUI_Puzzle/Session.lua" >&2
	exit 1
fi
oldest=$(printf '%s\n%s\n' "$protocol_release" "${version%%-*}" | sort -V | head -n1)
if [ "$oldest" != "$protocol_release" ]; then
	echo "Puzzle's newest protocol says it first shipped in $protocol_release, but this release is $version." >&2
	echo "Release $protocol_release or later, or fix PROTOCOL_RELEASES in TurkeyTickleUI_Puzzle/Session.lua." >&2
	exit 1
fi

echo "$version"
