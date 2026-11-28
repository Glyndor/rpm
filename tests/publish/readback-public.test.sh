#!/usr/bin/env bash
#
# scripts/publish/readback-public.sh: the index a client would get through the public address must be the one
# just built, byte for byte and signed by the archive key; a stale or altered one is retried and then a failure.
# Requires: rpm, createrepo_c, gpg, curl, python3 with cryptography.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/tree.sh"
RB="$HERE/scripts/publish/readback-public.sh"
WORK="$(mktemp -d)"
trap 'fx_stop_agent; rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
fx_init "$WORK"; fx_archive_key
mkdir -p "$WORK/v1/p" "$WORK/v2/p"
fx_rpm "$WORK/v1/p" podup 1.2.3 1.glyndor.any noarch; fx_rpm "$WORK/v2/p" podup 1.2.4 1.glyndor.any noarch
fx_build_tree "$WORK/new" "$FX_T2" "$WORK/v2" > /dev/null 2>&1
fx_build_tree "$WORK/old" "$FX_T1" "$WORK/v1" > /dev/null 2>&1
rb() { "$RB" "$@" > "$WORK/out" 2>&1; echo $?; }

check "the index served is the one built" 0 "$(rb "file://$WORK/new" "$WORK/new" "$WORK/archive.asc" 1 0)"
check "and says how many it read" 1 "$(grep -c 'read back 14 repository index' "$WORK/out")"
check "the previous index being served is a failure" 1 "$(rb "file://$WORK/old" "$WORK/new" "$WORK/archive.asc" 1 0)"
check "and names the folder" 1 "$(grep -c 'is not the one that was published' "$WORK/out")"
rm -rf "${WORK:?}/mix"; cp -r "$WORK/new" "$WORK/mix"; cp "$WORK/old/fc45/x86_64/repodata/repomd.xml.asc" "$WORK/mix/fc45/x86_64/repodata/repomd.xml.asc"
check "a new index with the signature of the old one is a failure" 1 "$(rb "file://$WORK/mix" "$WORK/new" "$WORK/archive.asc" 1 0)"
rm -rf "${WORK:?}/gone"; cp -r "$WORK/new" "$WORK/gone"; rm "$WORK/gone/el9/aarch64/repodata/repomd.xml"
check "an index that is not served is a failure" 1 "$(rb "file://$WORK/gone" "$WORK/new" "$WORK/archive.asc" 1 0)"
fx_other_key "$WORK/other.asc"
check "an index that verifies only with another key is a failure" 1 "$(rb "file://$WORK/new" "$WORK/new" "$WORK/other.asc" 1 0)"
# a purge that lands during the retries: the old index is served until a file appears
rm -rf "${WORK:?}/late"; cp -r "$WORK/old" "$WORK/late"
( sleep 3; rm -rf "$WORK/late"; cp -r "$WORK/new" "$WORK/late" ) &
check "an index that is stale at first and right a few seconds later passes" 0 "$(rb "file://$WORK/late" "$WORK/new" "$WORK/archive.asc" 6 2)"
wait
check "a base that is not allowed is refused" 1 "$(rb "http://example.com" "$WORK/new" "$WORK/archive.asc" 1 0)"
check "attempts that are not a number are refused" 1 "$(rb "file://$WORK/new" "$WORK/new" "$WORK/archive.asc" many 0)"
check "a tree that is not there is refused" 1 "$(rb "file://$WORK/new" "$WORK/none" "$WORK/archive.asc" 1 0)"
check "too few arguments are refused" 1 "$(rb "file://$WORK/new")"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
