#!/usr/bin/env bash
#
# The jobs `commit-identity` and `secret-scan` of tests.yml check out the head of a pull
# request, so the scripts in that checkout are the pull request's own. A change that rewrote a script to exit 0
# would be judged by itself. Each step therefore takes its rule from the base commit and
# runs that, and this runs the real step, the text of the workflow and nothing else, in a
# repository whose head swaps both scripts for ones that always pass and carries a
# .gitattributes that hides what a file adds. The change under review is refused by the
# base's rule, for the reason that rule gives; the same change without the offence is
# accepted, so a step that refuses everything would not pass.
#
# Two more cases hold the edges of that rule. The pull request that adds the scripts has
# a base with none, so it runs its own copy once and is judged by it; and a base commit
# that cannot be read stops the step, because falling back to the pull request's copy on
# an unreadable base would let a pull request choose its own judge.
#
# Requires: python3, git.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
WORKFLOW="$HERE/.github/workflows/tests.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # <desc> <want> <got>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}

# shellcheck disable=SC1091 # the fixture that reads one step of a workflow
. "$HERE/tests/fixtures/ci/step-script.sh"
step() { step_script "$WORKFLOW" "$1"; }
IDENTITY="$(step "Every commit uses a GitHub noreply address")"
SCAN="$(step "The change adds no credential-shaped line")"

noreply="12345+someone@users.noreply.github.com"
repo="$WORK/repo"
mkdir -p "$WORK/tmp"
git init -q "$repo"
gitc() { git -C "$repo" -c user.name=t -c "user.email=${AUTHOR:-$noreply}" -c commit.gpgSign=false "$@"; }

mkdir -p "$repo/scripts/quality/hygiene"
for name in check-secrets.sh check-commit-identity.sh; do
	cp "$HERE/scripts/quality/hygiene/$name" "$repo/scripts/quality/hygiene/$name"
done
echo base > "$repo/README"; gitc add -A; gitc commit -q -m base
base="$(git -C "$repo" rev-parse HEAD)"

# head <author> <file> <content>: a change that swaps both scripts for ones that always pass,
# hides what files add, and adds one file.
head_commit() {
	git -C "$repo" reset -q --hard "$base"
	for name in check-secrets.sh check-commit-identity.sh; do
		printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/scripts/quality/hygiene/$name"
	done
	printf '* -diff\n' > "$repo/.gitattributes"
	printf '%s\n' "$3" > "$repo/$2"
	gitc add -A; AUTHOR="$1" gitc commit -q -m change
	head="$(git -C "$repo" rev-parse HEAD)"
}
run_step() { # <run block>: the status in $rc, the output in $out
	rc=0
	out="$(cd "$repo" && RUNNER_TEMP="$WORK/tmp" BASE="$base" HEAD="$head" bash -c "$1" 2>&1)" || rc=$?
}
said() { printf '%s\n' "$out" | grep -cF -- "$1" || true; }

aws="id AKI""A$(printf 'Q%.0s' {1..16})"
personal="someone@mail.example"

head_commit "$noreply" leak.txt "$aws"
run_step "$SCAN"
check "a credential is refused although the head swapped the script for one that passes" 1 "$rc"
check "and it is the base's rule that names it" 1 "$(said 'leak.txt:1 AWS access key')"
head_commit "$noreply" leak.txt "just a line"
run_step "$SCAN"
check "the same change without the credential is accepted" 0 "$rc"
check "and says nothing credential-shaped was added" 1 "$(said 'no credential-shaped lines added')"

head_commit "$personal" notes.txt "just a line"
run_step "$IDENTITY"
check "a personal address is refused although the head swapped the script for one that passes" 1 "$rc"
check "and it is the base's rule that names the author" 1 "$(said 'the author address')"
head_commit "$noreply" notes.txt "just a line"
run_step "$IDENTITY"
check "the same change with a noreply address is accepted" 0 "$rc"

# The pull request that adds the scripts: a base with none runs the copy it brings.
git -C "$repo" reset -q --hard "$base"
git -C "$repo" rm -q -r scripts
gitc commit -q -m "base without the scripts"
base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" reset -q --hard "$base"
mkdir -p "$repo/scripts/quality/hygiene"
for name in check-secrets.sh check-commit-identity.sh; do
	cp "$HERE/scripts/quality/hygiene/$name" "$repo/scripts/quality/hygiene/$name"
done
printf '%s\n' "$aws" > "$repo/leak.txt"
gitc add -A; AUTHOR="$noreply" gitc commit -q -m "add the scripts"
head="$(git -C "$repo" rev-parse HEAD)"
run_step "$SCAN"
check "a base without the script runs the copy of the pull request that adds it" 1 "$(said 'adds it and runs its own copy once')"
check "and that copy refuses a credential" 1 "$rc"
run_step "$IDENTITY"
check "the same for the identity check" 1 "$(said 'adds it and runs its own copy once')"
check "and a pull request with a noreply address passes it" 0 "$rc"

# A base that cannot be read must stop the step, not hand the judgement to the head.
base=0000000000000000000000000000000000000000
run_step "$SCAN"
check "an unreadable base stops the secret scan" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and it did not run the copy of the pull request" 0 "$(said 'runs its own copy once')"
run_step "$IDENTITY"
check "an unreadable base stops the identity check" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "and it did not run the copy of the pull request here either" 0 "$(said 'runs its own copy once')"

# What the steps are given is part of the rule: the base and the head come from the event
# and from nowhere else, and the checkout is of the head with the whole history and no
# token left behind. A step handed another commit as its base judges the wrong range, and
# the cases above would not notice, because they pass the values in themselves.
shipped() { # <job id>: the env of its steps and the arguments of its checkout, as JSON
	python3 -I - "$WORKFLOW" "$1" <<'PY'
import json
import sys

import yaml

job = yaml.safe_load(open(sys.argv[1]))["jobs"][sys.argv[2]]
print(json.dumps([[s.get("env"), s.get("with")] for s in job["steps"]], sort_keys=True))
PY
}
# shellcheck disable=SC2016 # the text of the workflow, an expression GitHub expands
BASE_REF='${{ github.event.pull_request.base.sha }}'
# shellcheck disable=SC2016 # the text of the workflow, an expression GitHub expands
HEAD_REF='${{ github.event.pull_request.head.sha }}'
want_checkout="{\"fetch-depth\": 0, \"persist-credentials\": false, \"ref\": \"$HEAD_REF\"}"
for job in commit-identity secret-scan; do
	check "$job checks out the head with the whole history and no token" "1" \
		"$(shipped "$job" | grep -cF "[null, $want_checkout]")"
	check "$job is given the base and the head of the event and nothing else" "1" \
		"$(shipped "$job" | grep -cF "[{\"BASE\": \"$BASE_REF\", \"HEAD\": \"$HEAD_REF\"}, null]")"
done

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
