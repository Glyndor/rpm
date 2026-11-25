#!/usr/bin/env bash
#
# scripts/verify/fetch-release.sh with a stand-in for `gh`: what it downloads, what it refuses to
# ask for, and that every downloaded file is attested against the product's release workflow.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FETCH="$HERE/scripts/verify/fetch-release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
mkdir "$WORK/bin"; cp "$HERE/tests/fixtures/rpm/fake-gh.sh" "$WORK/bin/gh"
export FAKE_GH_LOG="$WORK/log" FAKE_GH_SRC="$WORK/src" FAKE_GH_VIEW="$WORK/view.json" PATH="$WORK/bin:$PATH"
mkdir "$WORK/src"
for f in podup-1.2.3-1.glyndor.any.x86_64.rpm podup-1.2.3-1.glyndor.any.x86_64.rpm.sig podup_1.2.3_amd64.deb components.txt; do
	printf 'data' > "$WORK/src/$f"
done
view() { # <tag> then name:size pairs
	local sep="" out='{"tagName":"'"$1"'","assets":['; shift
	for a in "$@"; do
		sz="${a#*:}"; [[ "$sz" =~ ^[0-9]+$ ]] || sz="\"$sz\""
		out="$out$sep{\"name\":\"${a%%:*}\",\"size\":$sz}"; sep=","
	done
	printf '%s]}' "$out" > "$WORK/view.json"
}
fetch() { rm -rf "$WORK/out"; mkdir "$WORK/out"; : > "$FAKE_GH_LOG"; "$FETCH" "$@" "$WORK/out" 2>&1; }
R="podup-1.2.3-1.glyndor.any.x86_64.rpm"
SHA=0123456789abcdef0123456789abcdef01234567
export FAKE_GH_SHA="$SHA"

view v1.2.3 "$R:4" "$R.sig:4" podup_1.2.3_amd64.deb:4 components.txt:4
out="$(fetch podup v1.2.3)"; check "a release is fetched" 0 "$?"
check "only the rpm and its signature are downloaded" "$R $R.sig" "$(find "$WORK/out" -type f -printf '%f\n' | sort | tr '\n' ' ' | sed 's/ $//')"
check "the deb is never asked for" 0 "$(grep -c 'deb' "$FAKE_GH_LOG")"
check "each file is downloaded by its exact name" 2 "$(grep -c -- '--pattern podup-1.2.3-1.glyndor.any.x86_64.rpm' "$FAKE_GH_LOG")"
check "the attestation of the rpm is checked against the product's workflow, the tag, its commit, and no self hosted runner" 1 \
	"$(grep -c "attestation verify $WORK/out/$R --repo Glyndor/podup --signer-workflow Glyndor/podup/.github/workflows/release.yml --deny-self-hosted-runners --source-ref refs/tags/v1.2.3 --source-digest $SHA\$" "$FAKE_GH_LOG")"
check "the commit of the tag is asked for" 1 "$(grep -c '^api repos/Glyndor/podup/commits/v1.2.3 --jq .sha$' "$FAKE_GH_LOG")"
check "the attestation of the signature is checked too" 1 "$(grep -c "attestation verify $WORK/out/$R.sig " "$FAKE_GH_LOG")"
check "the other workflow file name of helmly is read from the config" 1 \
	"$(view v1.2.3 helmly-1.2.3-1.glyndor.any.x86_64.rpm:4; : > "$FAKE_GH_LOG"; mkdir -p "$WORK/o2"; rm -f "$WORK/o2"/*
	cp "$WORK/src/$R" "$WORK/src/helmly-1.2.3-1.glyndor.any.x86_64.rpm"; "$FETCH" helmly v1.2.3 "$WORK/o2" >/dev/null 2>&1
	grep -c 'release-dashboard.yml' "$FAKE_GH_LOG")"

view v1.2.3 components.txt:4 podup_1.2.3_amd64.deb:4
out="$(fetch podup v1.2.3)"; check "a release with no rpm exits 3" 3 "$?"
check "and downloads nothing" 0 "$(find "$WORK/out" -type f | wc -l)"

refuse() { # <description> <fragment> <args...> ; runs against the current view
	local d="$1" frag="$2" o rc=0; shift 2
	o="$(fetch "$@")" || rc=$?
	check "$d: refused" 1 "$rc"
	check "$d: says why" 1 "$(printf '%s' "$o" | grep -cF -- "$frag")"
	check "$d: downloads nothing" 0 "$(grep -c 'release download' "$FAKE_GH_LOG")"
}
view v1.2.3 "$R:4" "../$R:4"; refuse "an asset name with a path separator" "outside the closed alphabet" podup v1.2.3
view v1.2.3 "$R:4" "podup-*.rpm:4"; refuse "an asset name with a glob character" "outside the closed alphabet" podup v1.2.3
view v1.2.3 "$R:4" "a b.rpm:4"; refuse "an asset name with a space" "outside the closed alphabet" podup v1.2.3
view v1.2.3 "$R:999999999999"; refuse "a package over the size cap" "over the" podup v1.2.3
view v1.2.3 "$R:4" "$R.sig:5000"; refuse "a signature over the size cap" "over the 4096-byte cap" podup v1.2.3
view v1.2.3 "$R:12x"; refuse "a size that is not a number" "non-numeric size" podup v1.2.3
view v1.2.4 "$R:4"; refuse "a release that is not the tag asked for" "is not that tag" podup v1.2.3
view v1.2.3 "$R:4"
refuse "a tag that is a branch name" "is not vX.Y.Z" podup main
refuse "a product that is not in the channel" "is not a product of this channel" nginx v1.2.3
mkdir -p "$WORK/full"; : > "$WORK/full/x"
out="$("$FETCH" podup v1.2.3 "$WORK/full" 2>&1)"; check "a directory that is not empty is refused" 1 "$?"

view v1.2.3 "$R:4" "$R.sig:4"
out="$(FAKE_GH_FAIL="$R.sig" fetch podup v1.2.3)"; check "a failed download is refused" 1 "$?"
out="$(FAKE_GH_BAD_ATTEST="$R" fetch podup v1.2.3)"; rc=$?
check "an attestation that does not verify is refused" 1 "$rc"
check "and names the file" 1 "$(printf '%s' "$out" | grep -c "attestation of $R does not verify")"
out="$(FAKE_GH_BAD_ATTEST="$R.sig" fetch podup v1.2.3)"; check "so is one for the signature" 1 "$?"
out="$(FAKE_GH_ATTEST_REF=refs/tags/v1.2.2 fetch podup v1.2.3)"; check "a valid attestation of another release of the same product is refused" 1 "$?"
check "and says which" 1 "$(printf '%s' "$out" | grep -c 'does not verify against Glyndor/podup.s release.yml for v1.2.3')"
out="$(FAKE_GH_ATTEST_SHA=ffffffffffffffffffffffffffffffffffffffff fetch podup v1.2.3)"; check "an attestation of another commit is refused" 1 "$?"
out="$(FAKE_GH_SHA='' fetch podup v1.2.3)"; check "a tag whose commit cannot be resolved is refused" 1 "$?"
out="$(FAKE_GH_SHA=notasha fetch podup v1.2.3)"; check "a commit that is not a full SHA is refused" 1 "$?"
out="$(FAKE_GH_ATTEST_REF=refs/tags/v1.2.3 FAKE_GH_ATTEST_SHA=$SHA fetch podup v1.2.3)"; check "the attestation for this very tag and commit passes" 0 "$?"
mkdir -p "$WORK/cfg"; cp "$HERE/config/"* "$WORK/cfg/"; sed -i 's/^\(podup\t.*\t\)tag$/\1refs\/heads\/main/' "$WORK/cfg/products.txt"
rm -rf "$WORK/out"; mkdir "$WORK/out"; : > "$FAKE_GH_LOG"
FAKE_GH_ATTEST_REF=refs/heads/main "$FETCH" --config "$WORK/cfg" podup v1.2.3 "$WORK/out" > /dev/null 2>&1; check "a product that releases from main is attested against that ref" 0 "$?"
check "and no tag commit is asked for" 0 "$(grep -c '^api ' "$FAKE_GH_LOG")"
sed -i 's/refs\/heads\/main$/main/' "$WORK/cfg/products.txt"
rm -rf "$WORK/out"; mkdir "$WORK/out"
"$FETCH" --config "$WORK/cfg" podup v1.2.3 "$WORK/out" > /dev/null 2>&1; check "a source ref that is neither tag nor a full ref is refused" 1 "$?"
rm -f "$WORK/src/$R.sig"
view v1.2.3 "$R:4" "$R.sig:4"; out="$(fetch podup v1.2.3)"; check "an advertised asset that does not arrive is refused" 1 "$?"
printf 'data' > "$WORK/src/$R.sig"; printf 'data' > "$WORK/src/$R.sig2"
view v1.2.3 "$R:4" "$R.sig:4"
out="$(fetch podup v1.2.3)"; check "the exact name is requested, not a pattern that could match more" 0 "$?"

# --- what a release may weigh, before anything of it is authenticated -------------------------------------------------
S="podup-1.2.3-1.glyndor.any"
for a in x86_64 aarch64 noarch; do printf 'data' > "$WORK/src/$S.$a.rpm"; printf 'data' > "$WORK/src/$S.$a.rpm.sig"; done
printf 'data' > "$WORK/src/$S.x86_64.rpm.mldsa65.sig"
view v1.2.3 "extra-1.rpm:4" "$R:4" "$R.sig:4"
refuse "an rpm whose name the contract does not give" "not a file the contract names" podup v1.2.3
view v1.2.3 "$R:4" "$R.sig:4" "podup-1.2.4-1.glyndor.any.x86_64.rpm:4"
refuse "an rpm of another version" "not a file the contract names" podup v1.2.3
view v1.2.3 "$S.x86_64.rpm:4" "$S.x86_64.rpm.sig:4" "$S.aarch64.rpm:4" "$S.aarch64.rpm.sig:4" "$S.noarch.rpm:4" "$S.noarch.rpm.sig:4"
out="$(fetch podup v1.2.3)"; check "six assets, the most a product of two architectures and its signatures can have, are fetched" 0 "$?"
view v1.2.3 "$S.x86_64.rpm:4" "$S.x86_64.rpm.sig:4" "$S.x86_64.rpm.mldsa65.sig:4" "$S.aarch64.rpm:4" "$S.aarch64.rpm.sig:4" "$S.noarch.rpm:4" "$S.noarch.rpm.sig:4"
refuse "seven assets, one over the most" "more than 6 rpm assets" podup v1.2.3
many=(); for _ in $(seq 1 100); do many+=("podup-1.2.3-1.glyndor.any.x86_64.rpm:314572800"); done
view v1.2.3 "${many[@]}"
refuse "a hundred assets of 300 MiB, each under the cap of one" "more than 6 rpm assets" podup v1.2.3
view v1.2.3 "$R:4" "$R.sig:4"
out="$(ADMIT_MAX_TOTAL_BYTES=8 fetch podup v1.2.3)"; check "the bytes the listing declares, exactly at the ceiling, are fetched" 0 "$?"
o="$(ADMIT_MAX_TOTAL_BYTES=7 fetch podup v1.2.3)" || rc=$?
check "and one byte over the ceiling is refused" 1 "${rc:-0}"
check "naming the ceiling" 1 "$(printf '%s' "$o" | grep -c 'declare more than 7 bytes together')"
check "before anything is downloaded" 0 "$(grep -c 'release download' "$FAKE_GH_LOG")"
head -c 100 /dev/zero > "$WORK/src/$R"
view v1.2.3 "$R:4" "$R.sig:4"
rc=0; o="$(ADMIT_MAX_TOTAL_BYTES=50 fetch podup v1.2.3)" || rc=$?
check "a listing that says 4 bytes over a file of 100 is caught by what arrived" 1 "$rc"
check "and says what the files weigh" 1 "$(printf '%s' "$o" | grep -c 'downloaded so far weigh')"
printf 'data' > "$WORK/src/$R"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
