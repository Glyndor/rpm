#!/usr/bin/env bash
#
# The second (ML-DSA-65) release signature in scripts/verify/admit-release.sh: the six cases of
# the post-quantum design, plus a required list that a typo cannot switch off. The cases that
# need a verifier use a cryptography with ML-DSA (50.0.2 or later, pinned by hash in
# scripts/verify/verify-release-requirements.txt): a path to its python in
# ADMIT_TEST_MLDSA_PYTHON, or a virtual environment made here. When neither is available the run
# fails: those cases are the point of this file, so a suite that cannot execute them is red, not
# green with a skip in it.
# Requires: rpm (rpmbuild), python3 with cryptography.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
ADMIT="$HERE/scripts/verify/admit-release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
fx_init "$WORK"
fx_static_release "$WORK/base" podup 1.2.3 x86_64,aarch64
X="podup-1.2.3-1.glyndor.any.x86_64.rpm"; A="podup-1.2.3-1.glyndor.any.aarch64.rpm"

# A python that can verify ML-DSA. There is no such thing here without one: the cases that verify a
# real second signature are the point of this file, so a run that cannot execute them is red.
PQPY="${ADMIT_TEST_MLDSA_PYTHON:-}"
if [ -z "$PQPY" ]; then
	if python3 -m venv "$WORK/venv" >/dev/null 2>&1 \
		&& "$WORK/venv/bin/python" -m pip install --quiet --disable-pip-version-check --require-hashes \
			--only-binary=:all: -r "$HERE/scripts/verify/verify-release-requirements.txt" >/dev/null 2>&1; then
		PQPY="$WORK/venv/bin/python"
	fi
fi
if [ -z "$PQPY" ] || ! "$PQPY" -c 'from cryptography.hazmat.primitives.asymmetric.mldsa import MLDSA65PrivateKey' 2>/dev/null; then
	echo "FAIL  no cryptography with ML-DSA-65: install scripts/verify/verify-release-requirements.txt into a virtual environment"
	echo "0 passed, 1 failed"
	printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" 0 1
	exit 1
fi

run() { # <keyring dir> <release dir> [python bin dir]: the verdict of the admission
	local py_path="$PATH"
	[ -z "${3:-}" ] || py_path="$3:$PATH"
	PATH="$py_path" "$ADMIT" --keyring "$1" podup v1.2.3 "$2" 2>&1
}
keyring() { # <name> [pq key file content]: a copy of the keyring with the required list and key given
	rm -rf "${WORK:?}/$1"; cp -r "$WORK/keyring" "$WORK/$1"
	[ -z "${2:-}" ] || printf '%s\n' "$2" > "$WORK/$1/glyndor-release-mldsa65.b64"
	# a key with nobody required is refused (checked below); the cases of this file that hold a key and no list name another product
	if [ -n "${2:-}" ] && ! grep -qvE '^[[:space:]]*(#|$)' "$WORK/$1/pq-required-products"; then echo epistle >> "$WORK/$1/pq-required-products"; fi
}
random_key() { head -c 1952 /dev/urandom | base64 -w0; }
refused() { # <description> <fragment> <keyring> <release>
	local out rc=0
	out="$(run "$3" "$4" "${5:-}")" || rc=$?
	check "$1: refused" 1 "$rc"
	check "$1: says why" 1 "$(printf '%s' "$out" | grep -cF -- "$2")"
}
copy() { rm -rf "$WORK/r"; cp -r "$1" "$WORK/r"; }

# --- the cases that need no ML-DSA library ---------------------------------------------------
keyring k0
out="$(run "$WORK/k0" "$WORK/base")"; check "valid Ed25519, no second signature, not required: admitted" 0 "$?"
check "the required state is said" 1 "$(printf '%s' "$out" | grep -c 'required for podup: no')"
keyring k1; printf 'podup\n' > "$WORK/k1/pq-required-products"
refused "valid Ed25519, no second signature, required" "requires the hybrid release signature" "$WORK/k1" "$WORK/base"
keyring k1b; printf '# a comment on a line of its own\n\nepistle\n' > "$WORK/k1b/pq-required-products"
out="$(run "$WORK/k1b" "$WORK/base")"; check "another product being required does not require this one" 0 "$?"
copy "$WORK/base"; head -c 3309 /dev/urandom > "$WORK/r/$X.mldsa65.sig"
refused "a second signature and no key configured" "ML-DSA-65 signature of $X is not valid" "$WORK/k0" "$WORK/r"
keyring k2 "$(random_key)"
copy "$WORK/base"; head -c 100 /dev/urandom > "$WORK/r/$X.mldsa65.sig"
refused "a second signature of the wrong length" "is not valid" "$WORK/k2" "$WORK/r"
copy "$WORK/base"; head -c 5000 /dev/urandom > "$WORK/r/$X.mldsa65.sig"
refused "a second signature over the 4096 byte cap" "over the 4096-byte signature cap" "$WORK/k2" "$WORK/r"
copy "$WORK/base"; : > "$WORK/r/$X.mldsa65.sig"
refused "an empty second signature" "is not valid" "$WORK/k2" "$WORK/r"
copy "$WORK/base"; head -c 3309 /dev/urandom > "$WORK/r/$X.mldsa65.sig"
refused "a well formed second signature that the installed library cannot check" "is not valid (status" "$WORK/k2" "$WORK/r"
keyring k3 "not base64 at all"
refused "a malformed second key file" "ML-DSA-65 key file" "$WORK/k3" "$WORK/base"
keyring k3b "$(head -c 100 /dev/urandom | base64 -w0)"
refused "a second key of the wrong size" "ML-DSA-65 key file" "$WORK/k3b" "$WORK/base"
for entry in 'podup # since 2.0' 'Podup' 'podup,epistle' 'pod up' '-podup'; do
	keyring k4; printf '%s\n' "$entry" > "$WORK/k4/pq-required-products"
	refused "a required list with the entry '$entry'" "is malformed" "$WORK/k4" "$WORK/base"
done
keyring k5; printf 'podup\r\n' > "$WORK/k5/pq-required-products"
refused "a required list with a carriage return" "not printable ASCII" "$WORK/k5" "$WORK/base"
keyring k6; printf 'podup\n' > "$WORK/k6/pq-required-products"; rm "$WORK/k6/glyndor-release-mldsa65.b64"
refused "a required product when the second key file is missing" "requires the hybrid" "$WORK/k6" "$WORK/base"

# --- the cases that verify a real second signature -------------------------------------------------
PQBIN="$(dirname "$PQPY")"
pqsign() { # <seed> <file>
	"$PQPY" -I "$HERE/tests/fixtures/rpm/release-key.py" sign-pq "$1" "$2"
}
mkdir -p "$WORK/pq1" "$WORK/pq2"
"$PQPY" -I "$HERE/tests/fixtures/rpm/release-key.py" gen-pq "$WORK/pq1"
"$PQPY" -I "$HERE/tests/fixtures/rpm/release-key.py" gen-pq "$WORK/pq2"
keyring kp "$(cat "$WORK/pq1/pq.b64")"
copy "$WORK/base"; pqsign "$WORK/pq1/pq.seed" "$WORK/r/$X"; pqsign "$WORK/pq1/pq.seed" "$WORK/r/$A"
out="$(run "$WORK/kp" "$WORK/r" "$PQBIN")"; check "both signatures valid: admitted" 0 "$?"
keyring kpr "$(cat "$WORK/pq1/pq.b64")"; printf 'podup\n' > "$WORK/kpr/pq-required-products"
out="$(run "$WORK/kpr" "$WORK/r" "$PQBIN")"; check "both signatures valid, required: admitted" 0 "$?"
check "the required state is said" 1 "$(printf '%s' "$out" | grep -c 'required for podup: yes')"
copy "$WORK/base"; pqsign "$WORK/pq1/pq.seed" "$WORK/r/$X"
refused "required, and only one of the two packages carries it" "no ML-DSA-65 signature for $A" "$WORK/kpr" "$WORK/r" "$PQBIN"
copy "$WORK/base"; pqsign "$WORK/pq2/pq.seed" "$WORK/r/$X"; pqsign "$WORK/pq1/pq.seed" "$WORK/r/$A"
refused "a second signature made by another key" "ML-DSA-65 signature of $X is not valid" "$WORK/kp" "$WORK/r" "$PQBIN"
copy "$WORK/base"; pqsign "$WORK/pq1/pq.seed" "$WORK/r/$X"; pqsign "$WORK/pq1/pq.seed" "$WORK/r/$A"
printf 'x' >> "$WORK/r/$X"
refused "a package changed after both signatures" "invalid signature for $X" "$WORK/kp" "$WORK/r" "$PQBIN"
copy "$WORK/base"; pqsign "$WORK/pq1/pq.seed" "$WORK/r/$X"; pqsign "$WORK/pq1/pq.seed" "$WORK/r/$A"
head -c 64 /dev/zero > "$WORK/r/$X.sig"
refused "a valid second signature does not rescue a bad first one" "invalid signature for $X" "$WORK/kp" "$WORK/r" "$PQBIN"
cp "$WORK/pq1/pq.b64" "$WORK/kp/two"; { cat "$WORK/pq2/pq.b64"; cat "$WORK/pq1/pq.b64"; } > "$WORK/kp/glyndor-release-mldsa65.b64"
copy "$WORK/base"; pqsign "$WORK/pq1/pq.seed" "$WORK/r/$X"; pqsign "$WORK/pq1/pq.seed" "$WORK/r/$A"
out="$(run "$WORK/kp" "$WORK/r" "$PQBIN")"; check "a rotation overlap: either key admits" 0 "$?"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
