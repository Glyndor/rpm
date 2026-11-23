#!/usr/bin/env bash
#
# keyring/glyndor-rpm-key.asc is the public half of the key this repository will sign
# its metadata with, and the fingerprint written below is the anchor everything
# else is checked against. A file in `keyring/` that is not that key (another
# key, a key with an expiry, a private block, two keys in one file, a file that is
# not a key at all) would be installed by whoever trusts the repository, and
# nothing would say so: it is a text file that every other check ignores.
#
# The fingerprint, the algorithm (Ed25519), the absence of an expiry, the label
# and the fact that the file holds a public key and nothing else are all read from
# the file with gpg in a scratch home, and the reader is run over planted keys
# first so that a pass is shown to come from a check that can fail.
#
# The fingerprint here is the one the owner recorded when the key was generated
# on 2026-11-22. It is not read from the file under test.
#
# Requires: gpg, coreutils.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEY="$HERE/keyring/glyndor-rpm-key.asc"
EXPECTED="FA78C216E91765E1950A29278903DA0D602C7E28"
LABEL="Glyndor rpm repository signing key <rpm@glyndor.net>"
WORK="$(mktemp -d)"
# Every agent this test starts lives in a scratch home under $WORK and is stopped by
# naming that home, with a bound: a bare `gpgconf --kill` would stop the agent of
# whoever runs the test, and an agent that hangs would keep the rm from running.
stop_agents() {
	local h
	for h in "$WORK"/home "$WORK"/gen-*; do
		[ -d "$h" ] || continue
		GNUPGHOME="$h" timeout 10 gpgconf --kill gpg-agent >/dev/null 2>&1 || true
	done
}
trap 'stop_agents; rm -rf "$WORK"' EXIT
pass=0
fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
		echo "ok    $1"
	else
		fail=$((fail + 1))
		echo "FAIL  $1"
		echo "        expected: $2"
		echo "        actual:   $3"
	fi
}

home="$WORK/home"
mkdir -p "$home"
chmod 700 "$home"

# One line per offence in the key file at $1; nothing when it is the key.
audit() { # $1=file
	local file="$1" colons
	if grep -q 'PRIVATE KEY BLOCK' "$file"; then
		echo "the file holds a private key block"
		return
	fi
	if ! grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----$' "$file"; then
		echo "the file holds no public key block"
		return
	fi
	if ! colons="$(GNUPGHOME="$home" timeout 30 gpg --batch --no-tty --show-keys --with-colons "$file" 2>/dev/null)" \
		|| [ -z "$colons" ]; then
		echo "gpg cannot read a key from the file"
		return
	fi
	local primaries
	primaries="$(printf '%s\n' "$colons" | grep -c '^pub:' || true)"
	[ "$primaries" -eq 1 ] || echo "the file holds $primaries primary keys, not one"
	[ "$(printf '%s\n' "$colons" | grep -c '^sub:' || true)" -eq 0 ] || echo "the file holds a subkey"
	local fpr
	fpr="$(printf '%s\n' "$colons" | awk -F: '/^pub:/{want=1;next} /^fpr:/{if(want){print $10;want=0}}' | paste -sd, -)"
	[ "$fpr" = "$EXPECTED" ] || echo "the fingerprint is ${fpr:-none}, not $EXPECTED"
	local pub
	pub="$(printf '%s\n' "$colons" | grep -m1 '^pub:' || true)"
	[ "$(printf '%s' "$pub" | cut -d: -f4)" = 22 ] || echo "the primary key is not EdDSA"
	[ "$(printf '%s' "$pub" | cut -d: -f17)" = ed25519 ] || echo "the primary key is not on the ed25519 curve"
	[ -z "$(printf '%s' "$pub" | cut -d: -f7)" ] || echo "the primary key expires"
	case "$(printf '%s' "$pub" | cut -d: -f2)" in
	r) echo "the primary key is revoked" ;;
	e) echo "the primary key has expired" ;;
	esac
	case "$(printf '%s' "$pub" | cut -d: -f12)" in
	*[sS]*) ;;
	*) echo "the primary key cannot sign" ;;
	esac
	local uids
	uids="$(printf '%s\n' "$colons" | awk -F: '/^uid:/{print $10}')"
	[ "$uids" = "$LABEL" ] || echo "the user id is '${uids:-none}', not '$LABEL'"
}

keygen() { # <name> <algo> <expire> <uid>: an armored public key in $WORK/<name>.asc
	local h="$WORK/gen-$1"
	mkdir -p "$h"
	chmod 700 "$h"
	GNUPGHOME="$h" gpg --batch --no-tty --quiet --passphrase '' --quick-generate-key "$4" "$2" sign "$3" 2>/dev/null
	GNUPGHOME="$h" gpg --batch --no-tty --armor --export > "$WORK/$1.asc"
	GNUPGHOME="$h" gpg --batch --no-tty --armor --export-secret-keys > "$WORK/$1.secret.asc" 2>/dev/null || true
	GNUPGHOME="$h" timeout 10 gpgconf --kill gpg-agent >/dev/null 2>&1 || true
}

# A key with the right shape and a different identity: the fingerprint is the only
# thing that tells it from the real one.
keygen other ed25519 never "$LABEL"
check "a key that is not the recorded one is refused for its fingerprint" \
	"the fingerprint is $(GNUPGHOME="$home" gpg --batch --show-keys --with-colons "$WORK/other.asc" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}'), not $EXPECTED" \
	"$(audit "$WORK/other.asc")"

keygen rsa rsa3072 never "$LABEL"
check "an RSA key is refused: wrong fingerprint, algorithm and curve" "3" "$(audit "$WORK/rsa.asc" | grep -c .)"
check "and the algorithm is among the reasons" "1" "$(audit "$WORK/rsa.asc" | grep -c 'not EdDSA')"

keygen expiring ed25519 1y "$LABEL"
check "a key with an expiry is reported" "1" "$(audit "$WORK/expiring.asc" | grep -c 'the primary key expires')"

keygen renamed ed25519 never "Somebody Else <someone@example.invalid>"
check "a key with another user id is reported" "1" "$(audit "$WORK/renamed.asc" | grep -c 'the user id is')"

check "a private key block is refused before anything is parsed" "the file holds a private key block" "$(audit "$WORK/other.secret.asc")"

cat "$WORK/other.asc" "$WORK/renamed.asc" > "$WORK/two.asc"
check "two keys in one file are reported" "1" "$(audit "$WORK/two.asc" | grep -c 'holds 2 primary keys')"

printf 'not a key\n' > "$WORK/text.asc"
check "a file that is not a key is reported" "the file holds no public key block" "$(audit "$WORK/text.asc")"

printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nAAAA\n-----END PGP PUBLIC KEY BLOCK-----\n' > "$WORK/garbled.asc"
check "a block gpg cannot read is reported" "gpg cannot read a key from the file" "$(audit "$WORK/garbled.asc")"

: > "$WORK/empty.asc"
check "an empty file is reported" "the file holds no public key block" "$(audit "$WORK/empty.asc")"

# The file itself, last: the planted cases above show this verdict can be red.
check "keyring/glyndor-rpm-key.asc is the recorded key" "" "$(audit "$KEY")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
