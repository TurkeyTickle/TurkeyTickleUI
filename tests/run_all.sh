#!/bin/sh
# Runs every module's harness, then plays the Puzzle module against older releases.
set -e
cd "$(dirname "$0")/.."
luajit tests/harness.lua TurkeyTickleUI_Plates
luajit tests/harness_pets.lua TurkeyTickleUI_Pets
luajit tests/harness_puzzle.lua TurkeyTickleUI_Puzzle
luajit tests/harness_cooking.lua TurkeyTickleUI_Cooking
luajit tests/harness_xp.lua TurkeyTickleUI_XP
tests/puzzle_compat.sh
