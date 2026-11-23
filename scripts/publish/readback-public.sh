#!/usr/bin/env bash
#
# Read the index of every repository back through the public address, after the upload and the purge, and
# refuse it unless it is the one that was just built.
#
# Usage: readback-public.sh <base-url> <tree> <public-key.asc> [<attempts> [<delay seconds>]]
#
# The upload is read back from the bucket by sync-tree.sh; this reads it as a client does, through the edge,
# where a cached old repomd.xml next to a purged new signature (or the reverse) is what would break every dnf
# transaction of a host. The purge is asynchronous, so a mismatch is retried (6 times, 10 seconds apart by
# default) before it is a failure. Each pair must equal the tree's byte for byte and verify with the archive key.
# Requires: curl, gpg, gpgv.
set -euo pipefail
export LC_ALL=C

die() { echo "::error::readback-public: $*" >&2; exit 1; }
if [ "$#" -lt 3 ] || [ "$#" -gt 5 ]; then die "usage: readback-public.sh <base-url> <tree> <public-key.asc> [<attempts> [<delay>]]"; fi
BASE="${1%/}"; TREE="$2"; PUB="$3"; ATTEMPTS="${4:-6}"; DELAY="${5:-10}"
[[ "$BASE" =~ ^(https://[a-z0-9.-]+|file:///[A-Za-z0-9._/+-]+|http://127\.0\.0\.1:[0-9]+)$ ]] || die "the address '$BASE' is not allowed"
[[ "$ATTEMPTS" =~ ^[1-9][0-9]?$ && "$DELAY" =~ ^[0-9]+$ ]] || die "attempts or delay is not a number"
if [ ! -d "$TREE" ] || [ ! -f "$PUB" ]; then die "$TREE is not a directory or $PUB is not a file"; fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gpg --batch --no-default-keyring --keyring "$WORK/ring.kbx" --import "$PUB" > /dev/null 2>&1 || die "cannot read $PUB"
fetch() { # <url> <file>
	curl --max-time 60 --connect-timeout 15 --silent --fail -H 'Cache-Control: no-cache' --output "$2" "$1" 2> /dev/null
}
pairs=0
while IFS= read -r dir; do
	rel="${dir#"$TREE"/}"; rel="${rel%/repodata}"
	ok=0
	for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
		if fetch "$BASE/$rel/repodata/repomd.xml" "$WORK/repomd.xml" && fetch "$BASE/$rel/repodata/repomd.xml.asc" "$WORK/repomd.xml.asc" \
			&& cmp -s "$WORK/repomd.xml" "$dir/repomd.xml" && cmp -s "$WORK/repomd.xml.asc" "$dir/repomd.xml.asc" \
			&& gpgv --keyring "$WORK/ring.kbx" "$WORK/repomd.xml.asc" "$WORK/repomd.xml" > /dev/null 2>&1; then
			ok=1; break
		fi
		[ "$attempt" -eq "$ATTEMPTS" ] || sleep "$DELAY"
	done
	[ "$ok" -eq 1 ] || die "$rel: the index served at $BASE is not the one that was published, after $ATTEMPTS attempt(s)"
	pairs=$((pairs + 1))
done < <(find "$TREE" -type d -name repodata | sort)
[ "$pairs" -ge 1 ] || die "the tree has no repository"
echo "read back $pairs repository index(es) through $BASE"
