#!/usr/bin/env bash
#
# scripts/publish/purge-cache.sh with a stand-in for curl: which URLs are purged (only the ones that
# change in place), in batches of at most 30, never everything, the token off the command line, and
# every way a purge can fail being a failure.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PURGE="$HERE/scripts/publish/purge-cache.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
mkdir -p "$WORK/bin" "$WORK/tree/fc45/x86_64/Packages" "$WORK/tree/fc45/x86_64/repodata" "$WORK/tree/install"
cp "$HERE/tests/fixtures/rpm/fake-curl.sh" "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH" FAKE_CURL_ARGS="$WORK/args" FAKE_CURL_BODIES="$WORK/bodies" FAKE_CURL_STDIN="$WORK/stdin"
export CF_TOKEN="tok-secret-value" CF_ZONE="0123456789abcdef0123456789abcdef"
T="$WORK/tree"
for f in fc45/x86_64/Packages/p-1-1.rpm fc45/x86_64/repodata/repomd.xml fc45/x86_64/repodata/repomd.xml.asc \
	fc45/x86_64/repodata/0000000000000000000000000000000000000000000000000000000000000000-primary.xml.gz \
	fc45/glyndor.repo glyndor-rpm-key.asc install/podup index.html; do echo x > "$T/$f"; done
run() { rm -f "$WORK/args" "$WORK/bodies" "$WORK/stdin"; "$PURGE" "$@" > "$WORK/out" 2>&1; echo $?; }
urls() { jq -r '.files[]' "$WORK/bodies" | sort; }

check "the purge succeeds" 0 "$(run https://rpm.glyndor.net "$T")"
check "the files that change in place are purged" "https://rpm.glyndor.net/
https://rpm.glyndor.net/fc45/glyndor.repo
https://rpm.glyndor.net/fc45/x86_64/repodata/repomd.xml
https://rpm.glyndor.net/fc45/x86_64/repodata/repomd.xml.asc
https://rpm.glyndor.net/glyndor-rpm-key.asc
https://rpm.glyndor.net/index.html
https://rpm.glyndor.net/install/podup" "$(urls)"
check "a package and a checksum-named file are not" 0 "$(urls | grep -c -E 'Packages|primary')"
check "the token is not on the command line" 0 "$(grep -c 'tok-secret-value' "$WORK/args")"
check "it reaches curl on stdin" 1 "$(grep -c 'Bearer tok-secret-value' "$WORK/stdin")"
check "everything is never purged" 0 "$(grep -c 'purge_everything' "$WORK/bodies")"
check "the zone is in the URL" 1 "$(grep -c 'zones/0123456789abcdef0123456789abcdef/purge_cache' "$WORK/args")"

for i in $(seq 1 70); do echo x > "$T/install/p$i"; done
check "a long list still succeeds" 0 "$(run https://rpm.glyndor.net "$T")"
check "in more than one request" 1 "$([ "$(wc -l < "$WORK/bodies")" -ge 3 ] && echo 1 || echo 0)"
check "none with more than 30 URLs" 0 "$(jq -r '.files | length' "$WORK/bodies" | awk '$1 > 30' | wc -l)"
check "every URL once" 0 "$(urls | uniq -d | wc -l)"
# a group too big for one request is cut, and the URLs gathered before it are still sent
expected() { # <tree>: the URLs of the files that change in place, and of the root
	{
		(cd "$1" && find . -type f ! -path '*/Packages/*' ! -name '[0-9a-f]*-primary.xml.gz' -printf '%P\n' | sed 's|^|https://rpm.glyndor.net/|')
		echo https://rpm.glyndor.net/
	} | sort
}
check "and none of them is lost before the long group" "$(expected "$T")" "$(urls)"
# the signature and the index it signs, and the repository file of the id, are never in two requests
mkdir -p "$T/fc44/x86_64/repodata" "$T/fc44/aarch64/repodata"
for f in fc44/glyndor.repo fc44/x86_64/repodata/repomd.xml fc44/x86_64/repodata/repomd.xml.asc fc44/aarch64/repodata/repomd.xml fc44/aarch64/repodata/repomd.xml.asc; do echo x > "$T/$f"; done
for n in 23 24 25 26 27 28 29 30; do
	rm -f "$T"/install/p*; for i in $(seq 1 "$n"); do echo x > "$T/install/p$i"; done
	run https://rpm.glyndor.net "$T" > /dev/null
	check "with $n installers, the five files of fc44 are in one request" 1 "$(jq -r '.files | map(select(startswith("https://rpm.glyndor.net/fc44/"))) | length' "$WORK/bodies" | grep -c '^5$')"
done
rm -f "$T"/install/p*; for i in $(seq 1 70); do echo x > "$T/install/p$i"; done; run https://rpm.glyndor.net "$T" > /dev/null
sent="$(jq -r '.files | length' "$WORK/bodies" | awk '{ n += $1 } END { print n }')"
check "the count said is the number sent" 1 "$(grep -c "purged $sent URL" "$WORK/out")"

check "an answer that is not success is a failure" 1 "$(FAKE_CURL_REPLY='{"success":false}' run https://rpm.glyndor.net "$T")"
check "an answer that is not JSON is a failure" 1 "$(FAKE_CURL_REPLY='<html>' run https://rpm.glyndor.net "$T")"
check "a curl that fails is a failure" 1 "$(FAKE_CURL_RC=28 run https://rpm.glyndor.net "$T")"
check "a budget of zero seconds is a failure" 1 "$(run https://rpm.glyndor.net "$T" 0)"
check "and says the budget ran out" 1 "$(grep -c 'budget of 0s ran out' "$WORK/out")"
check "a budget that is not a number is refused" 1 "$(run https://rpm.glyndor.net "$T" soon)"
check "a base URL that is not https is refused" 1 "$(run http://rpm.glyndor.net "$T")"
check "a base URL with a path is refused" 1 "$(run https://rpm.glyndor.net/x "$T")"
check "a tree that is not there is refused" 1 "$(run https://rpm.glyndor.net "$WORK/none")"
mkdir "$WORK/emptytree"
check "a tree with nothing to purge is refused" 1 "$(run https://rpm.glyndor.net "$WORK/emptytree")"
check "no token is refused" 1 "$(CF_TOKEN='' run https://rpm.glyndor.net "$T")"
check "a zone that is not an id is refused" 1 "$(CF_ZONE=../x run https://rpm.glyndor.net "$T")"
check "too few arguments are refused" 1 "$("$PURGE" https://rpm.glyndor.net > /dev/null 2>&1; echo $?)"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
