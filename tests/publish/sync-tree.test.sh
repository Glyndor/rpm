#!/usr/bin/env bash
#
# scripts/publish/sync-tree.sh against a bucket that is a folder: the order of the upload, that
# nothing is uploaded twice or replaced by other bytes, what happens when the upload or the read
# back goes wrong, and that what left the tree stays (sync-tree-keeps.test.sh holds the rest of that).
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
# With one of these missing about half of the cases still pass, since they expect a refusal: name it and stop.
for tool in rpm rpmbuild rpmsign createrepo_c gpg gpgv jq; do
	command -v "$tool" > /dev/null 2>&1 || { echo "FAIL  $tool is needed by this suite and was not found"; exit 1; }
done
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
bucket_files() { (cd "$FAKE_S3/b/o" 2>/dev/null && find . -type f | sort | sed 's|^\./||') ; }

check "the first upload succeeds" 0 "$(sync "$WORK/t1" b)"
check "the bucket holds exactly the tree" "$(cd "$WORK/t1" && find . -type f | sort | sed 's|^\./||')" "$(bucket_files)"
puts() { grep -n '^s3 cp .* s3://b/' "$FAKE_S3_LOG" | sed 's|.* s3://b/\([^ ]*\).*|\1|'; }
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

# a new version goes up, and what it replaces stays
check "a newer tree is uploaded" 0 "$(sync "$WORK/t2" b)"
OLDP="fc45/x86_64/Packages/podup-1.2.3-1.glyndor.any.noarch.rpm"
check "the replaced package is still in the bucket" 1 "$([ -f "$FAKE_S3/b/o/$OLDP" ] && echo 1 || echo 0)"
check "and the new one is" 1 "$([ -f "$FAKE_S3/b/o/fc45/x86_64/Packages/podup-1.2.4-1.glyndor.any.noarch.rpm" ] && echo 1 || echo 0)"
check "and nothing was asked to be deleted" 0 "$(grep -c 'delete' "$FAKE_S3_LOG")"

# nothing goes back: the bucket is read right before the upload, not when the tree was built
snap_all() { (cd "$FAKE_S3/b/o" && find . -type f -exec sha256sum {} + | sort | sha256sum | cut -d' ' -f1); }
before_all="$(snap_all)"
check "an older tree than what the bucket holds is refused" 1 "$(sync "$WORK/t1" b)"
check "and says a repository never goes back" 1 "$(grep -c 'a repository never goes back' "$WORK/out")"
check "and nothing at all was written" 0 "$(puts | wc -l)"
check "the bucket is as it was" "$before_all" "$(snap_all)"
cp "$FAKE_S3/b/o/fc45/x86_64/repodata/repomd.xml" "$WORK/keep-repomd.xml"
sed 's|<revision>[0-9]*</revision>||' "$WORK/keep-repomd.xml" > "$FAKE_S3/b/o/fc45/x86_64/repodata/repomd.xml"
check "a repomd.xml in the bucket with no revision is refused, not replaced" 1 "$(sync "$WORK/t2" b)"
check "and says so" 1 "$(grep -c 'has no revision I can read' "$WORK/out")"
cp "$WORK/keep-repomd.xml" "$FAKE_S3/b/o/fc45/x86_64/repodata/repomd.xml"

# failures
snapshot() { (cd "$FAKE_S3/b/o/fc45/x86_64/repodata" && cat repomd.xml repomd.xml.asc | sha256sum | cut -d' ' -f1); }
before="$(snapshot)"
fx_build_tree "$WORK/t3" 1790000300 "$WORK/v2" > /dev/null 2>&1
check "an upload of repomd.xml that fails ends red" 1 "$(FAKE_S3_FAIL=el10/x86_64/repodata/repomd.xml sync "$WORK/t3" b)"
check "and says the previous pairs were put back" 1 "$(grep -c 'previous pairs were put back' "$WORK/out")"
check "the pairs that went up before the failure are the previous ones again" "$before" "$(snapshot)"
# every case below starts from a bucket of its own, so what one leaves broken is not what the next one finds
gpg --batch --no-default-keyring --keyring "$WORK/ring.kbx" --import "$WORK/archive.asc" > /dev/null 2>&1
published() { sync "$WORK/t2" "$1" > /dev/null; } # <bucket>: it holds a good publication
pair_of() { (cd "$FAKE_S3/$1/o/$2/repodata" && cat repomd.xml repomd.xml.asc | sha256sum | cut -d' ' -f1); }
verifies() { gpgv --keyring "$WORK/ring.kbx" "$FAKE_S3/$1/o/$2/repodata/repomd.xml.asc" "$FAKE_S3/$1/o/$2/repodata/repomd.xml" > /dev/null 2>&1 && echo 1 || echo 0; }
said() { grep -c -- "$1" "$WORK/out"; }
FC45=fc45/x86_64
XML="$FC45/repodata/repomd.xml"

published corrupt
before="$(pair_of corrupt fc44/x86_64)"
check "a read back that differs ends red" 1 "$(FAKE_S3_CORRUPT=fc44/x86_64/repodata/repomd.xml.asc sync "$WORK/t3" corrupt)"
check "and says it reads back different" 1 "$(said 'reads back different')"
check "a rollback that is corrupted too leaves a pair that is not the previous one" 0 "$([ "$(pair_of corrupt fc44/x86_64)" = "$before" ] && echo 1 || echo 0)"
check "and the repository it could not put back is named" 1 "$(said 'could not be confirmed to hold the previous pair of fc44/x86_64')"
check "and the run does not claim the pairs were put back" 0 "$(said 'previous pairs were put back')"

# the signature of the new index goes up, the index does not, and the rollback of the signature fails
published half
before="$(pair_of half el9/x86_64)"
check "a pair left half replaced ends red" 1 "$(FAKE_S3_FAIL_AT="$XML#1 $XML.asc#2" sync "$WORK/t3" half)"
check "the bucket holds a signature that does not match its index" 0 "$(verifies half "$FC45")"
check "and that repository is named" 1 "$(said "could not be confirmed to hold the previous pair of $FC45")"
check "and the run does not claim the pairs were put back" 0 "$(said 'previous pairs were put back')"
check "and a repository that went up before it holds its previous pair again" "$before" "$(pair_of half el9/x86_64)"

# an upload of the rollback fails, and the bucket holds the previous pair all the same: it was never replaced
published untouched
before="$(pair_of untouched "$FC45")"
check "a rollback upload that fails over a pair that never changed ends red" 1 "$(FAKE_S3_FAIL_AT="$XML.asc#1 $XML.asc#2" sync "$WORK/t3" untouched)"
check "and says that upload failed" 1 "$(said "an upload of the previous pair of $FC45 failed")"
check "the bucket holds the previous pair" "$before" "$(pair_of untouched "$FC45")"
check "so it says the pairs were put back" 1 "$(said 'previous pairs were put back')"
check "and names no repository as lost" 0 "$(said 'could not be confirmed')"

# a pair that did not verify before the run is put back as it was: the run does not say it could not
published stale
cp "$FAKE_S3/stale/o/el9/x86_64/repodata/repomd.xml.asc" "$FAKE_S3/stale/o/$XML.asc"
before="$(pair_of stale "$FC45")"
check "a failure over a pair that was already broken ends red" 1 "$(FAKE_S3_FAIL_AT="$XML#1" sync "$WORK/t3" stale)"
check "the bytes that were there are there again" "$before" "$(pair_of stale "$FC45")"
check "and it says the pairs were put back" 1 "$(said 'previous pairs were put back')"
check "and names no repository as lost" 0 "$(said 'could not be confirmed')"

# a repository with no previous pair keeps what was uploaded, and the run says so
check "a first publication that reads back different ends red" 1 "$(FAKE_S3_CORRUPT="$XML" sync "$WORK/t3" first)"
check "the corrupted pair is still in the bucket" 0 "$(verifies first "$FC45")"
check "and it says there was no previous pair to put back" 1 "$(said 'there was no previous pair to put back')"
check "and names the repository that keeps the upload" 1 "$(said "no previous pair for .*$FC45")"
check "and does not claim any pair was put back" 0 "$(said 'previous pairs were put back')"
rm -rf "${WORK:?}/t6"; cp -r "$WORK/t2" "$WORK/t6"; rm -rf "$WORK/t6/fc45"
sync "$WORK/t6" added > /dev/null
check "a failure in a repository that is new to the bucket ends red" 1 "$(FAKE_S3_FAIL_AT="$XML#1" sync "$WORK/t3" added)"
check "and says the previous pairs were put back" 1 "$(said 'previous pairs were put back')"
check "and that the new one has none" 1 "$(said "no previous pair for .*$FC45")"
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
