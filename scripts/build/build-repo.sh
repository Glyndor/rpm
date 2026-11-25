#!/usr/bin/env bash
#
# Build the signed repository tree from the packages the admission let in.
#
# Usage: build-repo.sh [--config <dir>] <public-key.asc> <epoch> <admitted-root> <out-dir>
#
# <admitted-root>/<product>/ holds the .rpm files admit-release.sh admitted; <out-dir> must not
# exist. GNUPGHOME names a home with the archive key alone (sign-packages.sh checks it). <epoch> is
# the one time of the run: the signature time of every repomd.xml and the `revision` of the
# metadata, so building again at the same time gives the same files, and the revision grows from one
# run to the next. A package's signature time is its own (sign-packages.sh): the same package is
# the same bytes in every run.
#
# The release says which distribution a package is for in its Release field (`<R>.glyndor.<id>`),
# and `any` means all of them. An architecture-independent package goes into both architectures.
# For each id and architecture that has a package:
#
#   <out>/<id>/<arch>/Packages/<file>.rpm      signed with the archive key
#   <out>/<id>/<arch>/repodata/repomd.xml      createrepo_c, gzip, names that carry their checksum
#   <out>/<id>/<arch>/repodata/repomd.xml.asc  detached, armored, same key, same time
#   <out>/<id>/glyndor.repo                    what a user is given (dnf and zypper read it)
#   <out>/glyndor-rpm-key.asc                  the public key, the same bytes as keyring/
# Requires: rpm, createrepo_c, gpg.
set -euo pipefail
# what is made here is not writable by the group or by others, whatever the caller's umask is
umask 022
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_DIR="$HERE/config"
BASE_URL="${REPO_BASE_URL:-https://rpm.glyndor.net}"
die() { echo "::error::build-repo: $*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
	case "$1" in
		--config) CONFIG_DIR="${2:?--config needs a directory}"; shift 2 ;;
		--) shift; break ;;
		-*) die "unknown option $1" ;;
		*) break ;;
	esac
done
[ "$#" -eq 4 ] || die "usage: build-repo.sh [--config <dir>] <public-key.asc> <epoch> <admitted-root> <out-dir>"
PUB="$1"; EPOCH="$2"; ROOT="$3"; OUT="$4"
[[ "$EPOCH" =~ ^[0-9]{9,11}$ ]] || die "the build time '$EPOCH' is not an epoch in seconds"
[ -d "$ROOT" ] || die "$ROOT is not a directory"
[ ! -e "$OUT" ] || die "$OUT exists; a tree is built into a folder of its own"

declare -A ARCHES=() ID_OF=()
declare -a IDS=()
while IFS=$'\t' read -r id suffix archs _client _form; do
	[[ "$id" =~ ^[a-z0-9]+(\.[0-9]+)?$ && "$suffix" =~ ^[a-z0-9]+$ ]] || die "distros.txt has a malformed id '$id'"
	IDS+=("$id"); ARCHES[$id]="${archs//,/ }"; ID_OF[$suffix]="$id"
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONFIG_DIR/distros.txt")
[ "${#IDS[@]}" -ge 1 ] || die "config/distros.txt lists no distribution"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
placed=0
shopt -s nullglob
for rpm in "$ROOT"/*/*.rpm; do
	if [ ! -f "$rpm" ] || [ -L "$rpm" ]; then die "$rpm is not a regular file"; fi
	header="$(rpm --dbpath "$WORK/db" -qp --nosignature --nodigest --qf '%{RELEASE}\n%{ARCH}\n' "$rpm")" \
		|| die "cannot read the header of $rpm"
	mapfile -t h <<< "$header"
	[[ "${h[0]}" =~ ^[0-9]+\.glyndor\.([a-z0-9]+)$ ]] || die "$rpm has the release '${h[0]}', which names no distribution"
	pkg_id="${BASH_REMATCH[1]}"
	[ "$pkg_id" = any ] || [ -n "${ID_OF[$pkg_id]:-}" ] || die "$rpm is for '$pkg_id', which this channel does not serve"
	[ "$pkg_id" = any ] || pkg_id="${ID_OF[$pkg_id]}"
	arch="${h[1]}"
	targets=()
	if [ "$pkg_id" = any ]; then targets=("${IDS[@]}"); else
		[ -n "${ARCHES[$pkg_id]:-}" ] || die "$rpm is for '$pkg_id', which this channel does not serve"
		targets=("$pkg_id")
	fi
	for id in "${targets[@]}"; do
		if [ "$arch" = noarch ]; then arch_list="${ARCHES[$id]}"; else arch_list="$arch"; fi
		for a in $arch_list; do
			case " ${ARCHES[$id]} " in *" $a "*) ;; *) die "$rpm is for '$a', which $id does not serve" ;; esac
			mkdir -p "$OUT/$id/$a/Packages"
			[ ! -e "$OUT/$id/$a/Packages/$(basename "$rpm")" ] || die "two products carry $(basename "$rpm")"
			install -m 644 "$rpm" "$OUT/$id/$a/Packages/"
			placed=$((placed + 1))
		done
	done
done
[ "$placed" -ge 1 ] || die "no package to publish; refusing to build an empty repository"
# the bootstrap package of each id, architecture independent, in both architectures
# (every id gets it, so every id is a repository of both architectures whatever the products publish)
for id in "${IDS[@]}"; do
	mkdir -p "$WORK/rel-$id"
	"$HERE/scripts/build/release-package.sh" --config "$CONFIG_DIR" "$id" "$PUB" "$WORK/rel-$id"
	for a in ${ARCHES[$id]}; do mkdir -p "$OUT/$id/$a/Packages"; install -m 644 "$WORK/rel-$id"/*.rpm "$OUT/$id/$a/Packages/"; done
done

real_gpg="$(command -v gpg)"
cat > "$WORK/gpg" <<WRAP
#!/bin/sh
exec "$real_gpg" --faked-system-time "$EPOCH!" "\$@"
WRAP
chmod +x "$WORK/gpg"
fpr="$(gpg --batch --show-keys --with-colons "$PUB" | awk -F: '$1 == "fpr" { print $10; exit }')"
for dir in "$OUT"/*/*/Packages; do
	"$HERE/scripts/build/sign-packages.sh" "$PUB" "$dir" > /dev/null
	repo="${dir%/Packages}"
	# The metadata records the modification time of each file; the build time of the package is the
	# one value that is the same in every run, so the same packages give the same metadata.
	for rpm in "$dir"/*.rpm; do
		touch -d "@$(rpm --dbpath "$WORK/db" -qp --nosignature --nodigest --qf '%{BUILDTIME}' "$rpm")" "$rpm"
	done
	createrepo_c --quiet --revision "$EPOCH" --set-timestamp-to-revision --compress-type gz --general-compress-type gz \
		--workers 1 "$repo" || die "createrepo_c failed for $repo"
	"$WORK/gpg" --batch --armor --detach-sign -u "$fpr" -o "$repo/repodata/repomd.xml.asc" "$repo/repodata/repomd.xml" \
		2> /dev/null || die "could not sign $repo/repodata/repomd.xml"
done
for id in "${IDS[@]}"; do
	[ -d "$OUT/$id" ] || continue
	"$HERE/scripts/build/repo-file.sh" --config "$CONFIG_DIR" "$id" "$BASE_URL" "$BASE_URL/glyndor-rpm-key.asc" > "$OUT/$id/glyndor.repo"
done
install -m 644 "$PUB" "$OUT/glyndor-rpm-key.asc"
echo "built $placed package placement(s) under $OUT at revision $EPOCH"
