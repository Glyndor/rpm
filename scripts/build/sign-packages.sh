#!/usr/bin/env bash
#
# Sign every .rpm of a directory with the repository's archive key, at a time the package fixes.
#
# Usage: sign-packages.sh <public-key.asc> <dir>
#
# GNUPGHOME names a home that holds exactly one secret key, which must be the one whose public half
# is <public-key.asc>. The signature time of a package is the later of its build time and the time
# the key was made, never now: EdDSA is deterministic, so a package signed again, on any day, gets
# the same bytes, and a version that was published can be built again without changing a byte of
# it (a changed byte is a refusal later, in repo-state.py order). A time before the key was made
# would give a signature that rpm refuses ("not alive"), which is why the key's time is the floor.
#
# Every package is checked after signing, with rpm, against a scratch database that holds only the
# public key: digests and signature must both read OK.
# Requires: rpm (rpmsign, rpmkeys), gpg.
set -euo pipefail
export LC_ALL=C
die() { echo "::error::sign-packages: $*" >&2; exit 1; }

[ "$#" -eq 2 ] || die "usage: sign-packages.sh <public-key.asc> <dir>"
PUB="$1"; DIR="$2"
[ -f "$PUB" ] || die "$PUB is not a file"
[ -d "$DIR" ] || die "$DIR is not a directory"
if [ -z "${GNUPGHOME:-}" ] || [ ! -d "$GNUPGHOME" ]; then die "GNUPGHOME names no directory"; fi

want="$(gpg --batch --show-keys --with-colons "$PUB" | awk -F: '$1 == "fpr" { print $10; exit }')"
[ -n "$want" ] || die "$PUB holds no key"
mapfile -t secret < <(gpg --batch --list-secret-keys --with-colons | awk -F: '$1 == "sec" { print $5 }')
[ "${#secret[@]}" -eq 1 ] || die "GNUPGHOME holds ${#secret[@]} secret keys; exactly one is allowed"
have="$(gpg --batch --list-secret-keys --with-colons | awk -F: '$1 == "fpr" { print $10; exit }')"
[ "$have" = "$want" ] || die "the secret key ($have) is not the one the public key file holds ($want)"
created="$(gpg --batch --list-secret-keys --with-colons | awk -F: '$1 == "sec" { print $6; exit }')"

shopt -s nullglob
files=("$DIR"/*.rpm)
[ "${#files[@]}" -ge 1 ] || die "no .rpm in $DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
real_gpg="$(command -v gpg)"
for f in "${files[@]}"; do
	built="$(rpm --dbpath "$WORK/db0" -qp --nosignature --nodigest --qf '%{BUILDTIME}' "$f")" || die "cannot read $(basename "$f")"
	[[ "$built" =~ ^[0-9]+$ ]] || die "$(basename "$f") has no build time"
	at="$built"; [ "$at" -ge "$created" ] || at="$created"
	cat > "$WORK/gpg" <<WRAP
#!/bin/sh
exec "$real_gpg" --faked-system-time "$at!" "\$@"
WRAP
	chmod +x "$WORK/gpg"
	rpmsign --addsign --define "__gpg $WORK/gpg" --define "_gpg_name $want" --define "_gpg_path $GNUPGHOME" "$f" \
		> "$WORK/log" 2>&1 || { cat "$WORK/log" >&2; die "could not sign $(basename "$f")"; }
done

mkdir "$WORK/db"
rpmkeys --dbpath "$WORK/db" --import "$PUB" || die "rpm cannot import $PUB"
for f in "${files[@]}"; do
	out="$(rpmkeys --dbpath "$WORK/db" -K "$f" 2>&1)" || die "rpm refuses $(basename "$f"): $out"
	case "$out" in
		*"digests signatures OK") ;;
		*) die "$(basename "$f") does not verify after signing: $out" ;;
	esac
done
echo "signed ${#files[@]} package(s) with $want"
