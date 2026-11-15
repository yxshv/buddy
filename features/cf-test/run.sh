#!/bin/bash
# cf-test: compile a Codeforces solution and run it on the problem's samples.
# Usage: buddy cf-test [PROBLEM] < samples
#   PROBLEM is like 2276A (default: the .cpp in front, else the newest .cpp in $BUDDY_CF).
#   Samples on stdin, one or more of:
#       === input
#       3
#       1 2
#       === output
#       -1
#   They're saved in Buddy's folder (cf-samples/<problem>.txt), so later runs can skip them.

CF="${BUDDY_CF:-$HOME/cf}"
upper() { tr '[:lower:]' '[:upper:]'; }
problem=$(echo "$1" | upper)
guessed=0
if [ -z "$problem" ]; then
    # The problem page in the browser: …/contest/2276/problem/A or …/problemset/problem/2276/A.
    problem=$(echo "$BUDDY_FRONT_DOC" | sed -nE 's#.*/(contest|gym)/([0-9]+)/problem/([A-Za-z][0-9]?).*#\2\3#p; s#.*/problemset/problem/([0-9]+)/([A-Za-z][0-9]?).*#\1\2#p' | head -1 | upper)
fi
if [ -z "$problem" ]; then
    # The solution open in the editor: 2276A.cpp.
    problem=$(printf '%s\n%s\n' "$BUDDY_FRONT_DOC" "$BUDDY_FRONT_TITLE" | grep -oiE '\b[0-9]{3,4}[A-Z][0-9]?\b' | head -1 | upper)
fi
if [ -z "$problem" ]; then
    problem=$(basename "$(ls -t "$CF"/*.cpp 2>/dev/null | head -1)" .cpp)
    guessed=1
fi
src="$CF/$problem.cpp"
[ -f "$src" ] || { echo "error: no solution at ${src/#$HOME/~}"; exit 1; }

cache="${BUDDY_CACHE:-$HOME/Library/Application Support/Buddy}/cf-samples"
mkdir -p "$cache"
samples="$cache/$problem.txt"
piped=$(cat)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if echo "$piped" | grep -q '^=== input'; then
    # Samples for a problem that was only guessed (the newest .cpp) aren't saved under its name.
    if [ $guessed -eq 1 ]; then samples="$work/samples.txt"; fi
    printf '%s\n' "$piped" > "$samples"
elif [ -n "$(echo "$piped" | tr -d '[:space:]')" ]; then
    echo "error: samples must be piped in as '=== input', its lines, '=== output', its lines, for each sample."
    exit 1
elif [ ! -f "$samples" ]; then
    echo "error: no samples for $problem yet. Pipe them in: === input / lines / === output / lines, per sample."
    exit 1
fi

compiler=$(command -v g++-16 || command -v g++)
# GNU C++23 (the newest standard Codeforces accepts), built with bounds checks and sanitizers so an
# out-of-range index or other undefined behaviour stops with an error instead of printing garbage.
FLAGS="-std=gnu++23 -g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=all -D_GLIBCXX_ASSERTIONS"
# handle_abort: a failed bounds check (abort) prints where it happened, like a sanitizer error does.
export ASAN_OPTIONS=detect_leaks=0:handle_abort=1:symbolize=1 UBSAN_OPTIONS=print_stacktrace=1
if ! errors=$("$compiler" $FLAGS -o "$work/sol" "$src" 2>&1); then
    echo "COMPILE ERROR $problem"
    echo "$errors" | grep -E 'error' | head -1 | sed -E 's#^[^ :]*/([^/: ]+:[0-9]+)#\1#; s/^/  /'
    exit 0
fi

# Split the samples file into work/N.in and work/N.out.
awk -v dir="$work" '
    /^=== input/  { n++; file = dir "/" n ".in"; printf "" > file; next }
    /^=== output/ { file = dir "/" n ".out"; printf "" > file; next }
    file          { print >> file }' "$samples"
count=$(ls "$work"/*.in 2>/dev/null | wc -l | tr -d ' ')
[ "$count" -gt 0 ] || { echo "error: the samples for $problem are empty"; exit 1; }

# What went wrong in a crash, in one line: the error itself, then where in their file it happened.
why() {
    local err="$1" what where
    if grep -q "Assertion '__n < this->size()' failed" "$err"; then
        what="vector index out of range"
    else
        what=$(grep -m1 -E 'runtime error|ERROR: AddressSanitizer|Assertion|terminate called|what\(\)' "$err" \
            | sed -E 's/^==[0-9]+==//; s/^ *//; s#^[^ :]*/([^/: ]+:[0-9]+:[0-9]+)#\1#; s/ on address 0x[0-9a-f]+.*//' | cut -c1-160)
    fi
    # The first stack frame inside their own file (not the library's).
    where=$(grep -m1 -oE "$(basename "$src")"':[0-9]+' "$err")
    [ -z "$what" ] && what=$(grep -m1 -E 'Segmentation|Abort|SUMMARY' "$err" | cut -c1-120)
    echo "${what:-it exited with an error}${where:+ at $where}"
}

# Compare token by token, like Codeforces does for most problems (whitespace doesn't matter).
norm() { tr -s ' \t\r\n' '\n' | sed '/^$/d'; }
passed=0; report=""; crashed=0
for ((i = 1; i <= count; i++)); do
    # stdout is the answer; stderr is kept only to explain a crash (debug lines on cerr don't count).
    { perl -e 'alarm 3; exec @ARGV' "$work/sol" < "$work/$i.in" > "$work/$i.got" 2> "$work/$i.err"; status=$?; } 2>/dev/null
    if [ $status -eq 142 ]; then
        [ -z "$report" ] && report="  sample $i: took over 3 seconds (stopped)"$'\n'
        continue
    fi
    if [ $status -ne 0 ]; then
        crashed=1
        if [ -z "$report" ]; then
            reason=$(why "$work/$i.err")
            report="  sample $i: crashed (exit $status)${reason:+: $reason}"$'\n'
        fi
        continue
    fi
    if [ "$(norm < "$work/$i.got")" == "$(norm < "$work/$i.out")" ]; then
        passed=$((passed + 1))
    elif [ -z "$report" ]; then
        report+="  sample $i (< yours   > expected):"$'\n'
        report+=$(diff "$work/$i.got" "$work/$i.out" | head -10 | sed 's/^/    /')$'\n'
    fi
done
note=""; [ $guessed -eq 1 ] && note=" (guessed from the newest file; name the problem to be sure)"
if [ $passed -eq $count ]; then echo "PASS $problem: all $count sample(s)$note"
elif [ $crashed -eq 1 ]; then echo "CRASH $problem: $passed / $count sample(s) passed$note"; printf '%s' "$report"
else echo "FAIL $problem: $passed / $count sample(s) passed$note"; printf '%s' "$report"; fi
