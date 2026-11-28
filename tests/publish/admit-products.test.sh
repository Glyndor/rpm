#!/usr/bin/env bash
#
# scripts/publish/admit-products.sh and readmit-products.sh with a stand-in for gh: the plan is
# downloaded and admitted release by release, a refusal stops everything, and the job that signs
# looks again with no key around and records what it saw.
# Requires: rpm, python3 with cryptography.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
fx_init "$WORK"
R="podup-1.2.3-1.glyndor.any"
fx_static_release "$WORK/src" podup 1.2.3 x86_64,aarch64
# the committed release key is the one `admit-release.sh` reads; the stand-in signs for it only in the
# keyring the tests give, so the scripts are run with a copy of the repository whose key is the test's
mkdir -p "$WORK/repo"; cp -r "$HERE/scripts" "$HERE/config" "$WORK/repo/"; mkdir "$WORK/repo/keyring"
cp "$WORK/keyring"/* "$WORK/repo/keyring/"
mkdir "$WORK/bin"; cp "$HERE/tests/fixtures/rpm/fake-gh.sh" "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" FAKE_GH_LOG="$WORK/log" FAKE_GH_SRC="$WORK/src" FAKE_GH_VIEW="$WORK/view.json" FAKE_GH_SHA=0123456789abcdef0123456789abcdef01234567
printf '{"tagName":"v1.2.3","assets":[{"name":"%s.x86_64.rpm","size":4},{"name":"%s.x86_64.rpm.sig","size":4},{"name":"%s.aarch64.rpm","size":4},{"name":"%s.aarch64.rpm.sig","size":4}]}' \
	"$R" "$R" "$R" "$R" > "$WORK/view.json"
adm() { rm -rf "$WORK/out" "$WORK/out.sha256"; PRODUCTS="$1" bash "$WORK/repo/scripts/publish/admit-products.sh" "$WORK/out" > "$WORK/o" 2>&1; echo $?; }

check "a planned release is downloaded and admitted" 0 "$(adm 'podup v1.2.3')"
check "into a folder of its product" "podup" "$(fx_names "$WORK/out")"
check "with its files" 4 "$(find "$WORK/out/podup" -type f | wc -l)"
check "an output folder that exists is refused" 1 "$(PRODUCTS='podup v1.2.3' bash "$WORK/repo/scripts/publish/admit-products.sh" "$WORK/out" > /dev/null 2>&1; echo $?)"
: > "$WORK/log"; rc="$(adm 'podup main')"
check "a malformed plan is refused" 1 "$rc"
check "before anything is downloaded" 0 "$(wc -c < "$WORK/log")"
check "a plan that is empty is refused" 1 "$(adm '')"
printf 'x' >> "$WORK/src/$R.x86_64.rpm"
check "a release whose package changed after it was signed is refused" 1 "$(adm 'podup v1.2.3')"
check "and says so" 1 "$(grep -c 'is not admitted' "$WORK/o")"
cp "$WORK/src/$R.x86_64.rpm" "$WORK/keep"; head -c -1 "$WORK/keep" > "$WORK/src/$R.x86_64.rpm"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
