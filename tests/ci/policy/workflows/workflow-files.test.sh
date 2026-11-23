#!/usr/bin/env bash
#
# What a validator does not list, it does not compare, and GitHub runs it all the same:
# a workflow with the .yaml suffix, one nested in a folder, an action.yml under a
# folder nobody looks at. What a validator reads with a lenient loader, it reads as
# something other than what GitHub runs: a key written twice keeps the last one in
# PyYAML. So the workflows and the actions of this repository are listed in one place
# (tests/fixtures/ci/workflow-files.py), read with a loader that refuses a repeated key,
# and held to three rules:
#
#   * every one of them parses, and a key is never written twice in one mapping;
#   * every workflow is a `.yml` directly in .github/workflows, because the validators of
#     this repository glob `*.yml` there and a workflow they do not see is not judged;
#   * there is no action.yml or action.yaml in the tree: the repository has no composite
#     action, and one added would be run without being read by anything that judges
#     workflows.
#
# No security tool is restored from a cache either. A tool that judges a change is
# downloaded in every run from its release and checked against its SHA-256 before it
# runs; a cache keeps what an earlier run left, and a poisoned entry would be restored
# into every later job. So no workflow uses actions/cache or an action's `cache:` input,
# and no file under .github/workflows names a restore key.
#
# The rules are run over planted trees first, one defect each, then over this repository.
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

# One line per offence in the tree at $1.
audit() { # $1=root
	python3 -I - "$1" "$HERE/tests/fixtures/ci/workflow-files.py" <<'PY'
import os
import sys

root, helper = sys.argv[1:3]
exec(open(helper).read())
files = enumerate_files(root)
if not any(f.startswith(".github/workflows/") for f in files):
    print("no workflow was found, so nothing was judged")
for path in files:
    try:
        spec = load(root, path)
    except Exception as error:  # the message is the finding
        print(f"{path}: {str(error).splitlines()[0] if str(error) else type(error).__name__}"
              + (f" ({str(error).splitlines()[-1].strip()})" if len(str(error).splitlines()) > 1 else ""))
        continue
    name = os.path.basename(path)
    if name in ("action.yml", "action.yaml"):
        print(f"{path}: an action, and this repository has none")
        continue
    if not path.endswith(".yml") or path.count("/") != 2:
        print(f"{path}: not a .yml directly in .github/workflows, where the validators look")
    text = open(os.path.join(root, path)).read()
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if stripped.split("@")[0].replace("- ", "").strip() == "uses: actions/cache" or "restore-keys" in stripped:
            print(f"{path}: restores something from a cache")
        if stripped.startswith("cache:") or stripped.startswith("- cache:"):
            print(f"{path}: an action input that caches")
PY
}

plant() { # <name> <relative path> <text>
	mkdir -p "$WORK/$1/$(dirname "$2")"
	printf '%s\n' "$3" > "$WORK/$1/$2"
	echo "$WORK/$1"
}

GOOD='on: pull_request
jobs:
  j:
    runs-on: x
    steps: []'
check "a plain workflow passes" "" "$(audit "$(plant ok .github/workflows/a.yml "$GOOD")")"
check "a tree with no workflow is not a pass" "no workflow was found, so nothing was judged" "$(audit "$WORK/empty")"
check "a key written twice in one mapping is reported" "1" \
	"$(audit "$(plant dup .github/workflows/a.yml 'on: pull_request
jobs:
  j:
    runs-on: x
    if: true
    if: false
    steps: []')" | grep -c 'written twice')"
check "a workflow with the .yaml suffix is reported" ".github/workflows/a.yaml: not a .yml directly in .github/workflows, where the validators look" \
	"$(audit "$(plant yaml .github/workflows/a.yaml "$GOOD")" | grep -v 'no workflow')"
check "a workflow in a folder is reported" ".github/workflows/sub/a.yml: not a .yml directly in .github/workflows, where the validators look" \
	"$(audit "$(plant nested .github/workflows/sub/a.yml "$GOOD")" | grep -v 'no workflow')"
d="$(plant action .github/workflows/a.yml "$GOOD")"
mkdir -p "$d/deep/er"
printf 'runs: {using: composite, steps: []}\n' > "$d/deep/er/action.yaml"
check "an action.yaml deep in the tree is reported" "deep/er/action.yaml: an action, and this repository has none" "$(audit "$d")"
printf 'runs: {using: composite, steps: []}\n' > "$d/action.yml"
check "an action.yml at the root is reported too" "1" "$(audit "$d" | grep -c '^action.yml: an action')"
check "a file that is not YAML is reported" "1" "$(audit "$(plant broken .github/workflows/a.yml 'jobs: [')" | grep -c '^.github/workflows/a.yml:')"
check "actions/cache is reported" ".github/workflows/a.yml: restores something from a cache" \
	"$(audit "$(plant cache .github/workflows/a.yml 'on: pull_request
jobs:
  j:
    runs-on: x
    steps:
      - uses: actions/cache@0000000000000000000000000000000000000000')")"
check "restore-keys is reported" ".github/workflows/a.yml: restores something from a cache" \
	"$(audit "$(plant restore .github/workflows/a.yml 'on: pull_request
jobs:
  j:
    runs-on: x
    steps:
      - run: echo restore-keys')" | sort -u)"
check "a cache: input of an action is reported" ".github/workflows/a.yml: an action input that caches" \
	"$(audit "$(plant input .github/workflows/a.yml 'on: pull_request
jobs:
  j:
    runs-on: x
    steps:
      - uses: actions/setup-python@0000000000000000000000000000000000000000
        with:
          cache: pip')")"

check "the workflows and actions of this repository pass" "" "$(audit "$HERE")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
