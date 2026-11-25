#!/usr/bin/env bash
#
# scripts/verify/check-floor-monotonic.sh: the floor of a product may rise and may not go down or disappear, with the
# versions ordered the way rpm orders them (so +r9 is below +r10).
# Requires: rpm.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHK="$HERE/scripts/verify/check-floor-monotonic.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
run() { printf '%b' "$1" > "$WORK/old"; printf '%b' "$2" > "$WORK/new"; "$CHK" "$WORK/old" "$WORK/new" > "$WORK/out" 2>&1; echo $?; }
check "the file of the repository is not lower than itself" 0 "$("$CHK" "$HERE/config/floor.txt" "$HERE/config/floor.txt" > /dev/null 2>&1; echo $?)"
check "an empty floor stays empty" 0 "$(run '# nothing\n' '# nothing\n')"
check "a product that appears is accepted" 0 "$(run '' 'podup v1.2.3\n')"
check "the same floor is accepted" 0 "$(run 'podup v1.2.3\n' 'podup v1.2.3\n')"
check "a higher one is accepted" 0 "$(run 'podup v1.2.3\n' 'podup v1.2.4\n')"
check "a lower one is refused" 1 "$(run 'podup v1.2.4\n' 'podup v1.2.3\n')"
check "and says it went down" 1 "$(grep -c 'went down' "$WORK/out")"
check "a line that disappears is refused" 1 "$(run 'podup v1.2.4\nepistle v0.4.0\n' 'podup v1.2.4\n')"
check "and says it is gone" 1 "$(grep -c 'is gone' "$WORK/out")"
check "r9 to r10 is a rise, as rpm orders them" 0 "$(run 'podman v6.2.0+r9\n' 'podman v6.2.0+r10\n')"
check "r10 to r9 is a fall, whatever a string comparison says" 1 "$(run 'podman v6.2.0+r10\n' 'podman v6.2.0+r9\n')"
check "r19 to r20 is a rise" 0 "$(run 'podman v6.2.0+r19\n' 'podman v6.2.0+r20\n')"
check "a patch release over a revision is a rise" 0 "$(run 'podman v6.2.0+r12\n' 'podman v6.2.1\n')"
check "a line with a third field is refused" 1 "$(run 'podup v1.2.3\n' 'podup v1.2.3 x\n')"
check "a tag with a quote in it is refused, so nothing reaches the interpreter" 1 "$(run 'podup v1.2.3\n' "podup v1.2.3'\\n")"
check "two lines for a product are refused" 1 "$(run '' 'podup v1.2.3\npodup v1.2.4\n')"
check "a file that is missing is refused" 1 "$("$CHK" "$WORK/none" "$WORK/new" > /dev/null 2>&1; echo $?)"

# an rpm that cannot compare is a refusal, not a pass (the failure of a command substitution inside a condition is lost)
mkdir "$WORK/bin"; printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/rpm"; chmod +x "$WORK/bin/rpm"
printf 'podup v1.2.3\n' > "$WORK/old"; printf 'podup v1.2.2\n' > "$WORK/new"
check "a floor that went down is refused when rpm works" 1 "$("$CHK" "$WORK/old" "$WORK/new" > /dev/null 2>&1; echo $?)"
check "and still when rpm cannot answer, which must not read as 'not lower'" 1 "$(PATH="$WORK/bin:$PATH" "$CHK" "$WORK/old" "$WORK/new" > "$WORK/out" 2>&1; echo $?)"
check "and says rpm cannot compare" 1 "$(grep -c 'rpm cannot compare' "$WORK/out")"

# the step of the workflow, run as the workflow runs it, in a repository with a base commit and a change
STEP="$(python3 -I - "$HERE/.github/workflows/tests.yml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for st in d["jobs"]["commit-identity"]["steps"]:
    if st.get("name") == "The floor of a release only rises":
        print(st["run"])
PY
)"
check "the workflow has the step" 1 "$([ -n "$STEP" ] && echo 1 || echo 0)"
R="$WORK/repo"; mkdir -p "$R/scripts/verify" "$R/config" "$WORK/tmp"
cp "$HERE/scripts/verify/check-floor-monotonic.sh" "$HERE/scripts/verify/lib-evr.sh" "$R/scripts/verify/"
git -C "$R" init -q; git -C "$R" config user.email t@example.invalid; git -C "$R" config user.name t; git -C "$R" config commit.gpgsign false
printf 'podman v6.2.0+r10\n' > "$R/config/floor.txt"; git -C "$R" add -A; git -C "$R" commit -q -m base
BASE="$(git -C "$R" rev-parse HEAD)"
step() { ( cd "$R" && BASE="$BASE" RUNNER_TEMP="$WORK/tmp" bash -c "$STEP" > "$WORK/out" 2>&1; echo $? ); }
check "a floor that stays is accepted by the step" 0 "$(step)"
printf 'podman v6.2.0+r11\n' > "$R/config/floor.txt"; check "a floor that rises is accepted" 0 "$(step)"
printf 'podman v6.2.0+r9\n' > "$R/config/floor.txt"; check "a floor lowered from r10 to r9 is refused" 1 "$(step)"
check "and says it went down" 1 "$(grep -c 'went down' "$WORK/out")"
: > "$R/config/floor.txt"; check "a floor emptied is refused" 1 "$(step)"
printf 'podman v6.2.0+r9\n' > "$R/config/floor.txt"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R/scripts/verify/check-floor-monotonic.sh"
check "a change that also rewrites the check to pass is judged by the check of the base, and still refused" 1 "$(step)"
git -C "$R" rm -q -r --cached scripts > /dev/null; git -C "$R" commit -q -m nocheck; BASE="$(git -C "$R" rev-parse HEAD)"
cp "$HERE/scripts/verify/check-floor-monotonic.sh" "$R/scripts/verify/check-floor-monotonic.sh"
check "with no check in the base the change runs its own once, and a floor of the base it is held to still holds" 1 "$(step)"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
