#!/bin/sh
# Plays the current Puzzle module against older releases of it in the test harness.
#   tests/puzzle_compat.sh [git-ref ...]
# With no refs, tests against 0.1.0 (the last build before versioning) and the latest release tag.
set -e
cd "$(dirname "$0")/.."

BASELINE=1d22564 # Puzzle 0.1.0: no protocol versions, no turned pieces

refs="$*"
if [ -z "$refs" ]; then
	refs=$BASELINE
	latest=$(git tag --list '[0-9]*' --sort=-v:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
	if [ -n "$latest" ]; then
		refs="$refs $latest"
	fi
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for ref in $refs; do
	echo "== Puzzle against $ref"
	mkdir -p "$tmp/$ref"
	git archive "$ref" TurkeyTickleUI_Puzzle | tar -x -C "$tmp/$ref"
	luajit tests/harness_puzzle.lua TurkeyTickleUI_Puzzle --legacy "$tmp/$ref/TurkeyTickleUI_Puzzle"
done
