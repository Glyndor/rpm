#!/usr/bin/env bash
#
# scripts/publish/sync-tree.sh against a bucket that is a folder: the order of the upload, that
# nothing is uploaded twice or replaced by other bytes, what happens when the upload or the read
# back goes wrong, and when what left the tree is deleted.
# Requires: rpm, createrepo_c, gpg, jq, python3 with cryptography.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/tree.sh"
SYNC="$HERE/scripts/publish/sync-tree.sh"
WORK="$(mktemp -d)"
trap 'fx_stop_agent; rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
fx_init "$WORK"; fx_archive_key
mkdir -p "$WORK/v1/p" "$WORK/v2/p" "$WORK/bin" "$WORK/w"
fx_rpm "$WORK/v1/p" podup 1.2.3 1.glyndor.any noarch
fx_rpm "$WORK/v2/p" podup 1.2.4 1.glyndor.any noarch
fx_build_tree "$WORK/t1" "$FX_T1" "$WORK/v1" > /dev/null 2>&1
fx_build_tree "$WORK/t2" "$FX_T2" "$WORK/v2" > /dev/null 2>&1
mkdir -p "$WORK/t1/install"; printf '#!/bin/sh\n' > "$WORK/t1/install/podup"; cp -r "$WORK/t1/install" "$WORK/t2/install"
cp "$HERE/tests/fixtures/rpm/fake-aws.sh" "$WORK/bin/aws"
export PATH="$WORK/bin:$PATH" FAKE_S3="$WORK/s3" FAKE_S3_LOG="$WORK/log"
export AWS_ENDPOINT_URL="https://example.invalid" AWS_ACCESS_KEY_ID=k AWS_SECRET_ACCESS_KEY=s
sync() { rm -rf "${WORK:?}/w"; mkdir "$WORK/w"; : > "$FAKE_S3_LOG"; "$SYNC" "$@" "$WORK/w" > "$WORK/out" 2>&1; echo $?; }
bucket_files() { (cd "$FAKE_S3/b/o" 2>/dev/null && find . -type f ! -path './state/*' | sort | sed 's|^\./||') ; }

check "the first upload succeeds" 0 "$(sync "$WORK/t1" b)"
check "the bucket holds exactly the tree, and the list of retired objects" "$(cd "$WORK/t1" && find . -type f | sort | sed 's|^\./||')" "$(bucket_files)"
puts() { grep -n '^s3 cp .* s3://b/' "$FAKE_S3_LOG" | sed 's|.* s3://b/\([^ ]*\).*|\1|' | grep -v '^[0-9]*:\?state/'; }
order="$(puts | grep -n -E 'repomd.xml' | cut -d: -f1 | head -1)"
last_non_final="$(puts | grep -n -v -E 'repomd.xml' | cut -d: -f1 | tail -1)"
check "every package and every checksum-named file goes up before any repomd.xml" 1 "$([ "$last_non_final" -lt "$order" ] && echo 1 || echo 0)"
check "each signature goes up right before its repomd.xml" 14 "$(puts | grep -A1 'repomd.xml.asc' | grep -c 'repomd.xml$')"
check "nothing is uploaded after the last repomd.xml" "repodata/repomd.xml" "$(puts | tail -1 | sed 's|.*/repodata/|repodata/|')"
check "no size comparison and no sync is ever used" 0 "$(grep -c -E 'size-only|s3 sync' "$FAKE_S3_LOG")"
check "a package carries its sha256 as metadata" "$(sha256sum "$WORK/t1/fc45/x86_64/Packages/podup-1.2.3-1.glyndor.any.noarch.rpm" | cut -d' ' -f1)" \
	"$(cat "$FAKE_S3/b/m/fc45/x86_64/Packages/podup-1.2.3-1.glyndor.any.noarch.rpm")"

check "the same tree again succeeds" 0 "$(sync "$WORK/t1" b)"
check "and uploads no package and no checksum-named file again" 0 "$(puts | grep -c -E 'Packages/|repodata/[0-9a-f]{64}')"

# identity: a published name with other bytes
cp "$WORK/t1/fc45/x86_64/Packages/podup-1.2.3-1.glyndor.any.noarch.rpm" "$WORK/keep.rpm"
printf 'x' >> "$WORK/t1/fc45/x86_64/Packages/podup-1.2.3-1.glyndor.any.noarch.rpm"
check "a published package with other bytes is refused" 1 "$(sync "$WORK/t1" b)"
check "and says it does not change" 1 "$(grep -c 'a published identity does not change' "$WORK/out")"
check "and no metadata went up" 0 "$(puts | grep -c repomd)"
cp "$WORK/keep.rpm" "$WORK/t1/fc45/x86_64/Packages/podup-1.2.3-1.glyndor.any.noarch.rpm"
rm -f "$FAKE_S3/b/m/fc45/x86_64/Packages/podup-1.2.3-1.glyndor.any.noarch.rpm"
check "an object in the bucket with no recorded hash is refused" 1 "$(sync "$WORK/t1" b)"
sha256sum "$WORK/keep.rpm" | cut -d' ' -f1 | tr -d '\n' > "$FAKE_S3/b/m/fc45/x86_64/Packages/podup-1.2.3-1.glyndor.any.noarch.rpm"

# a new version goes up; what it replaces is noted, not deleted
check "a newer tree is uploaded" 0 "$(SYNC_NOW=1790000000 sync "$WORK/t2" b)"
OLDP="fc45/x86_64/Packages/podup-1.2.3-1.glyndor.any.noarch.rpm"
check "the replaced package is still in the bucket" 1 "$([ -f "$FAKE_S3/b/o/$OLDP" ] && echo 1 || echo 0)"
check "and the new one is" 1 "$([ -f "$FAKE_S3/b/o/fc45/x86_64/Packages/podup-1.2.4-1.glyndor.any.noarch.rpm" ] && echo 1 || echo 0)"
check "the replaced package is noted with the time it was first seen out of the tree" "1790000000" "$(grep "^$OLDP	" "$FAKE_S3/b/o/state/retired.tsv" | cut -f2)"
touch -d '400 days ago' "$FAKE_S3/b/o/$OLDP"
check "a run 14 days later deletes nothing, however old the upload" 0 "$(SYNC_NOW=$((1790000000 + 14 * 86400)) sync "$WORK/t2" b)"
check "the replaced package is still there" 1 "$([ -f "$FAKE_S3/b/o/$OLDP" ] && echo 1 || echo 0)"
check "and its date was kept, not renewed" "1790000000" "$(grep "^$OLDP	" "$FAKE_S3/b/o/state/retired.tsv" | cut -f2)"
check "a run 15 days and a second after it was first seen deletes it" 0 "$(SYNC_NOW=$((1790000000 + 15 * 86400 + 1)) sync "$WORK/t2" b)"
check "the replaced package is gone" 0 "$([ -f "$FAKE_S3/b/o/$OLDP" ] && echo 1 || echo 0)"
check "and its line with it" 0 "$(grep -c "^$OLDP	" "$FAKE_S3/b/o/state/retired.tsv")"
check "a file of the tree is never retired" 0 "$(grep -c 'podup-1.2.4' "$FAKE_S3/b/o/state/retired.tsv")"
# a package that comes back into the tree stops being retired
printf 'fc44/x86_64/Packages/podup-1.2.4-1.glyndor.any.noarch.rpm\t1700000000\n' >> "$FAKE_S3/b/o/state/retired.tsv"
check "a run with it back in the tree succeeds" 0 "$(SYNC_NOW=1795000000 sync "$WORK/t2" b)"
check "and it is no longer noted" 0 "$(grep -c 'fc44/x86_64/Packages/podup-1.2.4' "$FAKE_S3/b/o/state/retired.tsv")"
check "and is still in the bucket" 1 "$([ -f "$FAKE_S3/b/o/fc44/x86_64/Packages/podup-1.2.4-1.glyndor.any.noarch.rpm" ] && echo 1 || echo 0)"
# an id that is not in the tree is frozen: nothing of it is deleted, ever
rm -rf "${WORK:?}/t4"; cp -r "$WORK/t2" "$WORK/t4"; rm -rf "$WORK/t4/leap16.1"
check "a tree without the Leap folder uploads" 0 "$(SYNC_NOW=1796000000 sync "$WORK/t4" b)"
check "nothing of leap16.1 is noted as retired" 0 "$(grep -c '^leap16.1/' "$FAKE_S3/b/o/state/retired.tsv")"
before_leap="$(find "$FAKE_S3/b/o/leap16.1" -type f | wc -l)"
check "a run a year later succeeds" 0 "$(SYNC_NOW=$((1796000000 + 400 * 86400)) sync "$WORK/t4" b)"
check "and deletes none of the frozen folder" "$before_leap" "$(find "$FAKE_S3/b/o/leap16.1" -type f | wc -l)"
# the folders that are frozen come from the tree of the run, never from a list that can lose an id by mistake
check "sync-tree.sh reads no config of distributions" 0 "$(grep -c 'distros' "$SYNC")"
rm -rf "${WORK:?}/t5"; cp -r "$WORK/t2" "$WORK/t5"; rm -rf "$WORK/t5/el9"
mkdir -p "$FAKE_S3/b/o/weird" "$FAKE_S3/b/m/weird"; printf 'x' > "$FAKE_S3/b/o/weird/x"; printf 'x' > "$FAKE_S3/b/o/stray.txt"
{ find "$FAKE_S3/b/o/el9" -type f | sed "s|^$FAKE_S3/b/o/||"; echo weird/x; echo stray.txt; } | while read -r k; do printf '%s\t1700000000\n' "$k"; done > "$FAKE_S3/b/o/state/retired.tsv"
before_el9="$(find "$FAKE_S3/b/o/el9" -type f | wc -l)"
check "a tree without the el9 folder, with a year of delay, uploads" 0 "$(SYNC_NOW=$((1796000000 + 900 * 86400)) sync "$WORK/t5" b)"
check "no object of el9 is deleted, whatever the list says" "$before_el9" "$(find "$FAKE_S3/b/o/el9" -type f | wc -l)"
check "a key of a folder nobody has heard of is not deleted" 1 "$([ -f "$FAKE_S3/b/o/weird/x" ] && echo 1 || echo 0)"
check "nor a key with no folder" 1 "$([ -f "$FAKE_S3/b/o/stray.txt" ] && echo 1 || echo 0)"
check "and none of them stays on the list of retired objects" 0 "$(grep -cE '^(el9/|weird/|stray)' "$FAKE_S3/b/o/state/retired.tsv")"

# nothing goes back: the bucket is read right before the upload, not when the tree was built
snap_all() { (cd "$FAKE_S3/b/o" && find . -type f ! -path './state/*' -exec sha256sum {} + | sort | sha256sum | cut -d' ' -f1); }
before_all="$(snap_all)"
check "an older tree than what the bucket holds is refused" 1 "$(SYNC_NOW=1796000000 sync "$WORK/t1" b)"
check "and says a repository never goes back" 1 "$(grep -c 'a repository never goes back' "$WORK/out")"
check "and nothing at all was written" 0 "$(puts | wc -l)"
check "the bucket is as it was" "$before_all" "$(snap_all)"
cp "$FAKE_S3/b/o/fc45/x86_64/repodata/repomd.xml" "$WORK/keep-repomd.xml"
sed 's|<revision>[0-9]*</revision>||' "$WORK/keep-repomd.xml" > "$FAKE_S3/b/o/fc45/x86_64/repodata/repomd.xml"
check "a repomd.xml in the bucket with no revision is refused, not replaced" 1 "$(sync "$WORK/t2" b)"
check "and says so" 1 "$(grep -c 'has no revision I can read' "$WORK/out")"
cp "$WORK/keep-repomd.xml" "$FAKE_S3/b/o/fc45/x86_64/repodata/repomd.xml"
printf 'bad line without a time\n' > "$FAKE_S3/b/o/state/retired.tsv"
check "a retired list that is malformed stops the run" 1 "$(sync "$WORK/t2" b)"

# failures
snapshot() { (cd "$FAKE_S3/b/o/fc45/x86_64/repodata" && cat repomd.xml repomd.xml.asc | sha256sum | cut -d' ' -f1); }
before="$(snapshot)"
fx_build_tree "$WORK/t3" 1790000300 "$WORK/v2" > /dev/null 2>&1
check "an upload of repomd.xml that fails ends red" 1 "$(FAKE_S3_FAIL=el10/x86_64/repodata/repomd.xml sync "$WORK/t3" b)"
check "and says the previous pairs were put back" 1 "$(grep -c 'previous pairs were put back' "$WORK/out")"
check "the pairs that went up before the failure are the previous ones again" "$before" "$(snapshot)"
check "a read back that differs ends red" 1 "$(FAKE_S3_CORRUPT=fc44/x86_64/repodata/repomd.xml.asc sync "$WORK/t3" b)"
check "and says it reads back different" 1 "$(grep -c 'reads back different' "$WORK/out")"
check "the bucket holds the previous pair again" "$before" "$(snapshot)"
check "an upload of a package that fails ends red before any metadata" 1 "$(FAKE_S3_FAIL=Packages/podup-1.2.4 sync "$WORK/t2" other)"
check "and no repomd.xml went up" 0 "$(puts | grep -c repomd)"

# refusals
check "an empty endpoint is refused" 1 "$(AWS_ENDPOINT_URL='' sync "$WORK/t2" b)"
check "a variable that redirects the endpoint is refused" 1 "$(AWS_ENDPOINT_URL_S3=https://x.invalid sync "$WORK/t2" b)"
check "missing credentials are refused" 1 "$(AWS_SECRET_ACCESS_KEY='' sync "$WORK/t2" b)"
check "a bucket name with a slash is refused" 1 "$(sync "$WORK/t2" 'b/../x')"
check "a folder that is not a built tree is refused" 1 "$(sync "$WORK" b)"
check "too few arguments are refused" 1 "$("$SYNC" "$WORK/t2" b > /dev/null 2>&1; echo $?)"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
