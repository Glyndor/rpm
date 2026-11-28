#!/usr/bin/env bash
#
# scripts/build/build-installers.sh: one script per product from the template, with the fingerprint
# read from the key file, and the inputs it refuses.
# Requires: gpg, python3 with cryptography.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/tree.sh"
BUILD="$HERE/scripts/build/build-installers.sh"
WORK="$(mktemp -d)"
trap 'fx_stop_agent; rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
fx_init "$WORK"; fx_archive_key; fx_other_key "$WORK/other.asc"
FPR="$(gpg --batch --show-keys --with-colons "$WORK/archive.asc" | awk -F: '$1 == "fpr" { print $10; exit }')"

out="$("$BUILD" "$WORK/archive.asc" "$WORK/o" podup epistle helmly-agent 2>&1)"; check "three installers are rendered" 0 "$?"
check "one file per product" "epistle helmly-agent podup" "$(fx_names "$WORK/o")"
check "each is executable" 3 "$(find "$WORK/o" -type f -perm -755 | wc -l)"
check "each carries the product" 3 "$(grep -c -E '^GLYNDOR_PRODUCT="(podup|epistle|helmly-agent)"' "$WORK"/o/* | grep -c ':1$')"
check "each carries the fingerprint of the key file" 3 "$(grep -l "GLYNDOR_FPR=\"$FPR\"" "$WORK"/o/* | wc -l)"
check "each carries the public origin" 3 "$(grep -l 'GLYNDOR_BASE="https://rpm.glyndor.net"' "$WORK"/o/* | wc -l)"
check "each parses as POSIX sh" 0 "$(for f in "$WORK"/o/*; do sh -n "$f" || echo bad; done | wc -l)"
check "a test origin is written when it is given" 1 "$(REPO_BASE_URL=http://127.0.0.1:1 "$BUILD" "$WORK/archive.asc" "$WORK/o2" podup > /dev/null 2>&1; grep -c 'GLYNDOR_BASE="http://127.0.0.1:1"' "$WORK/o2/podup")"

refuse() { # <description> <fragment> <args...>
	local d="$1" frag="$2" o rc=0; shift 2
	o="$("$BUILD" "$@" 2>&1)" || rc=$?
	check "$d: refused" 1 "$rc"
	check "$d: says why" 1 "$(printf '%s' "$o" | grep -cF -- "$frag")"
}
refuse "a product that is not in the config" "is not a product of config/products.txt" "$WORK/archive.asc" "$WORK/o3" nginx
refuse "a product name that is a path" "is not a product" "$WORK/archive.asc" "$WORK/o3" ../podup
refuse "a regular expression as a product" "is not a product" "$WORK/archive.asc" "$WORK/o3" 'pod.p'
cat "$WORK/archive.asc" "$WORK/other.asc" > "$WORK/two.asc"
refuse "a key file with two keys" "exactly one key" "$WORK/two.asc" "$WORK/o3" podup
printf 'junk\n' > "$WORK/junk.asc"
refuse "a file that is not a key" "exactly one key" "$WORK/junk.asc" "$WORK/o3" podup
refuse "a key file that is not there" "is not a file" "$WORK/none.asc" "$WORK/o3" podup
refuse "no product at all" "usage" "$WORK/archive.asc" "$WORK/o3"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
