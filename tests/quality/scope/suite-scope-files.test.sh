#!/usr/bin/env bash
#
# The map says which suites a change to a file can affect. Its other half is the set of
# files for which it says "no suite needs to run", and that half is where a change merges
# unjudged, so it is not left to be whatever the patterns happen to leave over: it is
# written here, file by file, and the test fails when it differs.
#
# For every tracked file this runs the resolver the way a pull request does, over a real
# merge commit that changes only that file, with the map this repository ships, and reads
# which suites it keeps. Three things are asserted from that:
#
#   * The files whose change keeps no suite but the ones that walk the whole tree are
#     exactly the list below. A file moved into that list, or a new file that lands in
#     it, turns this red; a workflow or a script is not in it.
#   * A script runs the suite of the same name, one folder of tests/ below the same
#     path: scripts/<area>/<name>.sh keeps tests/<area>/<name>.test.sh, and a reusable
#     workflow keeps the suite of its own.
#   * The workflow that wires the checks keeps the suites that watch the wiring.
#
# The planted maps then drop one pattern each and the same reading has to name the file.
#
# Requires: bash, git, python3 with PyYAML.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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

# The files a change to which keeps only the suites that walk the whole tree. Each one is
# here because nothing reads it but the check of .editorconfig, and the map of paths
# against the tree: the licence, the ignore list, an empty folder's placeholder, the
# editor settings, and the README until a suite reads the key it names.
INERT="$(cat <<'EOF'
.editorconfig
.gitignore
LICENSE
README.md
docs/.gitkeep
EOF
)"

# files_and_kept <map file>: "<file>\t<suites kept, space separated>" for every tracked
# file. The repository is a copy of the tracked tree with placeholder contents, a base
# commit, and for each file a merge commit that changes that file and nothing else.
files_and_kept() { # $1=map
	python3 -I - "$HERE" "$1" "$WORK" <<'PY'
import os
import subprocess
import sys

here, map_path, work = sys.argv[1:4]
repo = os.path.join(work, "repo")


def git(*args, check=True, **kw):
    return subprocess.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@e.invalid",
                           "-c", "commit.gpgsign=false", *args], check=check,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw)


tracked = subprocess.run(["git", "-C", here, "ls-files", "-z"], check=True,
                         stdout=subprocess.PIPE).stdout.decode().split("\0")
tracked = [f for f in tracked if f]
suites = [f for f in tracked if f.startswith("tests/") and f.endswith(".test.sh")]
suites = [s for s in suites if s != "tests/ci/suites/check-suite-completeness.test.sh"]
subprocess.run(["rm", "-rf", repo], check=True)
os.makedirs(repo)
subprocess.run(["git", "-C", repo, "init", "-q", "-b", "main"], check=True)
for f in tracked:
    dest = os.path.join(repo, f)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "w") as fh:
        fh.write("placeholder\n")
for f in ("scripts/quality/scope/ci-job-scope.sh", "tests/ci/suites/check-suite-completeness.test.sh"):
    subprocess.run(["cp", os.path.join(here, f), os.path.join(repo, f)], check=True)
subprocess.run(["cp", map_path, os.path.join(repo, "scripts/quality/scope/suite-scope.txt")], check=True)
git("add", "-A")
git("commit", "-qm", "base")
base = git("rev-parse", "HEAD").stdout.decode().strip()
GLOBAL = {"scripts/quality/scope/ci-job-scope.sh", "scripts/quality/scope/suite-scope.txt",
          "tests/ci/suites/check-suite-completeness.test.sh"}
for f in tracked:
    if f in GLOBAL:
        continue
    git("checkout", "-q", "--detach", base)
    git("checkout", "-q", "-b", "pr")
    with open(os.path.join(repo, f), "a") as fh:
        fh.write("changed\n")
    git("commit", "-qam", "change")
    git("checkout", "-q", "--detach", base)
    git("merge", "-q", "--no-ff", "pr", "-m", "merge")
    done = subprocess.run(["bash", "scripts/quality/scope/ci-job-scope.sh", "suites", *suites], cwd=repo,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    print(f + "\t" + " ".join(done.stdout.decode().split()) + ("" if done.returncode == 0 else "\tFAILED"))
    git("branch", "-qD", "pr")
PY
}

# walkers <map>: the suites whose entry is the whole tree.
walkers() {
	python3 -I - "$1" <<'PY'
import sys

suite = None
entries = {}
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if line[:1].isspace():
        entries[suite].append(line.strip())
    else:
        suite = line.strip()
        entries[suite] = []
print(" ".join(sorted(s for s, p in entries.items() if p == ["**"])))
PY
}

# offences <map>: one line per breach of the three assertions, nothing when it holds.
offences() { # $1=map
	local map="$1" listing walk
	walk="$(walkers "$map")"
	listing="$(files_and_kept "$map")"
	python3 -I - "$walk" "$INERT" <<PY
import sys

walkers = set(sys.argv[1].split())
inert = set(sys.argv[2].split("\n"))
rows = {}
for line in """$listing""".splitlines():
    name, _, kept = line.partition("\t")
    rows[name] = kept
problems = []
for name, kept in sorted(rows.items()):
    if kept.endswith("FAILED"):
        problems.append(f"{name}: the resolver failed")
        continue
    kept = set(kept.split())
    only_walkers = kept <= walkers
    if only_walkers and name not in inert:
        problems.append(f"{name}: a change to it keeps no suite but the ones that walk the tree")
    if not only_walkers and name in inert:
        problems.append(f"{name}: is listed as inert and keeps {', '.join(sorted(kept - walkers))}")
    parts = name.split("/")
    if name.endswith(".sh") and name.startswith("scripts/") and len(parts) > 2:
        own = "tests/" + "/".join(parts[1:])[:-3] + ".test.sh"
        if own in rows and own not in kept:
            problems.append(f"{name}: a change to it does not keep {own}")
    if name.startswith(".github/workflows/reusable-") and name.endswith(".yml"):
        own = "tests/ci/reusable/" + parts[-1][:-4] + ".test.sh"
        if own not in kept:
            problems.append(f"{name}: a change to it does not keep {own}")
    if name == ".github/workflows/tests.yml":
        for want in ("tests/ci/policy/workflows/gate-job.test.sh", "tests/ci/suites/ci-runs-every-test.test.sh",
                     "tests/quality/coverage/check-suites-wired.test.sh",
                     "tests/quality/scope/suite-scope-map.test.sh", "tests/ci/reusable/reusable-shell-ci.test.sh"):
            if want not in kept:
                problems.append(f"{name}: a change to it does not keep {want}")
print("\n".join(problems))
PY
}

MAP="$HERE/scripts/quality/scope/suite-scope.txt"
check "every tracked file is either inert, as listed here, or keeps the suite that reads it" "" "$(offences "$MAP")"

# Plant one dropped pattern at a time. A pattern is dropped from the entry of one suite and
# the offence has to name the file that lost its suite.
drop() { # <suite> <pattern>: the map with that pattern removed from that suite's entry
	python3 -I - "$MAP" "$1" "$2" > "$WORK/planted.txt" <<'PY'
import sys

path, suite, pattern = sys.argv[1:4]
current = None
out = []
removed = 0
for line in open(path):
    if line[:1] not in ("\t", " ", "\n", "#") and line.strip():
        current = line.strip()
    if current == suite and line.strip() == pattern and line[:1].isspace():
        removed += 1
        continue
    out.append(line)
if not removed:
    sys.exit(f"nothing to drop: {pattern} is not in the entry of {suite}")
sys.stdout.write("".join(out))
PY
}

drop tests/ci/policy/workflows/gate-job.test.sh .github/workflows/tests.yml
check "dropping tests.yml from the suite that holds the gate is reported" \
	".github/workflows/tests.yml: a change to it does not keep tests/ci/policy/workflows/gate-job.test.sh" \
	"$(offences "$WORK/planted.txt" | grep 'gate-job')"

drop tests/ci/suites/ci-runs-every-test.test.sh '.github/workflows/**'
check "dropping the workflows from the suite that watches them is reported" \
	".github/workflows/tests.yml: a change to it does not keep tests/ci/suites/ci-runs-every-test.test.sh" \
	"$(offences "$WORK/planted.txt" | grep 'ci-runs-every-test' | head -1)"

drop tests/quality/hygiene/check-secrets.test.sh scripts/quality/hygiene/check-secrets.sh
check "dropping a script from the entry of its own suite is reported" \
	"scripts/quality/hygiene/check-secrets.sh: a change to it does not keep tests/quality/hygiene/check-secrets.test.sh" \
	"$(offences "$WORK/planted.txt" | grep 'check-secrets')"

drop tests/ci/reusable/reusable-dco.test.sh .github/workflows/reusable-dco.yml
check "dropping a reusable from the entry of its own suite is reported" \
	".github/workflows/reusable-dco.yml: a change to it does not keep tests/ci/reusable/reusable-dco.test.sh" \
	"$(offences "$WORK/planted.txt" | grep 'reusable-dco')"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
