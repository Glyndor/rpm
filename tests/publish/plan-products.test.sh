#!/usr/bin/env bash
#
# scripts/publish/plan-products.sh with stand-ins for gh and for what the repository serves: which
# products make the plan, what is skipped, and the refusal to drop a product that is served.
# Requires: rpm, createrepo_c, gpg, jq, python3 with cryptography.
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
cp "$WORK/archive.asc" "$WORK/repo/keyring/glyndor-rpm-key.asc"
mkdir -p "$WORK/bin"
# a gh that answers per repository from $FAKE_RELEASES/<product>.json: a repository whose one
# release is that, listed and viewed
cat > "$WORK/bin/gh" <<'SH'
#!/bin/sh
case "$2" in
	list) repo="${4#Glyndor/}" ;;
	view) repo="${5#Glyndor/}" ;;
	*) exit 2 ;;
esac
file="$FAKE_RELEASES/$repo.json"
[ -f "$file" ] || exit 1
if [ "$2" = list ]; then jq -c '[{tagName, isLatest: true}]' "$file"; else cat "$file"; fi
SH
chmod +x "$WORK/bin/gh"
mkdir "$WORK/rel"
export PATH="$WORK/bin:$PATH" FAKE_RELEASES="$WORK/rel"
release() { printf '{"tagName":"%s","assets":[%s]}' "$2" "$3" > "$WORK/rel/$1.json"; }
RPM='{"name":"x-1-1.glyndor.any.x86_64.rpm","size":4}'
for p in podman podup epistle helmly-agent helmly epistle-panel; do release "$p" v1.0.0 '{"name":"notes.txt","size":1}'; done
plan() { ARCHIVE_URL="${1:-file://$WORK/nothing}" bash "$WORK/repo/scripts/publish/plan-products.sh" 2> "$WORK/err"; }

rm "$WORK/repo/config/products.txt"
plan > "$WORK/out"; status=$?
check "a missing product list stops the run" 1 "$status"
check "a missing product list reports the error" 1 "$(grep -c 'config/products.txt cannot be read or lists no product' "$WORK/err")"
check "a missing product list emits no plan" "" "$(cat "$WORK/out")"

printf '# products\n\n  # still no products\n' > "$WORK/repo/config/products.txt"
plan > "$WORK/out"; status=$?
check "an empty product list stops the run" 1 "$status"
check "an empty product list reports the error" 1 "$(grep -c 'config/products.txt cannot be read or lists no product' "$WORK/err")"
check "an empty product list emits no plan" "" "$(cat "$WORK/out")"
cp "$HERE/config/products.txt" "$WORK/repo/config/products.txt"

check "nothing is planned while no release carries an rpm" "" "$(plan)"
check "and each product is skipped with a notice" 6 "$(grep -c '::notice::' "$WORK/err")"
release podup v1.2.3 "$RPM"; release epistle v0.4.0 "$RPM,{\"name\":\"y.deb\",\"size\":2}"
check "a product with an rpm in its latest release is planned, with its tag" "epistle v0.4.0
podup v1.2.3" "$(plan | sort)"
release podman v6.2.0+r12 "$RPM"
check "a podman tag with a revision is read" 1 "$(plan | grep -c '^podman v6.2.0+r12$')"
release podup main "$RPM"
check "a release whose tag is not a version is never planned" 0 "$(plan | grep -c '^podup ')"
release podup v1.2.3 "$RPM"
rm "$WORK/rel/epistle.json"
check "a product whose release cannot be read stops the run" 1 "$(plan > /dev/null 2>&1; echo $?)"
release epistle v0.4.0 "$RPM"

# a product that is served and whose release lost its rpm, or its version tag
mkdir -p "$WORK/in/podup"; fx_static_release "$WORK/in/podup" podup 1.2.3 x86_64,aarch64; rm -f "$WORK"/in/podup/*.sig
fx_build_tree "$WORK/served" "$FX_T1" "$WORK/in" > /dev/null 2>&1
release podup v1.2.4 '{"name":"notes.txt","size":1}'
check "a served product whose latest release has no rpm stops the run" 1 "$(plan "file://$WORK/served" > /dev/null 2>&1; echo $?)"
plan "file://$WORK/served" > /dev/null 2>&1 || true
check "and says it will not drop it" 1 "$(grep -c 'refusing to drop it' "$WORK/err")"
release podup main "$RPM"
check "a served product with no version release stops the run" 1 "$(plan "file://$WORK/served" > /dev/null 2>&1; echo $?)"
plan "file://$WORK/served" > /dev/null 2>&1 || true
check "and says why it will not drop it" 1 "$(grep -c 'podup is served and it has no version release; refusing to drop it' "$WORK/err")"
release podup v1.2.4 "$RPM"
check "once the release carries one again it is planned" 1 "$(plan "file://$WORK/served" | grep -c '^podup v1.2.4$')"
cp -r "$WORK/served" "$WORK/broken"; rm "$WORK/broken/fc45/x86_64/repodata/repomd.xml.asc"
check "a served repository that cannot be verified stops the run" 1 "$(plan "file://$WORK/broken" > /dev/null 2>&1; echo $?)"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
