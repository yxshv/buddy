#!/bin/bash
# project: open a project folder in VS Code by name.
# Usage: buddy project NAME…    e.g. buddy project cs
# Resolves the name like `z NAME` (zoxide), then falls back to a folder in $BUDDY_PROJECTS.

BASE="${BUDDY_PROJECTS:-$HOME/Projects}"
[ $# -gt 0 ] || { echo "error: usage: buddy project NAME"; exit 1; }

name="$*"
lower() { tr '[:upper:]' '[:lower:]'; }
# zoxide alone can pick a folder that merely ends in the name ("cs" → mechanics), so a folder called
# exactly that wins: first among zoxide's matches (most used first), then in $BUDDY_PROJECTS.
matches=""
command -v zoxide > /dev/null && matches=$(zoxide query --list -- "$@" 2>/dev/null)
dir=$(echo "$matches" | while read -r d; do [ "$(basename "$d" | lower)" == "$(echo "$name" | lower)" ] && { echo "$d"; break; }; done)
[ -d "$dir" ] || dir=$(find "$BASE" -maxdepth 1 -type d -iname "$name" | head -1)
[ -d "$dir" ] || dir=$(echo "$matches" | head -1)
if [ ! -d "$dir" ]; then
    # A folder in $BUDDY_PROJECTS that starts with the name, then one that contains it.
    for pattern in "$name*" "*$name*"; do
        dir=$(find "$BASE" -maxdepth 1 -type d -iname "$pattern" ! -path "$BASE" | sort | head -1)
        [ -n "$dir" ] && break
    done
fi
[ -d "$dir" ] || { echo "error: no project matching \"$*\" (looked in zoxide and $BASE)"; exit 1; }

[ -n "$BUDDY_DRY_RUN" ] && { echo "would open $dir"; exit 0; }
code=$(command -v code || echo "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")
"$code" "$dir" || { echo "error: couldn't open $dir in VS Code"; exit 1; }
echo "Opened ${dir/#$HOME/~} in VS Code."
