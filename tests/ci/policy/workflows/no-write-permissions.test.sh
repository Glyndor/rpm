#!/usr/bin/env bash
#
# No job of this repository holds a token that can write. Cancelling the other runs
# of a commit, labelling, commenting and pushing all need a write scope, and a job
# that holds one while it runs code the pull request controls hands the pull request
# that scope. Nothing here needs it: every check reads the tree and reports a result.
#
# The permissions that count are the effective ones, not the ones a job names:
#
#   * `write-all` is every write scope;
#   * a job with no `permissions:` of its own inherits the workflow's, and a workflow
#     with none inherits whatever the repository default is, which may be write;
#   * a reusable workflow is judged by its own file, and the caller by its.
#
# So every workflow declares its permissions at the top, each job that declares its
# own does so with read scopes only, and anything else is a failure. There is no list
# of exceptions: a job that needs a write scope is a decision for a pull request that
# changes this test and says why.
#
# For the same reason nothing here cancels another run. A job that cancels the other
# runs of a commit needs `actions: write`, and a list of the workflows it may cancel
# would have to keep every security analysis (CodeQL, dependency audits, the secret
# scan, DCO) out of it. This repository has no such job: a failed cheap check skips
# the suite through `needs`, and `gate` reports the failure. The second rule below
# fails if a workflow or a script starts one, so adding it means changing this test
# together with the list of what may be cancelled and a test of that list.
#
# The rule is run over planted workflows first, each with the one way round it and a
# passing twin, and then over this repository.
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

# One line per offence in the workflows of the directory $1.
audit() { # $1=workflows dir
	python3 -I - "$1" <<'PY'
import glob
import os
import sys

import yaml


def scopes(value):
    """The write scopes a `permissions:` value grants, or None when it is not declared."""
    if value is None:
        return None
    if isinstance(value, str):
        return {"write-all"} if value == "write-all" else set() if value == "read-all" else {f"unreadable: {value}"}
    if isinstance(value, dict):
        return {f"{k}: {v}" for k, v in value.items() if v not in ("read", "none")}
    return {f"unreadable: {value!r}"}


files = sorted(glob.glob(os.path.join(sys.argv[1], "*.y*ml")))
if not files:
    print("no workflow was read, so nothing was judged")
for path in files:
    name = os.path.basename(path)
    with open(path) as fh:
        spec = yaml.safe_load(fh) or {}
    top = scopes(spec.get("permissions"))
    if top is None:
        print(f"{name}: the workflow declares no permissions, so it inherits the repository default")
        top = set()
    for scope in sorted(top):
        print(f"{name}: the workflow grants {scope}")
    for job_id, job in (spec.get("jobs") or {}).items():
        own = scopes(job.get("permissions")) if isinstance(job, dict) else None
        for scope in sorted(own or ()):
            print(f"{name}: job {job_id} grants {scope}")
PY
}

plant() { # <name> <workflow text>
	mkdir -p "$WORK/$1"
	printf '%s\n' "$2" > "$WORK/$1/w.yml"
	echo "$WORK/$1"
}

check "read-only workflow and job pass" "" "$(audit "$(plant ok 'permissions:
  contents: read
jobs:
  j:
    permissions:
      contents: read
    runs-on: x
    steps: []')")"
check "an empty permissions block passes" "" "$(audit "$(plant empty 'permissions: {}
jobs:
  j: {runs-on: x}')")"
check "write-all on the workflow is reported" "w.yml: the workflow grants write-all" "$(audit "$(plant wa 'permissions: write-all
jobs:
  j: {runs-on: x}')")"
check "actions: write on a job is reported" "w.yml: job j grants actions: write" "$(audit "$(plant job 'permissions:
  contents: read
jobs:
  j:
    permissions:
      contents: read
      actions: write
    runs-on: x')")"
check "write-all on a job is reported" "w.yml: job j grants write-all" "$(audit "$(plant jwa 'permissions:
  contents: read
jobs:
  j:
    permissions: write-all
    runs-on: x')")"
check "a write scope on the workflow, inherited by every job, is reported once, at the workflow" \
	"w.yml: the workflow grants contents: write" "$(audit "$(plant inherit 'permissions:
  contents: write
jobs:
  j: {runs-on: x}')")"
check "a workflow with no permissions is reported" \
	"w.yml: the workflow declares no permissions, so it inherits the repository default" "$(audit "$(plant none 'jobs:
  j: {runs-on: x}')")"
check "a scope written as something unreadable is reported" "w.yml: the workflow grants unreadable: ['x']" "$(audit "$(plant odd 'permissions: [x]
jobs:
  j: {runs-on: x}')")"
check "a directory with no workflow is not a pass: nothing was read" "no workflow was read, so nothing was judged" "$(audit "$WORK/missing")"

# One line per file under $1 that cancels a run.
cancels() { # $1=directory
	grep -rnEI 'gh[[:space:]]+run[[:space:]]+cancel|actions/runs/[^[:space:]]*/cancel|cancel-workflow|force-cancel' "$1" 2>/dev/null \
		| cut -d: -f1 | sort -u | sed "s|^$1/||" || true
}
mkdir -p "$WORK/c/a" "$WORK/c/b"
# shellcheck disable=SC2016 # the text of a workflow, with `$ID` meant literally
printf 'steps:\n  - run: gh run cancel "$ID"\n' > "$WORK/c/a/w.yml"
printf 'steps:\n  - run: gh api -X POST repos/o/r/actions/runs/1/cancel\n' > "$WORK/c/b/w.yml"
printf 'steps:\n  - run: echo cancelled by nobody\n' > "$WORK/c/b/ok.yml"
check "a workflow that runs gh run cancel is reported" "a/w.yml" "$(cancels "$WORK/c" | grep '^a/')"
check "a call of the cancel endpoint is reported" "b/w.yml" "$(cancels "$WORK/c" | grep '^b/')"
check "a file that only says the word is not" "0" "$(cancels "$WORK/c" | grep -c 'ok.yml' || true)"
check "nothing in this repository cancels a run" "" "$(cancels "$HERE/.github"; cancels "$HERE/scripts")"

real="$(audit "$HERE/.github/workflows")"
check "no workflow of this repository holds a write scope" "" "$real"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
