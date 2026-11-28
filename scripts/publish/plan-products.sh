#!/usr/bin/env bash
#
# Decide which products this run publishes: print `<product> <tag>` for each product whose latest
# release carries rpm assets.
#
# The release of each product is chosen ONCE here, and every later job uses that tag. It is the one
# marked latest when its tag is a version, and otherwise the newest whose tag is one: a repository also
# releases other things under tags of another shape. Drafts and prereleases are never chosen. A product
# with no version release, or whose release carries no .rpm, is skipped with a notice while the
# repository serves nothing of it, and stops the run once it is served (a release that forgot its
# packages must not remove a product). Nothing printed means no product publishes rpm yet, which is not
# an error. A list or a release that cannot be read stops the run.
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
skip() { # <product> <what its releases lack>: stops the run when the product is served
	if grep -qx "$1" "$WORK/served-names"; then die "$1 is served and $2; refusing to drop it"; fi
	echo "::notice::Glyndor/$1 $3, and none is served: skipped" >&2
}
while IFS=$'\t' read -r product _kind _archs _wf; do
	list="$(gh release list --repo "Glyndor/$product" --exclude-drafts --exclude-pre-releases --limit 100 --json tagName,isLatest)" \
		|| die "cannot list the releases of Glyndor/$product"
	tag="$(jq -r '[.[] | select(.tagName | test("^v[0-9]+\\.[0-9]+\\.[0-9]+(\\+r[0-9]+)?$"))] | (map(select(.isLatest)) + .) | .[0].tagName // ""' <<< "$list")" \
		|| die "cannot read the release list of Glyndor/$product"
	if [ -z "$tag" ]; then
		skip "$product" "it has no version release" "has no version release"
		continue
	fi
	[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\+r[0-9]+)?$ ]] || die "the tag '$tag' chosen for Glyndor/$product is not a version tag"
	info="$(gh release view "$tag" --repo "Glyndor/$product" --json tagName,assets)" || die "cannot read the release $tag of Glyndor/$product"
	[ "$(jq -r '.tagName' <<< "$info")" = "$tag" ] || die "the release asked for as $tag of Glyndor/$product is not that tag"
	if [ "$(jq -r '[.assets[].name | select(endswith(".rpm"))] | length' <<< "$info")" -gt 0 ]; then
		printf '%s %s\n' "$product" "$tag"
	else
		skip "$product" "its release $tag carries no .rpm" "$tag carries no .rpm"
	fi
done <<< "$products"
