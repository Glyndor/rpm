#!/usr/bin/env bash
#
# A reusable workflow nobody calls is a file that looks like part of the CI and decides nothing.
#
# The reusables of this repository hold the checks a pull request waits for (`shell / test`,
# `dco`, `line limit`, `workflow-lint`, `empty diff`) and the watchers that turn the silence of
# something else into a red check. A reusable with no caller is not one of them: nothing runs
# it, so a change to it passes every check, and the file that says the CI is covered still
# counts it as covered.
#
# The two freshness reusables of this repository came with the rest of the CI and nothing here
# called them: this repository has no workflow of watchers. Nothing reported it, because a file
# that is never read cannot fail a check that reads other files.
#
# The rule is therefore one line per reusable that no job of any workflow calls:
#
#   <reusable>.yml
#
# A caller is a job whose `uses:` names the file, in any workflow of the tree, a reusable
# included: a reusable that calls another one is a caller of it.
#
# The checker is shown to refuse each way of getting it wrong before it is trusted with the
# live workflows, the same shape as tests/ci/policy/rules/cancel-policy.test.sh.
#
# Requires: python3 with PyYAML.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
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

# orphans <workflows dir>: one line per reusable that no job of the tree calls.
orphans() { # $1=workflows dir
	python3 -I - "$1" <<'PY'
import glob
import os
import sys

import yaml

root = sys.argv[1]
files = sorted(glob.glob(os.path.join(root, "*.yml")) + glob.glob(os.path.join(root, "*.yaml")))
reusables = {os.path.basename(path) for path in files if os.path.basename(path).startswith("reusable-")}
called = set()
for path in files:
	try:
		with open(path) as fh:
			spec = yaml.safe_load(fh) or {}
	except (OSError, yaml.YAMLError) as exc:
		print("cannot be judged: %s (%s)" % (os.path.basename(path), exc))
		continue
	jobs = spec.get("jobs") if isinstance(spec, dict) else None
	for job in (jobs or {}).values() if isinstance(jobs, dict) else ():
		uses = job.get("uses") if isinstance(job, dict) else None
		if not isinstance(uses, str) or not uses.startswith("./.github/workflows/"):
			continue
		name = uses.rsplit("/", 1)[1]
		if name in reusables:
			called.add(name)
for name in sorted(reusables - called):
	print(name)
PY
}

# --- the control: the checker refuses a reusable nobody calls ----------------
mkdir -p "$WORK/planted"
printf 'name: Called\non: pull_request\njobs:\n  c:\n    uses: ./.github/workflows/reusable-called.yml\n' > "$WORK/planted/tests.yml"
printf 'name: Called reusable\non:\n  workflow_call:\njobs:\n  r:\n    runs-on: ubuntu-latest\n    steps: []\n' > "$WORK/planted/reusable-called.yml"
printf 'name: Orphan reusable\non:\n  workflow_call:\njobs:\n  r:\n    runs-on: ubuntu-latest\n    steps: []\n' > "$WORK/planted/reusable-orphan.yml"
check "a reusable nobody calls is reported" "reusable-orphan.yml" "$(orphans "$WORK/planted")"

# A reusable called by another reusable is a caller of it: the tree is one of the
# reusables calling the other.
printf 'name: Caller reusable\non:\n  workflow_call:\njobs:\n  r:\n    uses: ./.github/workflows/reusable-called.yml\n' > "$WORK/planted/reusable-caller.yml"
printf 'name: Called\non: pull_request\njobs:\n  c:\n    uses: ./.github/workflows/reusable-called.yml\n  k:\n    uses: ./.github/workflows/reusable-caller.yml\n' > "$WORK/planted/tests.yml"
check "a reusable called by another reusable is not reported" "reusable-orphan.yml" "$(orphans "$WORK/planted")"
rm "$WORK/planted/reusable-orphan.yml"
check "and a tree whose reusables are all called reports nothing" "" "$(orphans "$WORK/planted")"

# --- the live workflows ------------------------------------------------------
check "every reusable workflow of this repository is called by a job" "" "$(orphans "$HERE/.github/workflows")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
