#!/usr/bin/env bash
#
# scripts/publish/check-plan-age.sh: a plan that is no longer the current one is not published, so a retry hours later
# does not put back what a later release replaced.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# --- the age of the plan ----------------------------------------------------------------------------
AGE="$HERE/scripts/publish/check-plan-age.sh"
age() { "$AGE" "$@" > "$WORK/out" 2>&1; echo $?; }
check "a plan of a minute ago is accepted" 0 "$(age 1790000000 10800 1790000060)"
check "a plan exactly at the limit is accepted" 0 "$(age 1790000000 10800 1790010800)"
check "a plan one second past the limit is refused" 1 "$(age 1790000000 10800 1790010801)"
check "and says to run the workflow again" 1 "$(grep -c 'run the workflow again' "$WORK/out")"
check "a retry the next day is refused" 1 "$(age 1790000000 10800 1790086400)"
check "a plan from the future is refused" 1 "$(age 1790000100 10800 1790000000)"
check "a plan epoch that is not a number is refused" 1 "$(age abc 10800 1790000000)"
check "a limit that is not a number is refused" 1 "$(age 1790000000 '1; true' 1790000000)"
check "too few arguments are refused" 1 "$(age 1790000000)"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
