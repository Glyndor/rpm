#!/usr/bin/env bash
#
# .github/dependabot.yml says which manifests Dependabot watches. It fails in three
# quiet ways, and each leaves a repository that looks watched and is not:
#
#   * an ecosystem the repository really has (a workflow that uses an action, a
#     requirements file, a package.json, a Dockerfile) with no entry, so its
#     updates never arrive;
#   * an entry for an ecosystem or a folder the repository no longer has, which
#     keeps a promise nothing can keep;
#   * groups that put a major version in with the patch and minor ones, so a change
#     of major version rides along with a routine bump and is not read on its own.
#
# Every entry also has to carry the label the project filters on (`type:deps`).
#
# The rule reads the tree, so it is run over planted trees first, each with one
# defect and a passing twin beside it, and then over this repository.
#
# Requires: python3 with PyYAML, git.
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

# One line per offence in the tree at $1, nothing when the configuration is sound.
audit() { # $1=repository root
	python3 -I - "$1" <<'PY'
import os
import re
import subprocess
import sys

import yaml

root = sys.argv[1]
listed = subprocess.run(["git", "-C", root, "ls-files", "-z"], check=True,
                        stdout=subprocess.PIPE).stdout.decode().split("\0")
files = [f for f in listed if f]
problems = []

# What the tree has, by ecosystem: the folder that holds its manifest.
MANIFESTS = {
    "pip": re.compile(r"(^|/)(requirements[^/]*\.txt|pyproject\.toml|Pipfile)$"),
    "npm": re.compile(r"(^|/)package\.json$"),
    "cargo": re.compile(r"(^|/)Cargo\.toml$"),
    "gomod": re.compile(r"(^|/)go\.mod$"),
    "docker": re.compile(r"(^|/)(Dockerfile[^/]*|Containerfile[^/]*)$"),
}
present = {}
for name, pattern in MANIFESTS.items():
    folders = sorted({"/" + os.path.dirname(f) if os.path.dirname(f) else "/" for f in files if pattern.search(f)})
    if folders:
        present[name] = folders
uses_action = False
for f in files:
    if re.fullmatch(r"\.github/workflows/[^/]+\.ya?ml", f):
        with open(os.path.join(root, f)) as fh:
            for line in fh:
                found = re.match(r"\s*(?:-\s+)?uses:\s*([^\s#]+)", line)
                if found and not found.group(1).startswith("./"):
                    uses_action = True
if uses_action:
    present["github-actions"] = ["/"]

path = os.path.join(root, ".github/dependabot.yml")
if not os.path.isfile(path):
    print("there is no .github/dependabot.yml")
    sys.exit(0)
with open(path) as fh:
    config = yaml.safe_load(fh) or {}
entries = config.get("updates") or []
if not entries:
    print("dependabot.yml has no updates entry")
watched = {}
for entry in entries:
    eco = entry.get("package-ecosystem")
    directory = entry.get("directory", "")
    watched.setdefault(eco, set()).add(directory)
    where = f"{eco} {directory}"
    if "type:deps" not in (entry.get("labels") or []):
        problems.append(f"{where}: the label type:deps is missing")
    if not (entry.get("schedule") or {}).get("interval"):
        problems.append(f"{where}: no schedule interval")
    groups = entry.get("groups") or {}
    if not groups:
        problems.append(f"{where}: no groups, so every update is a pull request of its own")
    majors = [name for name, group in groups.items() if "major" in (group.get("update-types") or [])]
    mixed = [name for name, group in groups.items()
             if not group.get("update-types") or
             ("major" in group["update-types"] and set(group["update-types"]) - {"major"})]
    for name in sorted(mixed):
        problems.append(f"{where}: group {name} puts major versions together with minor or patch ones")
    if groups and not majors and not mixed:
        problems.append(f"{where}: no group takes the major versions, so they open one pull request each")
    if not (entry.get("commit-message") or {}).get("prefix"):
        problems.append(f"{where}: no commit-message prefix")
    if eco in present and directory not in present[eco]:
        problems.append(f"{where}: no manifest of that kind in that folder")
    if eco not in present:
        problems.append(f"{where}: the repository has nothing of that ecosystem")
for eco, folders in sorted(present.items()):
    for folder in folders:
        if folder not in watched.get(eco, set()):
            problems.append(f"{eco} {folder}: the repository has it and dependabot.yml does not watch it")
print("\n".join(sorted(set(problems))))
PY
}

tree() { # <name> <dependabot.yml text> [extra file path ...]: a git tree with one workflow that uses an action
	local dir="$WORK/$1"
	mkdir -p "$dir/.github/workflows"
	git -C "$dir" init -q
	printf 'jobs:\n  j:\n    steps:\n      - uses: actions/checkout@0000000000000000000000000000000000000000 # v1\n' > "$dir/.github/workflows/a.yml"
	printf '%s\n' "$2" > "$dir/.github/dependabot.yml"
	shift 2
	local f
	for f in "$@"; do mkdir -p "$dir/$(dirname "$f")"; : > "$dir/$f"; done
	git -C "$dir" add -A
	echo "$dir"
}

GOOD='version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "daily"
    labels: ["type:deps", "type:ci"]
    groups:
      minor-patch:
        patterns: ["*"]
        update-types: ["minor", "patch"]
      major:
        patterns: ["*"]
        update-types: ["major"]
    commit-message:
      prefix: chore'

check "a repository with one workflow and a sound entry passes" "" "$(audit "$(tree good "$GOOD")")"

none='version: 2
updates: []'
check "an empty updates list is reported, and the action it leaves unwatched" \
	"$(printf 'dependabot.yml has no updates entry\ngithub-actions /: the repository has it and dependabot.yml does not watch it')" \
	"$(audit "$(tree none "$none")")"

check "a requirements file with no pip entry is reported" \
	"pip /scripts/verify: the repository has it and dependabot.yml does not watch it" \
	"$(audit "$(tree pip "$GOOD" scripts/verify/requirements.txt)")"

stale="$GOOD
  - package-ecosystem: \"npm\"
    directory: \"/\"
    schedule:
      interval: \"daily\"
    labels: [\"type:deps\"]
    groups:
      minor-patch:
        patterns: [\"*\"]
        update-types: [\"minor\", \"patch\"]
      major:
        patterns: [\"*\"]
        update-types: [\"major\"]
    commit-message:
      prefix: chore"
check "an entry for an ecosystem the repository does not have is reported" \
	"npm /: the repository has nothing of that ecosystem" "$(audit "$(tree stale "$stale")")"
check "the same entry is fine once a package.json exists" "" "$(audit "$(tree stale-ok "$stale" package.json)")"

moved="${GOOD//'directory: "/"'/'directory: "/gone"'}"
check "an entry for a folder with no manifest is reported, and the real one is unwatched" \
	"$(printf 'github-actions /: the repository has it and dependabot.yml does not watch it\ngithub-actions /gone: no manifest of that kind in that folder')" \
	"$(audit "$(tree moved "$moved")")"

mixed="${GOOD//'update-types: ["minor", "patch"]'/'update-types: ["minor", "patch", "major"]'}"
check "a group that holds minor, patch and major together is reported" \
	"github-actions /: group minor-patch puts major versions together with minor or patch ones" \
	"$(audit "$(tree mixed "$mixed")")"

untyped="${GOOD//'        update-types: ["minor", "patch"]'/'        ignore: []'}"
check "a group with no update-types takes everything and is reported" \
	"github-actions /: group minor-patch puts major versions together with minor or patch ones" \
	"$(audit "$(tree untyped "$untyped")")"

nomajor="${GOOD//'update-types: ["major"]'/'update-types: ["minor"]'}"
check "no group for the major versions is reported" \
	"github-actions /: no group takes the major versions, so they open one pull request each" \
	"$(audit "$(tree nomajor "$nomajor")")"

nolabel="${GOOD//'"type:deps", '/}"
check "a missing type:deps label is reported" "github-actions /: the label type:deps is missing" \
	"$(audit "$(tree nolabel "$nolabel")")"

noprefix="${GOOD//    commit-message:
      prefix: chore/}"
check "a missing commit prefix is reported" "github-actions /: no commit-message prefix" \
	"$(audit "$(tree noprefix "$noprefix")")"

dir="$(tree nofile "$GOOD")"
rm "$dir/.github/dependabot.yml"
check "no dependabot.yml at all is reported" "there is no .github/dependabot.yml" "$(audit "$dir")"

check "this repository's configuration is sound" "" "$(audit "$HERE")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
