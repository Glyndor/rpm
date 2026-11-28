#!/usr/bin/env bash
#
# Tests for scripts/quality/lint/no-deprecation-notices.sh: a run that carries a warning
# about a deprecation fails, a notice does not, and a read that fails is a failure and not
# a pass. The answers of the API are planted with a `gh` that prints files, so the filters
# the script runs in jq are the ones judged.
#
# The reader waits for the job of the run that ends last, and that wait is judged too.
#
# Requires: jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$HERE/scripts/quality/lint/no-deprecation-notices.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		echo "ok    $1"
		pass=$((pass + 1))
	else
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
		fail=$((fail + 1))
	fi
}

mkdir -p "$WORK/bin" "$WORK/api"
# A gh that answers from files named after the path asked: jobs.json for the listing, <id>.json for the annotations of a job,
# and a file `fail-<name>` makes that one answer fail.
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
path=""
for a in "$@"; do case "$a" in repos/*) path="$a" ;; esac; done
case "$path" in
	*/actions/runs/*/jobs*) name=jobs ;;
	*/check-runs/*/annotations*) name="${path#*check-runs/}"; name="${name%%/*}" ;;
	*) exit 9 ;;
esac
[ ! -e "$API_DIR/fail-$name" ] || exit 1
# `later.json`, when planted, is what the listing says from the second time on.
if [ "$name" = jobs ] && [ -e "$API_DIR/later.json" ]; then
	if [ -e "$API_DIR/seen" ]; then name=later; else touch "$API_DIR/seen"; fi
fi
cat "$API_DIR/$name.json"
GH
chmod +x "$WORK/bin/gh"

run() { # <run id>: the output and the status of the script against what is planted
	PATH="$WORK/bin:$PATH" API_DIR="$WORK/api" GH_TOKEN=x REPO=Glyndor/rpm RUN_ID="${1:-123}" \
		WAIT_FOR=gate WAIT_SECONDS=2 POLL_SECONDS=0 "$SCRIPT" 2>&1
}
listing() { # <status of gate>: the two jobs of the run
	printf '{"jobs":[{"id":11,"name":"shell / test","status":"completed"},{"id":12,"name":"gate","status":"%s"}]}' "$1"
}
reset() { rm -f "$WORK"/api/*; listing completed > "$WORK/api/jobs.json"; printf '[]' > "$WORK/api/11.json"; printf '[]' > "$WORK/api/12.json"; }
note() { # <id> <level> <message>
	printf '[{"annotation_level":"%s","message":"%s"}]' "$2" "$3" > "$WORK/api/$1.json"
}

reset
out="$(run)"; rc=$?
check "a run with no annotation passes" "0" "$rc"
check "and says so" "1" "$(printf '%s\n' "$out" | grep -c 'no job of run 123 carries a deprecation warning')"

reset; note 11 warning "Node.js 20 actions are deprecated. Please update the following actions to use Node.js 24"
out="$(run)"; rc=$?
check "a warning about a deprecated runtime fails" "1" "$rc"
check "and names the job" "1" "$(printf '%s\n' "$out" | grep -c "'shell / test' carries a deprecation warning")"

reset; note 12 failure "The set-output command is no longer supported"
run >/dev/null; check "a failure annotation that says it is no longer supported fails" "1" "$?"

reset; note 11 warning "actions/foo@v1 will be removed on 2027-01-01"
run >/dev/null; check "a warning that something will be removed fails" "1" "$?"

reset; note 11 warning "The following actions are forced to run on Node.js 24"
run >/dev/null; check "a runtime forced to a new Node fails" "1" "$?"

reset; note 11 warning "DEPRECATED: upper case is read as well"
run >/dev/null; check "the match ignores case" "1" "$?"

reset; note 11 notice "This command is deprecated"
run >/dev/null; check "a notice is not read, only a warning is" "0" "$?"

reset; note 11 warning "The disk is almost full"
run >/dev/null; check "a warning about something else passes" "0" "$?"

reset; touch "$WORK/api/fail-jobs"
out="$(run)"; rc=$?
check "a listing that fails is a failure" "1" "$rc"
check "and says that nothing was read" "1" "$(printf '%s\n' "$out" | grep -c 'could not be listed')"

reset; touch "$WORK/api/fail-12"
out="$(run)"; rc=$?
check "an annotation read that fails is a failure" "1" "$rc"
check "and names the job it could not read" "1" "$(printf '%s\n' "$out" | grep -c "annotations of 'gate' could not be read")"

reset; note 11 warning "something is deprecated"; touch "$WORK/api/fail-12"
out="$(run)"
check "a failed read does not hide the warning of another job" "1" "$(printf '%s\n' "$out" | grep -c "'shell / test' carries")"

reset; printf '{"jobs":[]}' > "$WORK/api/jobs.json"
out="$(run)"; rc=$?
check "a run that never lists the last job is a failure, nothing was waited for" "1" "$rc"
check "and says which job it waited for" "1" "$(printf '%s\n' "$out" | grep -c "the job 'gate' of run 123 did not end")"

reset; listing in_progress > "$WORK/api/jobs.json"; note 11 warning "something is deprecated"
out="$(run)"; rc=$?
check "a last job that does not end in the wait is a failure" "1" "$rc"
check "and no warning is read before it ends" "0" "$(printf '%s\n' "$out" | grep -c 'carries a deprecation warning:')"

reset; listing in_progress > "$WORK/api/jobs.json"; listing completed > "$WORK/api/later.json"
note 11 warning "something is deprecated"
out="$(run)"; rc=$?
check "a last job that ends during the wait lets the warnings be read" "1" "$rc"
check "and the warning is named" "1" "$(printf '%s\n' "$out" | grep -c "'shell / test' carries a deprecation warning")"

reset
out="$(PATH="$WORK/bin:$PATH" API_DIR="$WORK/api" GH_TOKEN=x REPO=Glyndor/rpm RUN_ID=123 WAIT_SECONDS=2 "$SCRIPT" 2>&1)"; rc=$?
check "a missing name of the last job is refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
out="$(PATH="$WORK/bin:$PATH" API_DIR="$WORK/api" GH_TOKEN=x REPO=Glyndor/rpm RUN_ID=123 WAIT_FOR=gate WAIT_SECONDS=soon "$SCRIPT" 2>&1)"; rc=$?
check "a wait that is not a number is refused" "1" "$rc"

reset
out="$(PATH="$WORK/bin:$PATH" API_DIR="$WORK/api" GH_TOKEN=x REPO=Glyndor/rpm RUN_ID='12;rm' WAIT_FOR=gate WAIT_SECONDS=2 "$SCRIPT" 2>&1)"; rc=$?
check "a run id that is not a number is refused" "1" "$rc"
out="$(PATH="$WORK/bin:$PATH" API_DIR="$WORK/api" GH_TOKEN=x REPO=Glyndor/rpm "$SCRIPT" 2>&1)"; rc=$?
check "a missing run id is refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

echo
echo "$pass passed, $fail failed"
echo "DONE no-deprecation-notices.test.sh $pass $fail"
[ "$fail" -eq 0 ]
