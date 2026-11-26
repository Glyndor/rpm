#!/usr/bin/env bash
#
# The limit of the `heavy tests` job follows what its suites measured, and the suites of the job are the ones that were
# measured. The job runs the suites that build and admit whole releases; the job that runs the other suites is cut at 15
# minutes by its reusable, and a suite added to the heavy one without its measure, or a list grown past the limit, is red
# here before it is a run cut in half on a pull request.
#
#   budget = (sum of the seconds of the suites * 1.25 + 120 seconds of setup)
#   the limit of the job is at least 1.4 times the budget and at most 2.2 times
#
# Requires: python3 with PyYAML.
# shellcheck disable=SC2016 # the messages quote a job name with backticks
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
# verdict <workflow> <seconds file> <tests dir>: one line per problem, nothing when the job is sound
verdict() {
	python3 -I - "$1" "$2" "$3" <<'PY'
import math, os, re, sys
import yaml

wf = yaml.safe_load(open(sys.argv[1]))
rows = {}
for line in open(sys.argv[2]):
    line = line.strip()
    if line and not line.startswith("#"):
        suite, secs = line.split()
        if suite in rows:
            print("measured twice: " + suite)
        rows[suite] = int(secs)
job = wf["jobs"].get("heavy")
if job is None:
    print("the workflow has no job `heavy`")
    sys.exit()
run = "\n".join(st.get("run", "") for st in job["steps"])
suites = re.findall(r"\./(tests/[A-Za-z0-9_./-]+\.test\.sh)", run)
suites = [s for s in suites if s != "tests/ci/suites/check-suite-completeness.test.sh"]
if not suites:
    print("the job runs no suite")
for s in suites:
    if s not in rows:
        print("no measure for " + s)
    if not os.path.isfile(os.path.join(sys.argv[3], s)):
        print("does not exist: " + s)
for s in rows:
    if s not in suites:
        print("measured and not in the job: " + s)
if len(suites) != len(set(suites)):
    print("a suite twice in the job")
shell = yaml.safe_load(open(os.path.join(os.path.dirname(sys.argv[1]), "tests.yml")))["jobs"]["shell"]["with"]["test-command"].split() \
    if os.path.exists(os.path.join(os.path.dirname(sys.argv[1]), "tests.yml")) else wf["jobs"]["shell"]["with"]["test-command"].split()
for s in suites:
    if "./" + s in shell:
        print("also run by the job `shell`: " + s)
budget = sum(rows.get(s, 0) for s in suites) * 1.25 + 120
limit = job["timeout-minutes"] * 60
if limit < 1.4 * budget:
    print("the limit of %d s is under 1.4 times the budget of %d s" % (limit, budget))
if limit > 2.2 * budget:
    print("the limit of %d s is over 2.2 times the budget of %d s" % (limit, budget))
PY
}
check "the job of the repository is sound" "" "$(verdict "$HERE/.github/workflows/tests-heavy.yml" "$HERE/tests/ci/suites/suite-seconds.txt" "$HERE")"

# planted copies
mkdir -p "$WORK/t/tests/a"; : > "$WORK/t/tests/a/one.test.sh"; : > "$WORK/t/tests/a/two.test.sh"
mk() { # <timeout> <suites on the line> -> workflow path
	printf 'jobs:\n  shell:\n    with:\n      test-command: >-\n        ./tests/ci/x.test.sh\n  heavy:\n    timeout-minutes: %s\n    steps:\n      - run: |\n          ./tests/ci/suites/check-suite-completeness.test.sh %s\n' "$1" "$2" > "$WORK/wf.yml"
	echo "$WORK/wf.yml"
}
printf 'tests/a/one.test.sh 600\ntests/a/two.test.sh 300\n' > "$WORK/s.txt"   # budget = 900*1.25+120 = 1245 s
check "control: a limit of 30 minutes for a budget of 1245 s is sound" "" "$(verdict "$(mk 30 './tests/a/one.test.sh ./tests/a/two.test.sh')" "$WORK/s.txt" "$WORK/t")"
check "a limit of 20 minutes is under 1.4 times the budget" "1" "$(verdict "$(mk 20 './tests/a/one.test.sh ./tests/a/two.test.sh')" "$WORK/s.txt" "$WORK/t" | grep -c 'under 1.4')"
check "a limit of 60 minutes is over 2.2 times the budget" "1" "$(verdict "$(mk 60 './tests/a/one.test.sh ./tests/a/two.test.sh')" "$WORK/s.txt" "$WORK/t" | grep -c 'over 2.2')"
check "a suite with no measure is reported" "1" "$(verdict "$(mk 30 './tests/a/one.test.sh ./tests/a/two.test.sh ./tests/a/three.test.sh')" "$WORK/s.txt" "$WORK/t" | grep -c 'no measure for tests/a/three')"
check "a measure of a suite that the job does not run is reported" "1" "$(verdict "$(mk 30 './tests/a/one.test.sh')" "$WORK/s.txt" "$WORK/t" | grep -c 'measured and not in the job: tests/a/two')"
check "a suite that is also in the other job is reported" "1" "$(mk 30 './tests/a/one.test.sh ./tests/a/two.test.sh' > /dev/null; sed -i 's|./tests/ci/x.test.sh|./tests/ci/x.test.sh ./tests/a/two.test.sh|' "$WORK/wf.yml"; verdict "$WORK/wf.yml" "$WORK/s.txt" "$WORK/t" | grep -c 'also run by the job `shell`')"
check "a suite that does not exist is reported" "1" "$(verdict "$(mk 30 './tests/a/one.test.sh ./tests/a/two.test.sh')" "$WORK/s.txt" "$WORK/none" | grep -c 'does not exist: tests/a/one')"
check "a job with no suite is reported" "1" "$(verdict "$(mk 30 '')" "$WORK/s.txt" "$WORK/t" | grep -c 'runs no suite')"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
