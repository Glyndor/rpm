#!/usr/bin/env bash
#
# Check, in the job that publishes, the files of a tree that no signature covers: the installers that people run as
# root, and the index page.
#
# Usage: check-static-files.sh <tree> <public-key.asc>
#
# They are rendered again here, from the commit this job checked out, and compared byte by byte with the ones the
# artifact holds: the artifact of an earlier job is data, not something to trust. The tree must hold exactly one
# installer for each product it names under install/, and each must be the one the template renders for it. The index
# page is either absent or the same bytes as site/index.html of this repository.
# Requires: gpg, cmp.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { echo "::error::check-static-files: $*" >&2; exit 1; }
if [ "$#" -ne 2 ] || [ ! -d "$1" ] || [ ! -f "$2" ]; then die "usage: check-static-files.sh <tree> <public-key.asc>"; fi
TREE="$1"; PUB="$2"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mapfile -t names < <(find "$TREE/install" -mindepth 1 -maxdepth 1 -printf '%f\n' 2> /dev/null | sort)
[ "${#names[@]}" -ge 1 ] || die "$TREE/install holds no installer"
for n in "${names[@]}"; do
	if [ ! -f "$TREE/install/$n" ] || [ -L "$TREE/install/$n" ]; then die "install/$n is not a regular file"; fi
	[[ "$n" =~ ^[a-z0-9-]+$ ]] || die "install/$n is not the name of a product"
done
if find "$TREE/install" -mindepth 2 -print -quit | grep -q .; then die "install/ holds a folder"; fi
"$HERE/scripts/build/build-installers.sh" "$PUB" "$WORK/install" "${names[@]}" > /dev/null
for n in "${names[@]}"; do
	cmp -s "$WORK/install/$n" "$TREE/install/$n" || die "install/$n is not what scripts/installer/install-template.sh renders for $n"
	[ "$(stat -c %a "$TREE/install/$n")" = 755 ] || die "install/$n is not mode 755"
done

if [ -e "$TREE/index.html" ]; then
	[ -f "$HERE/site/index.html" ] || die "the tree has an index.html and this repository has no site/index.html"
	cmp -s "$HERE/site/index.html" "$TREE/index.html" || die "index.html is not site/index.html of this commit"
fi
echo "the ${#names[@]} installer(s) and the index page are the ones this commit renders"
