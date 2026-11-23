#!/usr/bin/env bash
#
# tests.yml adds up its checks in a job called `gate`, and the suite waits for the
# cheap checks. Both are claims nothing else reads, and each fails quietly:
#
#   * a job added to tests.yml that `gate` does not wait for is a check whose result
#     the verdict never sees, so a red one does not turn the verdict red;
#   * `gate` without `always()` is skipped when a dependency fails, and a skipped
#     job reports Success, so the verdict passes exactly when something failed;
#   * a `shell` that does not wait for a cheap check runs the suite on a pull
#     request that is already red, which is the cost the ordering exists to avoid;
#   * a `gate` that accepts anything but `success` reads a skipped or cancelled job
#     as a pass.
#
# The structure is read from the workflow and judged first on planted copies, so a
# pass is shown to be a pass of a check that can fail; the shell of the `gate` step
# is then run as it ships, over every result a job can end with.
#
# Requires: python3 with PyYAML.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		echo "ok    $1"
	else
		fail=$((fail + 1))
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
	fi
}
# shellcheck disable=SC1091 # the fixture that reads one step of a workflow
. "$HERE/tests/fixtures/ci/step-script.sh"

# One line per offence in the workflow at $1.
audit() { # $1=tests.yml
	python3 -I - "$1" <<'PY'
import sys

import yaml

with open(sys.argv[1]) as fh:
    spec = yaml.safe_load(fh)
jobs = spec.get("jobs") or {}


def needs(job):
    value = (jobs.get(job) or {}).get("needs", [])
    return set(value if isinstance(value, list) else [value])


if "gate" not in jobs:
    print("there is no job called gate")
else:
    others = set(jobs) - {"gate"}
    missing = sorted(others - needs("gate"))
    for job in missing:
        print(f"gate does not wait for {job}")
    for job in sorted(needs("gate") - others):
        print(f"gate waits for {job}, which is not a job of this workflow")
    if str(jobs["gate"].get("if", "")).strip() != "always()":
        print("gate does not run when a job it waits for fails: its if: is not always()")
if "shell" not in jobs:
    print("there is no job called shell")
else:
    for job in sorted(set(jobs) - {"gate", "shell"} - needs("shell")):
        print(f"shell does not wait for {job}")
    for job in sorted(needs("shell") - (set(jobs) - {"gate", "shell"})):
        print(f"shell waits for {job}, which is not one of the cheap checks")
# The verdict reads the results of the jobs it waits for and nothing else, in one step.
steps = (jobs.get("gate") or {}).get("steps") or []
if "gate" not in jobs:
    pass
elif len(steps) != 1:
    print(f"gate has {len(steps)} steps, not the one that reads the verdict")
elif steps[0].get("env") != {"NEEDS": "${{ toJSON(needs) }}"}:
    print("the step of gate reads something other than toJSON(needs)")
elif "uses" in steps[0] or "if" in steps[0] or "continue-on-error" in steps[0]:
    print("the step of gate is conditional or calls an action")
PY
}

plant() { # <name> <python statement editing `spec`>: a copy of tests.yml, edited
	python3 -I - "$HERE/.github/workflows/tests.yml" "$WORK/$1.yml" "$2" <<'PY'
import sys

import yaml

with open(sys.argv[1]) as fh:
    spec = yaml.safe_load(fh)
exec(sys.argv[3])
with open(sys.argv[2], "w") as out:
    yaml.safe_dump(spec, out, sort_keys=False)
PY
}

check "the real workflow: gate waits for every job and shell for every cheap check" "" "$(audit "$HERE/.github/workflows/tests.yml")"

plant no-gate "del spec['jobs']['gate']"
check "a workflow with no gate is reported" "there is no job called gate" "$(audit "$WORK/no-gate.yml")"

plant dropped "spec['jobs']['gate']['needs'].remove('secret-scan')"
check "a job gate does not wait for is reported" "gate does not wait for secret-scan" "$(audit "$WORK/dropped.yml")"

plant added "spec['jobs']['extra'] = {'runs-on': 'ubuntu-latest', 'steps': [{'run': 'true'}]}"
check "a new job the verdict never sees is reported" \
	"$(printf 'gate does not wait for extra\nshell does not wait for extra')" "$(audit "$WORK/added.yml")"

plant ghost "spec['jobs']['gate']['needs'].append('nowhere')"
check "a wait for a job that does not exist is reported" \
	"gate waits for nowhere, which is not a job of this workflow" "$(audit "$WORK/ghost.yml")"

plant no-always "del spec['jobs']['gate']['if']"
check "a gate without always() is reported" \
	"gate does not run when a job it waits for fails: its if: is not always()" "$(audit "$WORK/no-always.yml")"

plant success "spec['jobs']['gate']['if'] = 'success()'"
check "a gate that runs only after success is reported" \
	"gate does not run when a job it waits for fails: its if: is not always()" "$(audit "$WORK/success.yml")"

plant eager "spec['jobs']['shell']['needs'].remove('folder-limit')"
check "a suite that does not wait for a cheap check is reported" "shell does not wait for folder-limit" "$(audit "$WORK/eager.yml")"

plant no-needs "del spec['jobs']['shell']['needs']"
check "a suite that waits for nothing is reported once per cheap check" "7" "$(audit "$WORK/no-needs.yml" | grep -c '^shell does not wait')"

plant gate-env "spec['jobs']['gate']['steps'][0]['env']['NEEDS'] = '\${{ toJSON(github) }}'"
check "a gate that reads something other than the results of its jobs is reported" \
	"the step of gate reads something other than toJSON(needs)" "$(audit "$WORK/gate-env.yml")"
plant gate-extra "spec['jobs']['gate']['steps'].append({'run': 'true'})"
check "a gate with a second step is reported" "gate has 2 steps, not the one that reads the verdict" "$(audit "$WORK/gate-extra.yml")"
plant gate-if "spec['jobs']['gate']['steps'][0]['if'] = 'false'"
check "a conditional step of the gate is reported" "the step of gate is conditional or calls an action" "$(audit "$WORK/gate-if.yml")"
plant shell-extra "spec['jobs']['shell']['needs'].append('gate')"
check "a suite that waits for the verdict is reported" \
	"shell waits for gate, which is not one of the cheap checks" "$(audit "$WORK/shell-extra.yml")"

# The shell of the gate, as it ships, over every result a job can end with.
step_script "$HERE/.github/workflows/tests.yml" 'Every job above succeeded' > "$WORK/gate.sh"
check "the gate step was found" "1" "$([ -s "$WORK/gate.sh" ] && echo 1 || echo 0)"
run_gate() { # <needs json>: the exit status of the step in $rc, its output in $out
	rc=0
	out="$(NEEDS="$1" bash "$WORK/gate.sh" 2>&1)" || rc=$?
}
said() { printf '%s\n' "$out" | grep -cF -- "$1" || true; }

run_gate '{"a":{"result":"success","outputs":{}},"b":{"result":"success","outputs":{}}}'
check "every job succeeded: the gate passes" "0" "$rc"
check "and says how many it read" "1" "$(said '2 job(s) succeeded')"
check "and prints one row per job with its result" "2" "$(printf '%s\n' "$out" | grep -cE '^(a|b) +success$' || true)"
run_gate '{"a":{"result":"success","outputs":{}},"b":{"result":"failure","outputs":{}}}'
check "one failed: the gate fails" "1" "$rc"
check "and names the job and what it ended with" "1" "$(said 'b ended failure')"
check "and does not name the one that passed as failed" "0" "$(said 'a ended')"
check "and still prints the row of the one that passed" "1" "$(printf '%s\n' "$out" | grep -cE '^a +success$' || true)"
run_gate '{"a":{"result":"skipped","outputs":{}}}'
check "one was skipped: the gate fails, because a skip reports Success" "1" "$rc"
check "and says it ended skipped" "1" "$(said 'a ended skipped')"
run_gate '{"a":{"result":"cancelled","outputs":{}}}'
check "one was cancelled: the gate fails" "1" "$rc"
run_gate '{"a":{"outputs":{}}}'
check "a job with no result: the gate fails" "1" "$rc"
run_gate '{}'
check "no job at all: the gate fails rather than pass having looked at nothing" "1" "$rc"
check "and says why" "1" "$(said 'waits for no other job')"
run_gate 'not json'
check "a value that is not JSON: the gate fails" "1" "$rc"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
