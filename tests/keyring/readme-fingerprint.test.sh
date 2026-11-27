#!/usr/bin/env bash
#
# README.md tells a reader which fingerprint to check a key against, and the key in
# keyring/ is what the repository is signed with. They have to be the same key:
# a README that names another fingerprint sends the reader to distrust the real key,
# or to trust a different one, and nothing else reads the README.
#
# The README writes the fingerprint in groups of four, the form gpg prints it in. The
# test removes the spaces, reads the primary fingerprint of the key file with gpg in
# a scratch home, and requires them to be equal. It is run over planted READMEs first:
# one that names another fingerprint, one that names none, one that names two, and a
# fingerprint written without its groups.
#
# Requires: gpg, coreutils.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
stop_agent() {
	# The agent of the temporary keyring is closed before its folder goes, and its socket folder with it.
	timeout 10 gpgconf --homedir "$WORK/home" --kill all >/dev/null 2>&1 || true
	gpgconf --homedir "$WORK/home" --remove-socketdir >/dev/null 2>&1 || true
}
trap 'stop_agent; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"
chmod 700 "$WORK/home"
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

key_fingerprint() { # $1=key file: its primary fingerprint
	GNUPGHOME="$WORK/home" gpg --batch --no-tty --show-keys --with-colons "$1" 2>/dev/null \
		| awk -F: '/^pub:/{want=1;next} /^fpr:/{if(want){print $10;want=0}}'
}

# The fingerprints a README writes in ten groups of four hexadecimal digits, one per
# line with the spaces removed. A line of forty digits with no spaces is not read.
readme_fingerprints() { # $1=README
	grep -E '^([0-9A-F]{4} ){9}[0-9A-F]{4}$' "$1" | tr -d ' ' || true
}

# One line per offence of the README at $1 against the key file at $2.
audit() { # $1=README $2=key
	local found expected
	found="$(readme_fingerprints "$1")"
	expected="$(key_fingerprint "$2")"
	[ -n "$expected" ] || { echo "no fingerprint could be read from the key"; return; }
	case "$(printf '%s\n' "$found" | grep -c . || true)" in
	0) echo "the README writes no fingerprint in groups of four" ;;
	1) [ "$found" = "$expected" ] || echo "the README writes $found, the key is $expected" ;;
	*) echo "the README writes more than one fingerprint" ;;
	esac
}

KEY="$(ls "$HERE"/keyring/glyndor-*-key.asc)"
real="$(key_fingerprint "$KEY")"
spaced="$(printf '%s' "$real" | sed 's/..../& /g; s/ $//')"
other="0000 1111 2222 3333 4444 5555 6666 7777 8888 9999"

printf 'Fingerprint:\n\n%s\n' "$spaced" > "$WORK/ok.md"
check "a README with the key's fingerprint passes" "" "$(audit "$WORK/ok.md" "$KEY")"
printf 'Fingerprint:\n\n%s\n' "$other" > "$WORK/other.md"
check "a README with another fingerprint is reported" \
	"the README writes 0000111122223333444455556666777788889999, the key is $real" "$(audit "$WORK/other.md" "$KEY")"
printf 'No fingerprint here\n' > "$WORK/none.md"
check "a README with no fingerprint is reported" "the README writes no fingerprint in groups of four" "$(audit "$WORK/none.md" "$KEY")"
printf '%s\n\n%s\n' "$spaced" "$other" > "$WORK/two.md"
check "a README with two fingerprints is reported" "the README writes more than one fingerprint" "$(audit "$WORK/two.md" "$KEY")"
printf '%s\n' "$real" > "$WORK/bare.md"
check "a fingerprint written without its groups is not read" "the README writes no fingerprint in groups of four" "$(audit "$WORK/bare.md" "$KEY")"
printf 'x\n' > "$WORK/notakey.asc"
check "a key that cannot be read is reported" "no fingerprint could be read from the key" "$(audit "$WORK/ok.md" "$WORK/notakey.asc")"

check "README.md names the fingerprint of the key in keyring/" "" "$(audit "$HERE/README.md" "$KEY")"

echo "$pass passed, $fail failed"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
