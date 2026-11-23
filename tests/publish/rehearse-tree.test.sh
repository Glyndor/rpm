#!/usr/bin/env bash
#
# scripts/publish/rehearse-tree.sh on a copy of the repository whose committed keys
# are the test's: the rehearsal signs with a key of its own, checks the order against the committed
# one, and reads no secret.
# Requires: rpm, createrepo_c, gpg, python3 with cryptography.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/tree.sh"
WORK="$(mktemp -d)"
trap 'fx_stop_agent; rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
fx_init "$WORK"; fx_archive_key
mkdir -p "$WORK/repo"; cp -r "$HERE/scripts" "$HERE/config" "$WORK/repo/"; mkdir "$WORK/repo/keyring"
cp "$WORK/keyring"/* "$WORK/repo/keyring/"; cp "$WORK/archive.asc" "$WORK/repo/keyring/glyndor-rpm-key.asc"
fx_static_release "$WORK/src/podup" podup 1.2.3 x86_64,aarch64
fx_static_release "$WORK/src/epistle-panel" epistle-panel 0.9.1 noarch
PLAN='podup v1.2.3,epistle-panel v0.9.1'
export ORDER_NOW=$((FX_T2 + 60)) ARCHIVE_URL="file://$WORK/nothing" EPOCH="$FX_T1" PRODUCTS="$PLAN"
admitted() { rm -rf "$WORK/adm" "$WORK/adm.sha256"; cp -r "$WORK/src" "$WORK/adm"; bash "$WORK/repo/scripts/publish/readmit-products.sh" "$WORK/adm" > /dev/null 2>&1; }
# --- the rehearsal --------------------------------------------------------------------------------
reh() { rm -rf "$WORK/rtree"; env "$@" bash "$WORK/repo/scripts/publish/rehearse-tree.sh" "$WORK/adm" "$WORK/rtree" > "$WORK/o" 2>&1; echo $?; }
admitted
EPOCH="$(date +%s)"; ORDER_NOW="$((EPOCH + 30))"; export EPOCH ORDER_NOW
check "the rehearsal builds a tree" 0 "$(reh PRODUCTS="$PLAN")"
check "the throwaway key signed it, not the committed one" 1 "$(gpg --batch --show-keys --with-colons "$WORK/rtree/glyndor-rpm-key.asc" | awk -F: '$1 == "fpr" { print $10; exit }' | grep -vc "$(gpg --batch --show-keys --with-colons "$WORK/archive.asc" | awk -F: '$1 == "fpr" { print $10; exit }')")"
check "the rehearsal refuses an environment that holds the archive key" 1 "$(reh PRODUCTS="$PLAN" GLYNDOR_RPM_GPG_PRIVATE_KEY=x)"
check "and says it reads no secret" 1 "$(grep -c 'reads no secret' "$WORK/o")"
check "a rehearsal with no plan is refused" 1 "$(reh PRODUCTS=)"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
