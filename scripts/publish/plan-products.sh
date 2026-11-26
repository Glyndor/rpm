#!/usr/bin/env bash
#
# Decide which products this run publishes: print `<product> <tag>` for each product whose latest
# release carries rpm assets.
#
# The latest release of each product is resolved ONCE here, and every later job uses that tag. A
# product whose latest release carries no .rpm is skipped with a notice while the repository serves
# nothing of it, and stops the run once it is served (a release that forgot its packages must not
# remove a product). Nothing printed means no product publishes rpm yet, which is not an error.
# GH_TOKEN, and ARCHIVE_URL for the served check. Requires: gh, jq, curl.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARCHIVE_URL="${ARCHIVE_URL:-https://rpm.glyndor.net}"
die() { echo "::error::plan-products: $*" >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/served"
served=1
rc=0
"$HERE/scripts/verify/served-state.sh" "$ARCHIVE_URL" fc45 x86_64 "$WORK/served" "$HERE/keyring/glyndor-rpm-key.asc" > /dev/null 2>&1 || rc=$?
if [ "$rc" -eq 10 ]; then served=0; elif [ "$rc" -ne 0 ]; then die "the served repository cannot be read, so which products it serves is not known"; fi
if [ "$served" -eq 1 ]; then
	python3 -I "$HERE/scripts/verify/repo-state.py" packages "$WORK/served/repomd.xml" "$WORK/served/primary.xml.gz" | cut -f1 | sort -u > "$WORK/served-names"
else
	: > "$WORK/served-names"
fi
products="$(grep -vE '^[[:space:]]*(#|$)' "$HERE/config/products.txt")" || die "config/products.txt cannot be read or lists no product"
while IFS=$'\t' read -r product _kind _archs _wf; do
	info="$(gh release view --repo "Glyndor/$product" --json tagName,assets)" || die "cannot read the latest release of Glyndor/$product"
	tag="$(jq -r '.tagName' <<< "$info")"
	[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\+r[0-9]+)?$ ]] || die "the latest release of Glyndor/$product is '$tag', which is not a version tag"
	if [ "$(jq -r '[.assets[].name | select(endswith(".rpm"))] | length' <<< "$info")" -gt 0 ]; then
		printf '%s %s\n' "$product" "$tag"
	elif grep -qx "$product" "$WORK/served-names"; then
		die "$product is served and its latest release $tag carries no .rpm; refusing to drop it"
	else
		echo "::notice::Glyndor/$product $tag carries no .rpm, and none is served: skipped" >&2
	fi
done <<< "$products"
