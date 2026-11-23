#!/usr/bin/env bash
#
# Download and admit the release of each product of the plan into <out>/<product>/.
#
# Usage: admit-products.sh <out>
#
# PRODUCTS is the plan as the plan job printed it. A release that is refused stops the run: the
# repository is rebuilt from every product at once or not at all.
# Requires: what fetch-release.sh and admit-release.sh require.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/scripts/publish/parse-plan.sh"
die() { echo "::error::admit-products: $*" >&2; exit 1; }
[ "$#" -eq 1 ] || die "usage: admit-products.sh <out>"
OUT="$1"
[ ! -e "$OUT" ] || die "$OUT exists"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PLAN_CONFIG="$HERE/config/products.txt" parse_plan "${PRODUCTS:-}" "$WORK/plan" || exit 1
mkdir -p "$OUT"
while read -r product tag; do
	mkdir "$OUT/$product"
	echo "::group::$product $tag"
	"$HERE/scripts/verify/fetch-release.sh" "$product" "$tag" "$OUT/$product" || die "$product $tag cannot be fetched"
	"$HERE/scripts/verify/admit-release.sh" "$product" "$tag" "$OUT/$product" || die "$product $tag is not admitted"
	echo "::endgroup::"
done < "$WORK/plan"
