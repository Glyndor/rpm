#!/usr/bin/env bash
#
# From the downloaded releases to a verified tree, in one place that every job which signs calls.
#
# Usage: assemble-tree.sh [--key <public-key.asc>] [--served-key <public-key.asc>] [--keyring <dir>] <admitted-root> <plan-file> <out-dir> <epoch>
#
# <plan-file> has one `<product> <tag>` per line: what the plan job resolved. <admitted-root>/<product>/
# holds the files downloaded for that tag. The steps, each of which stops the run:
#
#   1. the folders of <admitted-root> are exactly the products of the plan (the plan, not the folder,
#      says what is expected);
#   2. every release is admitted again (admit-release.sh): the signature, the set and the header are
#      checked here, in the job that is about to sign, with no key in the environment yet;
#   3. build-repo.sh builds and signs the tree (GNUPGHOME, with the archive key, is made by the caller);
#   4. the installer of each product is rendered into the tree;
#   5. verify-tree.sh reads the tree the way a client would;
#   6. check-release-order.sh compares it with what is served at ARCHIVE_URL.
# The options are for the tests and for the rehearsal (a throwaway key signs the tree, the committed
# key still checks what is served); the publishing job never passes them, and a test says so.
# Requires: what each of those scripts requires.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUB="$HERE/keyring/glyndor-rpm-key.asc"
ARCHIVE_URL="${ARCHIVE_URL:-https://rpm.glyndor.net}"
die() { echo "::error::assemble-tree: $*" >&2; exit 1; }
ADMIT_ARGS=()
SERVED_KEY=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--key) PUB="${2:?--key needs a file}"; shift 2 ;;
		--served-key) SERVED_KEY="${2:?--served-key needs a file}"; shift 2 ;;
		--keyring) ADMIT_ARGS=(--keyring "${2:?--keyring needs a folder}"); shift 2 ;;
		--) shift; break ;;
		-*) die "unknown option $1" ;;
		*) break ;;
	esac
done
[ "$#" -eq 4 ] || die "usage: assemble-tree.sh [--key <public-key.asc>] [--served-key <public-key.asc>] [--keyring <dir>] <admitted-root> <plan-file> <out-dir> <epoch>"
ROOT="$1"; PLAN="$2"; OUT="$3"; EPOCH="$4"
if [ ! -d "$ROOT" ] || [ ! -f "$PLAN" ]; then die "$ROOT is not a directory or $PLAN is not a file"; fi
[ ! -e "$OUT" ] || die "$OUT exists"
# The revisions are judged against the start of the run, not against the clock when this step happens to
# run: an approval gate between signing and publishing can take hours.
export ORDER_NOW="${ORDER_NOW:-$EPOCH}"

declare -a PRODUCTS=()
declare -A TAG_OF=()
while read -r product tag extra; do
	[ -n "$product" ] || continue
	[ -z "$extra" ] || die "the plan line for $product has more than a product and a tag"
	[[ "$product" =~ ^[a-z0-9-]+$ && "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\+r[0-9]+)?$ ]] || die "the plan line '$product $tag' is malformed"
	[ -z "${TAG_OF[$product]:-}" ] || die "$product is twice in the plan"
	PRODUCTS+=("$product"); TAG_OF[$product]="$tag"
done < "$PLAN"
[ "${#PRODUCTS[@]}" -ge 1 ] || die "the plan has no product"

present="$(find "$ROOT" -mindepth 1 -maxdepth 1 -printf '%y %f\n' | sort | tr '\n' ',')"
planned="$(for p in "${PRODUCTS[@]}"; do printf 'd %s\n' "$p"; done | sort | tr '\n' ',')"
[ "$present" = "$planned" ] || die "the folders of $ROOT ($present) are not the products of the plan ($planned)"

# What is admitted is what is signed: the files are copied once into a folder of this run, and that copy is the one that
# is admitted and the one the tree is built from, so nothing that touches the downloaded folder afterwards (a later step
# of the job, a process on the runner) can put other bytes under a signature of the channel.
SNAP="$(mktemp -d)"
trap 'rm -rf "$SNAP"' EXIT
cp -a "$ROOT/." "$SNAP/" || die "cannot copy $ROOT"
for p in "${PRODUCTS[@]}"; do
	"$HERE/scripts/verify/admit-release.sh" "${ADMIT_ARGS[@]}" "$p" "${TAG_OF[$p]}" "$SNAP/$p" || die "$p ${TAG_OF[$p]} is not admitted"
done
"$HERE/scripts/build/build-repo.sh" "$PUB" "$EPOCH" "$SNAP" "$OUT"
"$HERE/scripts/build/build-installers.sh" "$PUB" "$OUT/install" "${PRODUCTS[@]}"
"$HERE/scripts/verify/verify-tree.sh" "$OUT" "$PUB"
"$HERE/scripts/verify/check-release-order.sh" "$ARCHIVE_URL" "$OUT" "${SERVED_KEY:-$PUB}" "$HERE/config/retired-packages.txt"
echo "assembled the tree of ${#PRODUCTS[@]} product(s) at revision $EPOCH"
