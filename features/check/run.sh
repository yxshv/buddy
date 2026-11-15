#!/bin/bash
# check: run the Part F checker on the challenge in front and print PASS or FAIL with the first failing lines.
# Usage: buddy check [PREFIX]     e.g. buddy check F03. Without a prefix it works out the challenge from
# the file in front, then the window title, then the most recently edited challenge.

ROOT="${BUDDY_CHALLENGES:-$HOME/cs/challenges}"
PART="$ROOT/F_oop"
[ -x "$PART/check.sh" ] || { echo "error: no checker at $PART/check.sh"; exit 1; }

prefix="$1"
if [ -z "$prefix" ]; then
    # Only Part F has a checker; say so if they're in another part.
    case "$BUDDY_FRONT_DOC" in
        "$ROOT"/[A-E]_*) part=${BUDDY_FRONT_DOC#"$ROOT"/}; echo "No checker for ${part%%/*}: only Part F (F_oop) has one."; exit 0 ;;
    esac
    prefix=$(printf '%s\n%s\n' "$BUDDY_FRONT_DOC" "$BUDDY_FRONT_TITLE" | grep -oE 'F[0-9]{2}' | head -1)
fi
if [ -z "$prefix" ]; then
    newest=$(ls -t "$PART"/F*/*.h "$PART"/F*/*.cpp 2>/dev/null | head -1)
    prefix=$(basename "$(dirname "$newest")" | grep -oE '^F[0-9]{2}')
fi
prefix=$(echo "$prefix" | tr '[:lower:]' '[:upper:]')
# "F1" means F01, not F10–F13.
[[ "$prefix" =~ ^F([0-9])$ ]] && prefix="F0${BASH_REMATCH[1]}"
dir=$(cd "$PART" && ls -d "$prefix"*/ 2>/dev/null | head -1 | tr -d /)
[ -n "$dir" ] || { echo "error: no challenge matching \"$prefix\" in $PART"; exit 1; }

out=$("$PART/check.sh" "$dir" 2>&1)
if echo "$out" | grep -qE '^1 / 1 passing'; then
    warnings=$(echo "$out" | grep -oE '^  [0-9]+ warning\(s\)' | tr -s ' ')
    echo "PASS $dir${warnings:+ (with$warnings)}"
    exit 0
fi
# Only the first thing that went wrong: its heading and its first line (a compile error's first error,
# a broken rule, an output diff's first lines). Never more, so it can't spell out the solution.
echo "FAIL $dir"
echo "$out" | awk '
    /^  (not started|COMPILE ERROR|RULE BROKEN|LINK ERROR|FAIL)/ && !found { found = 1; print; limit = ($0 ~ /FAIL/) ? 4 : 1; next }
    found && /^    / && n < limit { n++; print; next }
    found { exit }'
