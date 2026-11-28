#!/usr/bin/env bash
#
# scripts/publish/readmit-products.sh with a stand-in for gh: the plan is
# the job that signs looks again with no key around and records what it saw.
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
export PATH="$WORK/bin:$PATH" FAKE_GH_LOG="$WORK/log" FAKE_GH_SRC="$WORK/src" FAKE_GH_VIEW="$WORK/view.json"
printf '{"tagName":"v1.2.3","assets":[{"name":"%s.x86_64.rpm","size":4},{"name":"%s.x86_64.rpm.sig","size":4},{"name":"%s.aarch64.rpm","size":4},{"name":"%s.aarch64.rpm.sig","size":4}]}' \
	"$R" "$R" "$R" "$R" > "$WORK/view.json"
adm() { rm -rf "$WORK/out" "$WORK/out.sha256"; PRODUCTS="$1" bash "$WORK/repo/scripts/publish/admit-products.sh" "$WORK/out" > "$WORK/o" 2>&1; echo $?; }

# --- the second look, in the job that signs -----------------------------------------------------
rm -rf "$WORK/adm"; mkdir -p "$WORK/adm/podup"; cp "$WORK/src"/* "$WORK/adm/podup/"
readmit() { PRODUCTS="$1" bash "$WORK/repo/scripts/publish/readmit-products.sh" "$WORK/adm" > "$WORK/o" 2>&1; echo $?; }
check "the second look admits and records the hashes" 0 "$(readmit 'podup v1.2.3')"
check "the manifest is beside the folder, not in it" 1 "$([ -f "$WORK/adm.sha256" ] && [ ! -e "$WORK/adm/adm.sha256" ] && echo 1 || echo 0)"
check "it lists every file once" 4 "$(wc -l < "$WORK/adm.sha256")"
check "its names are relative to the folder" 4 "$(grep -c '  \./podup/' "$WORK/adm.sha256")"
mkdir "$WORK/adm/other"; rc="$(readmit 'podup v1.2.3')"; rmdir "$WORK/adm/other"
check "a folder the plan does not name is refused" 1 "$rc"
check "a plan with a product that has no folder is refused" 1 "$(readmit 'podup v1.2.3,podman v6.2.0')"
check "a changed package is refused" 1 "$(printf 'x' >> "$WORK/adm/podup/$R.x86_64.rpm"; readmit 'podup v1.2.3')"
check "an environment that already holds the archive key is refused" 1 "$(GLYNDOR_RPM_GPG_PRIVATE_KEY=x readmit 'podup v1.2.3')"
check "a missing folder is refused" 1 "$(PRODUCTS='podup v1.2.3' bash "$WORK/repo/scripts/publish/readmit-products.sh" "$WORK/none" > /dev/null 2>&1; echo $?)"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
