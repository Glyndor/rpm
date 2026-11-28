#!/usr/bin/env bash
#
# scripts/publish/tree-digest.sh: one digest for every file of a tree, by path and by content, so the job that publishes can
# check that the artifact it downloaded is the tree the signing job made.
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
fx_init "$WORK"; fx_archive_key
mkdir -p "$WORK/v/p"; fx_rpm "$WORK/v/p" podup 1.2.3 1.glyndor.any noarch
fx_build_tree "$WORK/tree" "$FX_T1" "$WORK/v" > /dev/null 2>&1

# --- the digest of the tree -------------------------------------------------------------------------
DIG="$HERE/scripts/publish/tree-digest.sh"
d0="$("$DIG" "$WORK/tree")"
check "the digest is a sha256" 1 "$([[ "$d0" =~ ^[0-9a-f]{64}$ ]] && echo 1 || echo 0)"
check "the same tree gives the same digest" "$d0" "$("$DIG" "$WORK/tree")"
cp -r "$WORK/tree" "$WORK/copy"
check "a copy of the tree gives it too" "$d0" "$("$DIG" "$WORK/copy")"
printf 'x' >> "$WORK/copy/glyndor-rpm-key.asc"
check "one byte more in a file changes it" 1 "$([ "$("$DIG" "$WORK/copy")" != "$d0" ] && echo 1 || echo 0)"
rm -rf "${WORK:?}/copy"; cp -r "$WORK/tree" "$WORK/copy"
mv "$WORK/copy/fc45/x86_64/repodata/repomd.xml" "$WORK/copy/fc45/x86_64/repodata/repomd.xml.moved"
check "a file under another name changes it" 1 "$([ "$("$DIG" "$WORK/copy")" != "$d0" ] && echo 1 || echo 0)"
rm -rf "${WORK:?}/copy"; cp -r "$WORK/tree" "$WORK/copy"; : > "$WORK/copy/extra"
check "an extra empty file changes it" 1 "$([ "$("$DIG" "$WORK/copy")" != "$d0" ] && echo 1 || echo 0)"
rm -rf "${WORK:?}/copy"; cp -r "$WORK/tree" "$WORK/copy"; ln -s /etc/passwd "$WORK/copy/link"
"$DIG" "$WORK/copy" > "$WORK/out" 2>&1; check "a link in the tree is refused" 1 "$?"
check "and says what is wrong" 1 "$(grep -c 'neither a file nor a folder' "$WORK/out")"
"$DIG" "$WORK/missing" > /dev/null 2>&1; check "a folder that does not exist is refused" 1 "$?"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
