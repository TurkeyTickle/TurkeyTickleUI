#!/bin/sh
# Prints the version for the next release of HEAD and checks it can be released.
#   tools/next_version.sh [auto]              pick it from the commits since the last release
#   tools/next_version.sh patch|minor|major   raise that part of the last release
#   tools/next_version.sh 1.2.3[-beta.1]      use exactly this version
# Auto raises the patch number, or the minor / major number when any commit message since the last
# release says [minor] / [major]. Versions are plain semver tags with no "v"; ones with "alpha" or
# "beta" in them become alpha / beta files on CurseForge.
set -e
cd "$(dirname "$0")/.."

# The newest full release by version. Release tags sit on prod, so they needn't be ancestors of HEAD.
latest_release() {
	git tag --list '[0-9]*' --sort=-v:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -n1
}

raise() {
	IFS=. read -r major minor patch <<-EOF
		$1
	EOF
	case $2 in
		major) echo "$((major + 1)).0.0" ;;
		minor) echo "$major.$((minor + 1)).0" ;;
		patch) echo "$major.$minor.$((patch + 1))" ;;
	esac
}

newer() {
	printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1
}

request=${1:-auto}
latest=$(latest_release)

# The Puzzle module names the first release of each protocol; no release can predate the newest.
protocol_release=$(sed -n 's/^local PROTOCOL_RELEASES = {.*"\([^"]*\)" }$/\1/p' TurkeyTickleUI_Puzzle/Session.lua)
if [ -z "$protocol_release" ]; then
	echo "Couldn't find PROTOCOL_RELEASES in TurkeyTickleUI_Puzzle/Session.lua" >&2
	exit 1
fi

case $request in
	auto)
		messages=$(git log --format=%B ${latest:+"$latest..HEAD"})
		part=patch
		if printf '%s' "$messages" | grep -qF '[major]'; then
			part=major
		elif printf '%s' "$messages" | grep -qF '[minor]'; then
			part=minor
		fi
		version=$(newer "$(raise "${latest:-0.1.0}" $part)" "$protocol_release")
		;;
	major | minor | patch) version=$(raise "${latest:-0.1.0}" "$request") ;;
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
if [ "$(newer "$protocol_release" "${version%%-*}")" != "${version%%-*}" ]; then
	echo "Puzzle's newest protocol says it first shipped in $protocol_release, but this release is $version." >&2
	echo "Release $protocol_release or later, or fix PROTOCOL_RELEASES in TurkeyTickleUI_Puzzle/Session.lua." >&2
	exit 1
fi

echo "$version"
