#!/usr/bin/env bash
#
# scripts/verify/verify-release-sig.py: the exit status it gives for each way a signature or a key
# file can be wrong, since admit-release.sh reads that status and nothing else.
# Requires: python3 with cryptography.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
SIG="$HERE/scripts/verify/verify-release-sig.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }
fx_init "$WORK"
KEY="$WORK/keyring/glyndor-release-ed25519.b64"
printf 'the bytes of a package' > "$WORK/data"; fx_sign "$WORK/data"
v() { python3 -I "$SIG" "$@"; }

check "a valid signature verifies" 0 "$(status v ed25519 "$WORK/data.sig" "$WORK/data" "$KEY")"
check "and keeps the verified bytes" 0 "$(v ed25519 "$WORK/data.sig" "$WORK/data" "$KEY" "$WORK/copy" >/dev/null 2>&1; cmp -s "$WORK/data" "$WORK/copy"; echo $?)"
check "the copy is private to the owner" "600" "$(stat -c%a "$WORK/copy")"
check "a copy that exists already is not overwritten (4)" 4 "$(status v ed25519 "$WORK/data.sig" "$WORK/data" "$KEY" "$WORK/copy")"
printf 'other bytes' > "$WORK/data2"
check "a signature of other bytes is bad (1)" 1 "$(status v ed25519 "$WORK/data.sig" "$WORK/data2" "$KEY")"
head -c 63 "$WORK/data.sig" > "$WORK/short.sig"
check "a signature that is 63 bytes is bad (1)" 1 "$(status v ed25519 "$WORK/short.sig" "$WORK/data" "$KEY")"
head -c 65 /dev/zero > "$WORK/long.sig"
check "a signature that is 65 bytes is bad (1)" 1 "$(status v ed25519 "$WORK/long.sig" "$WORK/data" "$KEY")"
check "a signature file that is missing is bad (1)" 1 "$(status v ed25519 "$WORK/none.sig" "$WORK/data" "$KEY")"
mkdir "$WORK/o"; python3 -I "$HERE/tests/fixtures/rpm/release-key.py" gen-ed "$WORK/o"
check "a signature checked against another key is bad (1)" 1 "$(status v ed25519 "$WORK/data.sig" "$WORK/data" "$WORK/o/ed.b64")"
{ cat "$WORK/o/ed.b64"; printf '# the rotation overlap\n\n'; cat "$KEY"; } > "$WORK/two.b64"
check "any key of the file may verify, comments and blank lines are ignored" 0 "$(status v ed25519 "$WORK/data.sig" "$WORK/data" "$WORK/two.b64")"
check "a key file that is missing is a local error (2)" 2 "$(status v ed25519 "$WORK/data.sig" "$WORK/data" "$WORK/none.b64")"
: > "$WORK/empty.b64"
check "a key file with no key is a local error (2)" 2 "$(status v ed25519 "$WORK/data.sig" "$WORK/data" "$WORK/empty.b64")"
printf '%s\r\n' "$(cat "$KEY")" > "$WORK/crlf.b64"
check "a key file with a carriage return is a local error (2)" 2 "$(status v ed25519 "$WORK/data.sig" "$WORK/data" "$WORK/crlf.b64")"
printf '\xef\xbb\xbf%s\n' "$(cat "$KEY")" > "$WORK/bom.b64"
check "a key file with a byte order mark is a local error (2)" 2 "$(status v ed25519 "$WORK/data.sig" "$WORK/data" "$WORK/bom.b64")"
printf '%s\t\n' "$(cat "$KEY")" > "$WORK/tab.b64"
check "a key file with a tab is a local error (2)" 2 "$(status v ed25519 "$WORK/data.sig" "$WORK/data" "$WORK/tab.b64")"
printf 'AAAA\n' > "$WORK/short.b64"
check "a key that is not 32 bytes is a local error (2)" 2 "$(status v ed25519 "$WORK/data.sig" "$WORK/data" "$WORK/short.b64")"
printf '!!!notbase64!!!\n' > "$WORK/junk.b64"
check "a key that is not base64 is a local error (2)" 2 "$(status v ed25519 "$WORK/data.sig" "$WORK/data" "$WORK/junk.b64")"
check "check-keys accepts the good file" 0 "$(status v check-keys ed25519 "$KEY")"
check "check-keys refuses the bad file" 2 "$(status v check-keys ed25519 "$WORK/crlf.b64")"
check "check-keys of the ML-DSA file accepts a comment only" 0 "$(status v check-keys mldsa65 "$HERE/keyring/glyndor-release-mldsa65.b64")"
check "check-keys of the ML-DSA file refuses an Ed25519 key" 2 "$(status v check-keys mldsa65 "$KEY")"
check "an unknown algorithm is refused (2)" 2 "$(status v check-keys rsa "$KEY")"
check "no arguments is a usage error (2)" 2 "$(status v)"
check "an ML-DSA signature with no key configured is bad (1)" 1 "$(head -c 3309 /dev/zero > "$WORK/pq.sig"; status v mldsa65 "$WORK/pq.sig" "$WORK/data" "$WORK/empty.b64")"
head -c 5000 /dev/zero > "$WORK/pqbig.sig"; head -c 1952 /dev/zero | base64 -w0 > "$WORK/pqkey.b64"
check "an ML-DSA signature over the cap is bad (1)" 1 "$(status v mldsa65 "$WORK/pqbig.sig" "$WORK/data" "$WORK/pqkey.b64")"
check "the committed Ed25519 key is one 32 byte key" 0 "$(status v check-keys ed25519 "$HERE/keyring/glyndor-release-ed25519.b64")"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
