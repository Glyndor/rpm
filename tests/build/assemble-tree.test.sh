#!/usr/bin/env bash
#
# scripts/build/assemble-tree.sh from downloaded releases to a verified tree: the whole chain on three
# products, and each refusal before anything is built.
# Requires: rpm, createrepo_c, gpg, python3 with cryptography.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/tree.sh"
ASM="$HERE/scripts/build/assemble-tree.sh"
WORK="$(mktemp -d)"
trap 'fx_stop_agent; rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
fx_init "$WORK"; fx_archive_key
fx_static_release "$WORK/rel/podup" podup 1.2.3 x86_64,aarch64
fx_static_release "$WORK/rel/epistle-panel" epistle-panel 0.9.1 noarch
fx_podman_release "$WORK/rel/podman" 6.2.0 12
printf 'podup v1.2.3\nepistle-panel v0.9.1\npodman v6.2.0+r12\n' > "$WORK/plan"
export ORDER_NOW=$((FX_T2 + 60))
asm() { # <admitted root> <plan> <out> <epoch> [archive url]
	ARCHIVE_URL="${5:-file://$WORK/nothing}" "$ASM" --key "$WORK/archive.asc" --keyring "$WORK/keyring" "$1" "$2" "$3" "$4" > "$WORK/out" 2>&1
	echo $?
}
check "the chain succeeds on three products" 0 "$(asm "$WORK/rel" "$WORK/plan" "$WORK/t1" "$FX_T1")"
check "the tree has the repositories" 7 "$(find "$WORK/t1" -mindepth 1 -maxdepth 1 -type d ! -name install | wc -l)"
check "and an installer for each product" "epistle-panel podman podup" "$(fx_names "$WORK/t1/install")"
check "the order check compared nothing, since nothing is served" 1 "$(grep -c '0 repository(ies) compared' "$WORK/out")"
check "a second run against the first is accepted" 0 "$(asm "$WORK/rel" "$WORK/plan" "$WORK/t2" "$FX_T2" "file://$WORK/t1")"
check "and compared fourteen repositories" 1 "$(grep -c '14 repository(ies) compared' "$WORK/out")"
check "the same revision as the served one is refused" 1 "$(asm "$WORK/rel" "$WORK/plan" "$WORK/t3" "$FX_T1" "file://$WORK/t1")"

mkdir -p "$WORK/bad"; cp -r "$WORK/rel/." "$WORK/bad/"
printf 'x' >> "$WORK/bad/podup/podup-1.2.3-1.glyndor.any.x86_64.rpm"
check "a package changed after it was signed stops it" 1 "$(asm "$WORK/bad" "$WORK/plan" "$WORK/t4" "$FX_T1")"
check "in the admission" 1 "$(grep -c 'podup v1.2.3 is not admitted' "$WORK/out")"
check "before anything is built" 0 "$([ -e "$WORK/t4" ] && echo 1 || echo 0)"
mkdir -p "$WORK/more"; cp -r "$WORK/rel/." "$WORK/more/"; mkdir "$WORK/more/other"
check "a folder the plan does not name stops it" 1 "$(asm "$WORK/more" "$WORK/plan" "$WORK/t5" "$FX_T1")"
mkdir -p "$WORK/less"; cp -r "$WORK/rel/." "$WORK/less/"; rm -rf "$WORK/less/podman"
check "a product of the plan with no folder stops it" 1 "$(asm "$WORK/less" "$WORK/plan" "$WORK/t6" "$FX_T1")"
printf 'podup v1.2.4\nepistle-panel v0.9.1\npodman v6.2.0+r12\n' > "$WORK/plan2"
check "a plan with another tag than the files stops it" 1 "$(asm "$WORK/rel" "$WORK/plan2" "$WORK/t7" "$FX_T1")"
printf 'podup v1.2.3\npodup v1.2.3\n' > "$WORK/plan3"
check "a product twice in the plan is refused" 1 "$(asm "$WORK/rel" "$WORK/plan3" "$WORK/t8" "$FX_T1")"
printf 'podup main\n' > "$WORK/plan4"
check "a plan line with a branch name is refused" 1 "$(asm "$WORK/rel" "$WORK/plan4" "$WORK/t9" "$FX_T1")"
printf 'podup v1.2.3 extra\n' > "$WORK/plan5"
check "a plan line with a third word is refused" 1 "$(asm "$WORK/rel" "$WORK/plan5" "$WORK/t10" "$FX_T1")"
: > "$WORK/plan6"
check "an empty plan is refused" 1 "$(asm "$WORK/rel" "$WORK/plan6" "$WORK/t11" "$FX_T1")"
rm -rf "${WORK:?}/t12"
check "revisions are judged against the start of the run when ORDER_NOW is not given" 0 "$(env -u ORDER_NOW ARCHIVE_URL="file://$WORK/nothing" "$ASM" --key "$WORK/archive.asc" --keyring "$WORK/keyring" "$WORK/rel" "$WORK/plan" "$WORK/t12" "$FX_T1" > /dev/null 2>&1; echo $?)"
check "an output folder that exists is refused" 1 "$(asm "$WORK/rel" "$WORK/plan" "$WORK/t1" "$FX_T2")"
check "an unknown option is refused" 1 "$("$ASM" --bogus a b c d > /dev/null 2>&1; echo $?)"
check "the real key file is the default" 1 "$(grep -cF "PUB=\"\$HERE/keyring/glyndor-rpm-key.asc\"" "$ASM")"

# what is admitted is what is signed: a package swapped in the downloaded folder after the admission does not reach the tree
mkdir -p "$WORK/repo2"; cp -r "$HERE/scripts" "$HERE/config" "$HERE/keyring" "$WORK/repo2/"
mv "$WORK/repo2/scripts/verify/admit-release.sh" "$WORK/repo2/scripts/verify/admit-real.sh"
cat > "$WORK/repo2/scripts/verify/admit-release.sh" <<'SH'
#!/usr/bin/env bash
# admits like the real one, then swaps the file of the folder it was given by the evil one
D="$(dirname "$0")"
"$D/admit-real.sh" "$@" || exit $?
for f in "$FX_ORIG_ROOT/podup"/*.rpm; do cp "$FX_EVIL/$(basename "$f")" "$f" 2> /dev/null || true; done
SH
chmod +x "$WORK/repo2/scripts/verify/admit-release.sh"
mkdir -p "$WORK/evil"; fx_rpm "$WORK/evil" podup 1.2.3 1.glyndor.any x86_64 provides=podup file=/usr/bin/evil; fx_rpm "$WORK/evil" podup 1.2.3 1.glyndor.any aarch64 provides=podup file=/usr/bin/evil
mkdir -p "$WORK/relswap"; cp -r "$WORK/rel/." "$WORK/relswap/"; printf 'podup v1.2.3\n' > "$WORK/plan1"; rm -rf "${WORK:?}/relswap/epistle-panel" "${WORK:?}/relswap/podman"
FX_ORIG_ROOT="$WORK/relswap" FX_EVIL="$WORK/evil" ARCHIVE_URL="file://$WORK/nothing" "$WORK/repo2/scripts/build/assemble-tree.sh" --key "$WORK/archive.asc" --keyring "$WORK/keyring" "$WORK/relswap" "$WORK/plan1" "$WORK/tswap" "$FX_T1" > "$WORK/out" 2>&1
check "a run in which the downloaded folder is swapped after the admission still ends well" 0 "$?"
check "the folder was swapped, as the test meant" 1 "$(rpm -qlp "$WORK/relswap/podup/podup-1.2.3-1.glyndor.any.x86_64.rpm" 2> /dev/null | grep -c '/usr/bin/evil')"
check "and the tree holds the package that was admitted, not the swapped one" 0 "$(rpm -qlp "$WORK/tswap/fc45/x86_64/Packages/podup-1.2.3-1.glyndor.any.x86_64.rpm" 2> /dev/null | grep -c '/usr/bin/evil')"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
