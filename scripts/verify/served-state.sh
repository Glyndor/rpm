#!/usr/bin/env bash
#
# Fetch what the repository serves today for one distribution and architecture, and check it.
#
# Usage: served-state.sh <base-url> <id> <arch> <out-dir> <public-key.asc>
#
# Writes <out-dir>/repomd.xml and <out-dir>/primary.xml.gz. Exit status: 0 fetched and verified,
# 10 nothing is served there (repomd.xml answers 404, or a file:// tree has none), anything else
# a failure, which is never read as "nothing served": a repository that answers an error, whose
# signature does not verify with the archive key or whose primary metadata does not match the
# checksum repomd.xml gives it stops the run. The base URL is https, or file:// or a local http
# address for a tree that has not been uploaded.
# Requires: curl, gpg, gpgv, python3.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { echo "::error::served-state: $*" >&2; exit 1; }
[ "$#" -eq 5 ] || die "usage: served-state.sh <base-url> <id> <arch> <out-dir> <public-key.asc>"
BASE="$1"; ID="$2"; ARCH="$3"; OUT="$4"; PUB="$5"
[[ "$BASE" =~ ^(https://[a-z0-9.-]+|file:///[A-Za-z0-9._/+-]+|http://127\.0\.0\.1:[0-9]+)$ ]] || die "the base URL '$BASE' is not allowed"
[[ "$ID" =~ ^[a-z0-9]+(\.[0-9]+)?$ && "$ARCH" =~ ^[a-z0-9_]+$ ]] || die "malformed id or architecture"
if [ ! -d "$OUT" ] || [ ! -f "$PUB" ]; then die "$OUT is not a directory, or $PUB is not a file"; fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$BASE/$ID/$ARCH"

get() { # <url> <file> <max bytes>: the HTTP status, or 000 for a file:// URL; never fails on a status
	local rc=0 code
	code="$(
		curl --silent --show-error --max-time 120 --connect-timeout 20 --retry 3 --retry-delay 5 --max-redirs 0 \
			--max-filesize "$3" --write-out '%{http_code}' --output "$2" "$1" 2> "$WORK/curl.err"
	)" || rc=$?
	if [ "$rc" -eq 37 ]; then echo 404; return 0; fi # a file:// URL that does not exist
	if [ "$rc" -ne 0 ]; then cat "$WORK/curl.err" >&2; return "$rc"; fi
	[ "$code" != 000 ] || code=200
	echo "$code"
}
code="$(get "$REPO/repodata/repomd.xml" "$WORK/repomd.xml" $((64 * 1024 * 1024)))" || die "cannot reach $REPO/repodata/repomd.xml"
if [ "$code" = 404 ]; then echo "nothing is served at $ID/$ARCH"; exit 10; fi
[ "$code" = 200 ] || die "$REPO/repodata/repomd.xml answers $code"
code="$(get "$REPO/repodata/repomd.xml.asc" "$WORK/repomd.xml.asc" 65536)" || die "cannot reach the signature of $ID/$ARCH"
[ "$code" = 200 ] || die "the served repomd.xml of $ID/$ARCH has no signature (the server answers $code)"
gpg --batch --no-default-keyring --keyring "$WORK/ring.kbx" --import "$PUB" > /dev/null 2>&1 || die "cannot read $PUB"
gpgv --keyring "$WORK/ring.kbx" "$WORK/repomd.xml.asc" "$WORK/repomd.xml" > /dev/null 2>&1 \
	|| die "the served repomd.xml of $ID/$ARCH is not signed by the archive key"
href="$(python3 -I "$HERE/scripts/verify/repo-state.py" primary "$WORK/repomd.xml")" || die "unreadable repomd.xml of $ID/$ARCH"
code="$(get "$REPO/$href" "$WORK/primary.xml.gz" $((512 * 1024 * 1024)))" || die "cannot reach $REPO/$href"
[ "$code" = 200 ] || die "$REPO/$href answers $code"
python3 -I "$HERE/scripts/verify/repo-state.py" packages "$WORK/repomd.xml" "$WORK/primary.xml.gz" > /dev/null \
	|| die "the served primary metadata of $ID/$ARCH does not match its repomd.xml"
cp "$WORK/repomd.xml" "$OUT/repomd.xml"; cp "$WORK/primary.xml.gz" "$OUT/primary.xml.gz"
echo "fetched the served state of $ID/$ARCH"
