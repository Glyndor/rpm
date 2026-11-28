#!/usr/bin/env bash
#
# Render the installer of each product from the template.
#
# Usage: build-installers.sh <public-key.asc> <out-dir> <product>...
#
# One script per product at <out-dir>/<product>, from the one template, so a fix reaches every
# product the day it merges. The fingerprint written into each script is read from the key file
# (the single key it holds); a file with two keys or none stops the run. A product name is a
# product of config/products.txt, never an argument turned into a path. The result is checked:
# no placeholder is left, and it parses as a POSIX shell.
# Requires: gpg.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_URL="${REPO_BASE_URL:-https://rpm.glyndor.net}"
die() { echo "::error::build-installers: $*" >&2; exit 1; }
[ "$#" -ge 3 ] || die "usage: build-installers.sh <public-key.asc> <out-dir> <product>..."
PUB="$1"; OUT="$2"; shift 2
[ -f "$PUB" ] || die "$PUB is not a file"
mapfile -t fprs < <(gpg --batch --show-keys --with-colons "$PUB" 2> /dev/null | awk -F: '$1 == "fpr" { print $10 }')
if [ "${#fprs[@]}" -ne 1 ] || [[ ! "${fprs[0]}" =~ ^[0-9A-F]{40}$ ]]; then die "$PUB must hold exactly one key"; fi
mkdir -p "$OUT"
for product in "$@"; do
	[[ "$product" =~ ^[a-z0-9-]+$ ]] || die "'$product' is not a product name"
	grep -qE "^${product}	" "$HERE/config/products.txt" 2> /dev/null || die "$product is not a product of config/products.txt"
	sed -e "s|@PRODUCT@|$product|g" -e "s|@BASE_URL@|$BASE_URL|g" -e "s|@FPR@|${fprs[0]}|g" \
		"$HERE/scripts/installer/install-template.sh" > "$OUT/$product"
	chmod 755 "$OUT/$product"
	if grep -q '@[A-Z_]*@' "$OUT/$product"; then die "a placeholder is left in the installer of $product"; fi
	sh -n "$OUT/$product" || die "the installer of $product does not parse"
done
echo "rendered ${#} installer(s) into $OUT"
