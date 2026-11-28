#!/usr/bin/env bash
#
# The ruleset requires checks by name, and GitHub matches the name and nothing else: the
# check a pull request waits for can be produced by any run on the same commit, by any
# workflow and any event. A second workflow, or the same workflow on `push`, that emits
# the same name satisfies the requirement with a run that judged something else. The
# promotion of one branch to another points at a commit that already ran under the other
# event, which is how a green push run has stood in for a pull request.
#
# So this repository holds three things, and the planted workflows below break each:
#
#   * every workflow that is not a reusable runs on `pull_request` and on no other event,
#     so no check of this repository exists on a commit that no pull request judged;
#   * the names the workflows produce (the id of a job, or its `name`, and for a caller of
#     a local reusable the `id / inner name` GitHub shows) are all different, so no name
#     comes from two jobs or from two workflows;
#   * the names are exactly the list written here, which is the list the ruleset of
#     `main` is asked to require. A job added, renamed or removed changes this list in
#     the same pull request, where it is read.
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

# The workflows that are not pull request checks: the events each may run on, and no other. The
# publication runs by hand; none of its jobs may produce a name the ruleset requires.
EXEMPT="publish.yml=workflow_dispatch"

# The checks of a pull request, as the ruleset names them.
REQUIRED="commit identity
dco / Signed-off-by present on every commit
deprecations
empty-diff / empty diff
folder limit
gate
heavy tests
heavy tests deprecations
line-limit / line limit
secret scan
shell / shellcheck
shell / test
workflow-lint / workflow-lint"

# names <root>: the check names the workflows of the tree produce, one per line with the
# file that produces it; and one line per offence of the event rule.
names() { # $1=root
	python3 -I - "$1" "$HERE/tests/fixtures/ci/workflow-files.py" "$EXEMPT" <<'PY'
import sys

root, helper, exempt = sys.argv[1:4]
exec(open(helper).read())
EXEMPT = {pair.split("=")[0]: set(pair.split("=")[1].split(",")) for pair in exempt.split()}
INNER = {}
for path in enumerate_files(root):
    if path.startswith(".github/workflows/reusable-") and path.endswith(".yml"):
        spec = load(root, path)
        INNER[path.rsplit("/", 1)[1]] = [str((job or {}).get("name", job_id)) for job_id, job in (spec.get("jobs") or {}).items()]
for path in enumerate_files(root):
    if not path.startswith(".github/workflows/") or path.rsplit("/", 1)[1].startswith("reusable-"):
        continue
    spec = load(root, path)
    events = triggers(spec)
    if path.rsplit("/", 1)[1] in EXEMPT:
        if events != EXEMPT[path.rsplit("/", 1)[1]]:
            print(f"OFFENCE {path}: runs on {', '.join(sorted(events)) or 'nothing'}, not on {', '.join(sorted(EXEMPT[path.rsplit('/', 1)[1]]))} alone")
        continue
    if events != {"pull_request"}:
        print(f"OFFENCE {path}: runs on {', '.join(sorted(events)) or 'nothing'}, not on pull_request alone")
    for job_id, job in (spec.get("jobs") or {}).items():
        uses = str(job.get("uses", ""))
        if uses.startswith("./.github/workflows/"):
            for inner in INNER.get(uses.rsplit("/", 1)[1], ["?"]):
                print(f"NAME {job_id} / {inner}\t{path}")
        else:
            print(f"NAME {job.get('name', job_id)}\t{path}")
PY
}

offences() { # $1=root: the offences, then the duplicated names, then a difference from the list
	local out
	out="$(names "$1")"
	printf '%s\n' "$out" | grep '^OFFENCE ' | sed 's/^OFFENCE //' || true
	printf '%s\n' "$out" | grep '^NAME ' | sed 's/^NAME //' | cut -f1 | sort | uniq -d | sed 's/^/produced more than once: /' || true
	diff <(printf '%s\n' "$REQUIRED" | sort) <(printf '%s\n' "$out" | grep '^NAME ' | sed 's/^NAME //' | cut -f1 | sort -u) \
		| grep '^[<>]' | sed 's/^< /missing from the workflows: /; s/^> /not in the list of required names: /' || true
}

mk() { # <name> <relative workflow file> <text>
	mkdir -p "$WORK/$1/.github/workflows"
	printf '%s\n' "$3" > "$WORK/$1/.github/workflows/$2"
	echo "$WORK/$1"
}
# A copy of this repository's workflows to plant changes in.
cp_repo() { # <name>
	mkdir -p "$WORK/$1/.github"
	cp -r "$HERE/.github/workflows" "$WORK/$1/.github/workflows"
	echo "$WORK/$1"
}

check "the workflows of this repository produce exactly the listed names, each once, on pull_request alone" "" "$(offences "$HERE")"

d="$(cp_repo exempt)"
sed -i 's/^  workflow_dispatch:$/  push:\n  workflow_dispatch:/' "$d/.github/workflows/publish.yml"
check "a push trigger on the publication workflow is reported" "1" "$(offences "$d" | grep -c 'publish.yml: runs on push, workflow_dispatch, not on workflow_dispatch alone')"

d="$(cp_repo push)"
sed -i 's/^on:$/on:\n  push:\n    branches: [main]/' "$d/.github/workflows/tests.yml"
check "a push trigger on the workflow is reported" "1" "$(offences "$d" | grep -c 'tests.yml: runs on pull_request, push, not on pull_request alone')"

d="$(cp_repo schedule)"
sed -i 's/^on:$/on:\n  schedule:\n    - cron: "0 0 * * *"/' "$d/.github/workflows/tests.yml"
check "a schedule trigger is reported" "1" "$(offences "$d" | grep -c 'runs on pull_request, schedule')"

d="$(cp_repo second)"
printf 'on: pull_request\njobs:\n  gate:\n    runs-on: x\n    steps: []\n' > "$d/.github/workflows/other.yml"
check "a second workflow that produces the name gate is reported" "produced more than once: gate" "$(offences "$d" | grep 'produced')"

d="$(cp_repo renamed)"
sed -i 's/^    name: gate$/    name: verdict/' "$d/.github/workflows/tests.yml"
check "a renamed gate is reported on both sides of the list" \
	"$(printf 'missing from the workflows: gate\nnot in the list of required names: verdict')" "$(offences "$d")"

d="$(mk dispatch other.yml 'on: [pull_request, workflow_dispatch]
jobs:
  a:
    runs-on: x
    steps: []')"
check "a manual trigger is reported" "1" "$(offences "$d" | grep -c 'runs on pull_request, workflow_dispatch')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
