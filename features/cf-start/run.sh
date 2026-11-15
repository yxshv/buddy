#!/bin/bash
# cf-start: get ready to solve the Codeforces problem on screen.
# Usage: buddy cf-start [PROBLEM] < samples
#   1. Works out the problem (PROBLEM like 2276C, else the browser page's URL).
#   2. Saves its samples, if piped in (=== input / lines / === output / lines, per sample), so
#      `buddy cf-test` can run them later.
#   3. Creates $BUDDY_CF/<PROBLEM>.cpp from template.cpp (next to this script); never overwrites.
#   4. Opens it in Neovim in a new Ghostty tab, in that folder.

CF="${BUDDY_CF:-$HOME/cf}"
upper() { tr '[:lower:]' '[:upper:]'; }

problem=$(echo "$1" | upper)
if [ -z "$problem" ]; then
    problem=$(echo "$BUDDY_FRONT_DOC" | sed -nE 's#.*/(contest|gym)/([0-9]+)/problem/([A-Za-z][0-9]?).*#\2\3#p; s#.*/problemset/problem/([0-9]+)/([A-Za-z][0-9]?).*#\1\2#p' | head -1 | upper)
fi
if [ -z "$problem" ]; then
    echo "error: can't tell which problem this is. Pass its ID, like: buddy cf-start 2276C"
    exit 1
fi
[[ "$problem" =~ ^[0-9]{1,5}[A-Z][0-9]?$ ]] || { echo "error: \"$problem\" doesn't look like a problem ID (like 2276C)"; exit 1; }

# Samples, for cf-test.
piped=$(cat)
saved=0
if echo "$piped" | grep -q '^=== input'; then
    cache="${BUDDY_CACHE:-$HOME/Library/Application Support/Buddy}/cf-samples"
    mkdir -p "$cache"
    printf '%s\n' "$piped" > "$cache/$problem.txt"
    saved=$(echo "$piped" | grep -c '^=== input')
elif [ -n "$(echo "$piped" | tr -d '[:space:]')" ]; then
    echo "error: samples must be piped in as '=== input', its lines, '=== output', its lines, for each sample."
    exit 1
fi

mkdir -p "$CF"
file="$CF/$problem.cpp"
made=0
if [ ! -e "$file" ]; then
    cp "$BUDDY_FEATURE_DIR/template.cpp" "$file" || { echo "error: couldn't create $file"; exit 1; }
    made=1
fi

if [ -z "$BUDDY_DRY_RUN" ]; then
    # A new tab in the front Ghostty window (or a new window), starting in the folder, running nvim.
    # Typed as input rather than run as the tab's command, so quitting nvim leaves a shell there.
    osascript - "$CF" "nvim $problem.cpp" <<'APPLESCRIPT' > /dev/null 2>&1 || { echo "error: couldn't open Ghostty (allow Buddy to control Ghostty in System Settings › Privacy & Security › Automation)"; exit 1; }
on run argv
    set dir to item 1 of argv
    set cmd to item 2 of argv
    tell application "Ghostty"
        activate
        set cfg to new surface configuration
        set initial working directory of cfg to dir
        set initial input of cfg to cmd & return
        if (count of windows) > 0 then
            new tab in front window with configuration cfg
        else
            new window with configuration cfg
        end if
    end tell
end run
APPLESCRIPT
fi

[ $made -eq 1 ] && buddy card "$problem.cpp" --subtitle "New solution from your template" --url "$file" --kind file > /dev/null 2>&1
what=$([ $made -eq 1 ] && echo "Created" || echo "Opened")
samples=$([ $saved -gt 0 ] && echo ", $saved sample(s) saved" || echo "")
echo "$what $problem.cpp in Neovim$samples."
