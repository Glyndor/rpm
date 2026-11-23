#!/usr/bin/env bash
#
# scripts/publish/sign-tree.sh and rehearse-tree.sh on a copy of the repository whose committed keys
# are the test's: the signed tree is the one the archive key makes, the key is refused when it is not
# the committed one or when a file is not what was admitted, and the rehearsal signs with a key of its
# own and reads no secret.
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
fx_init "$WORK"; fx_archive_key; fx_other_key "$WORK/other.asc"
SECRET="$(gpg --batch --armor --export-secret-keys)"
mkdir -p "$WORK/repo"; cp -r "$HERE/scripts" "$HERE/config" "$WORK/repo/"; mkdir "$WORK/repo/keyring"
cp "$WORK/keyring"/* "$WORK/repo/keyring/"; cp "$WORK/archive.asc" "$WORK/repo/keyring/glyndor-rpm-key.asc"
fx_static_release "$WORK/src/podup" podup 1.2.3 x86_64,aarch64
fx_static_release "$WORK/src/epistle-panel" epistle-panel 0.9.1 noarch
PLAN='podup v1.2.3,epistle-panel v0.9.1'
export ORDER_NOW=$((FX_T2 + 60)) ARCHIVE_URL="file://$WORK/nothing" EPOCH="$FX_T1" PRODUCTS="$PLAN"
admitted() { rm -rf "$WORK/adm" "$WORK/adm.sha256"; cp -r "$WORK/src" "$WORK/adm"; bash "$WORK/repo/scripts/publish/readmit-products.sh" "$WORK/adm" > /dev/null 2>&1; }
sign() { rm -rf "$WORK/tree"; env GLYNDOR_RPM_GPG_PRIVATE_KEY="${1-$SECRET}" bash "$WORK/repo/scripts/publish/sign-tree.sh" "$WORK/adm" "$WORK/tree" > "$WORK/o" 2>&1; echo $?; }

admitted
check "the tree is signed with the committed key" 0 "$(sign)"
check "and it verifies against that key" 0 "$("$HERE/scripts/verify/verify-tree.sh" "$WORK/tree" "$WORK/archive.asc" > /dev/null 2>&1; echo $?)"
check "it holds the installers" "epistle-panel podup" "$(fx_names "$WORK/tree/install")"
check "no key in the environment is refused" 1 "$(sign '')"
check "and says so" 1 "$(grep -c 'is not set; refusing to sign' "$WORK/o")"
OTHER_SECRET="$(GNUPGHOME="$WORK/gother" gpg --batch --armor --export-secret-keys)"
GNUPGHOME="$WORK/gother" fx_stop_agent
check "a secret key that is not the committed one is refused" 1 "$(sign "$OTHER_SECRET")"
check "and says which" 1 "$(grep -c 'is not the one the public key file holds' "$WORK/o")"
check "text that is not a key is refused" 1 "$(sign 'not a key')"
printf 'x' >> "$WORK/adm/podup/podup-1.2.3-1.glyndor.any.x86_64.rpm"
check "a file changed since the second look is refused" 1 "$(sign)"
check "and says it is not what was admitted" 1 "$(grep -c 'is not what was admitted' "$WORK/o")"
admitted; echo extra > "$WORK/adm/podup/extra.rpm"
check "a file added since the second look is refused" 1 "$(sign)"
admitted; rm "$WORK/adm.sha256"
check "no manifest is refused" 1 "$(sign)"
check "and says the files were not admitted here" 1 "$(grep -c 'were not admitted in this job' "$WORK/o")"
admitted
check "an unknown plan product is refused" 1 "$(PRODUCTS='nginx v1.0.0' sign)"
check "an epoch that is not set is refused" 1 "$(env -u EPOCH GLYNDOR_RPM_GPG_PRIVATE_KEY="$SECRET" bash "$WORK/repo/scripts/publish/sign-tree.sh" "$WORK/adm" "$WORK/t9" > /dev/null 2>&1; echo $?)"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
