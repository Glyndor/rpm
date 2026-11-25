#!/usr/bin/env bash
#
# scripts/build/sign-packages.sh: every package is signed with the archive key at a time the package
# fixes, the same package gives the same bytes on any day, and a wrong key or more than one secret key
# stops it before anything is signed.
# Requires: rpm, gpg, python3 with cryptography.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/tree.sh"
SIGN="$HERE/scripts/build/sign-packages.sh"
WORK="$(mktemp -d)"
trap 'fx_stop_agent; rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
fx_init "$WORK"; fx_archive_key
mkdir "$WORK/a" "$WORK/b"
fx_rpm "$WORK/a" tiny 1.0.0 1.glyndor.any noarch; fx_rpm "$WORK/a" other 2.0.0 1.glyndor.any x86_64
cp "$WORK/a"/*.rpm "$WORK/b"/

out="$("$SIGN" "$WORK/archive.asc" "$WORK/a" 2>&1)"; check "signing succeeds" 0 "$?"
check "and says how many" 1 "$(printf '%s' "$out" | grep -c 'signed 2 package')"
mkdir "$WORK/db"; rpmkeys --dbpath "$WORK/db" --import "$WORK/archive.asc"
check "rpm accepts both signatures" 2 "$(rpmkeys --dbpath "$WORK/db" -K "$WORK/a"/*.rpm 2>&1 | grep -c 'digests signatures OK')"
check "an unsigned package is not accepted by the key" 0 "$(rpmkeys --dbpath "$WORK/db" -K "$WORK/b"/*.rpm 2>&1 | grep -c 'digests signatures OK')"
"$SIGN" "$WORK/archive.asc" "$WORK/b" > /dev/null 2>&1
check "the same package signed at the same time is the same file" "$(sha256sum "$WORK/a"/*.rpm | cut -d' ' -f1 | tr '\n' ' ')" \
	"$(sha256sum "$WORK/b"/*.rpm | cut -d' ' -f1 | tr '\n' ' ')"
sleep 2
rm -rf "${WORK:?}/c"; mkdir "$WORK/c"; cp "$WORK/b"/*.rpm "$WORK/c"/
rpmsign --delsign "$WORK/c"/*.rpm > /dev/null 2>&1
"$SIGN" "$WORK/archive.asc" "$WORK/c" > /dev/null 2>&1
check "signed again two seconds later, a package is the same file" "$(sha256sum "$WORK/a"/*.rpm | cut -d' ' -f1 | tr '\n' ' ')" \
	"$(sha256sum "$WORK/c"/*.rpm | cut -d' ' -f1 | tr '\n' ' ')"
rm -rf "${WORK:?}/e"; mkdir "$WORK/e"; fx_rpm "$WORK/e" old 1.0.0 1.glyndor.any noarch buildtime=1700000000
out="$("$SIGN" "$WORK/archive.asc" "$WORK/e" 2>&1)"; check "a package built before the key was made is signed at the key's time" 0 "$?"
check "and rpm accepts it" 1 "$(rpmkeys --dbpath "$WORK/db" -K "$WORK/e"/*.rpm 2>&1 | grep -c 'digests signatures OK')"

refuse() { # <description> <fragment> <args...>
	local d="$1" frag="$2" o rc=0; shift 2
	o="$("$SIGN" "$@" 2>&1)" || rc=$?
	check "$d: refused" 1 "$rc"
	check "$d: says why" 1 "$(printf '%s' "$o" | grep -cF -- "$frag")"
}
rm -rf "${WORK:?}/d"; mkdir "$WORK/d"; fx_rpm "$WORK/d" tiny 1.0.0 1.glyndor.any noarch
refuse "a directory with no package" "no .rpm" "$WORK/archive.asc" "$WORK"/keys
refuse "a public key file that does not exist" "is not a file" "$WORK/none.asc" "$WORK/d"
refuse "a directory that does not exist" "is not a directory" "$WORK/archive.asc" "$WORK/none"
refuse "too few arguments" "usage" "$WORK/archive.asc"
mkdir -p "$WORK/g2"; chmod 700 "$WORK/g2"
GNUPGHOME="$WORK/g2" gpg --batch --pinentry-mode loopback --passphrase '' --faked-system-time "$FX_T0!" \
	--quick-gen-key 'Other <o@example.invalid>' ed25519 sign never > /dev/null 2>&1
GNUPGHOME="$WORK/g2" gpg --batch --armor --export > "$WORK/other.asc"
refuse "the secret key is not the one the public file holds" "is not the one the public key file holds" "$WORK/other.asc" "$WORK/d"
GNUPGHOME="$WORK/g2" fx_stop_agent
cp -r "$WORK/gnupg" "$WORK/g3"; chmod 700 "$WORK/g3"
GNUPGHOME="$WORK/g3" gpg --batch --pinentry-mode loopback --passphrase '' --faked-system-time "$FX_T0!" \
	--quick-gen-key 'Second <s@example.invalid>' ed25519 sign never > /dev/null 2>&1
o="$(GNUPGHOME="$WORK/g3" "$SIGN" "$WORK/archive.asc" "$WORK/d" 2>&1)"; rc=$?
check "two secret keys in the home: refused" 1 "$rc"
check "two secret keys: says why" 1 "$(printf '%s' "$o" | grep -c 'exactly one is allowed')"
GNUPGHOME="$WORK/g3" fx_stop_agent
o="$(env -u GNUPGHOME "$SIGN" "$WORK/archive.asc" "$WORK/d" 2>&1)"; check "no GNUPGHOME: refused" 1 "$?"
o="$(GNUPGHOME="$WORK/none" "$SIGN" "$WORK/archive.asc" "$WORK/d" 2>&1)"; check "a GNUPGHOME that is not there: refused" 1 "$?"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
