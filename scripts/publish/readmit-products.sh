#!/usr/bin/env bash
#
# In the job that signs, before any key is in the environment: admit every release again and record
# the hash of every file, outside the folder, for the step that signs to compare.
#
# Usage: readmit-products.sh <admitted-root>
#
# The artifact crossed a job boundary since admit-products.sh looked at it, so it is looked at again,
# here, where the archive key is not. The manifest is <root>.sha256 and is read by sign-tree.sh, which
# refuses a file that is not exactly what was admitted here.
# Requires: what admit-release.sh requires.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/scripts/publish/parse-plan.sh"
die() { echo "::error::readmit-products: $*" >&2; exit 1; }
[ "$#" -eq 1 ] || die "usage: readmit-products.sh <admitted-root>"
ROOT="${1%/}"
[ -d "$ROOT" ] || die "$ROOT is not a directory"
if [ -n "${GLYNDOR_RPM_GPG_PRIVATE_KEY:-}" ]; then die "the archive key is in the environment of the step that admits"; fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PLAN_CONFIG="$HERE/config/products.txt" parse_plan "${PRODUCTS:-}" "$WORK/plan" || exit 1
present="$(find "$ROOT" -mindepth 1 -maxdepth 1 -printf '%y %f\n' | sort | tr '\n' ',')"
planned="$(awk '{ print "d " $1 }' "$WORK/plan" | sort | tr '\n' ',')"
[ "$present" = "$planned" ] || die "the folders of $ROOT ($present) are not the products of the plan ($planned)"
while read -r product tag; do
	"$HERE/scripts/verify/admit-release.sh" "$product" "$tag" "$ROOT/$product" || die "$product $tag is not admitted"
done < "$WORK/plan"
(cd "$ROOT" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$ROOT.sha256"
echo "admitted again, $(wc -l < "$ROOT.sha256") file(s) recorded"
