#!/usr/bin/env bash
#
# Download the .rpm assets of one product release, and nothing else.
#
# Usage: fetch-release.sh [--config <dir>] <product> <tag> <dir>
#
# The release is a list somebody else controls, so the list is read, bounded and filtered
# before any byte is transferred: the tag must be the one asked for, a name outside the closed
# alphabet (a path separator or a glob character would turn `--pattern` into a wildcard) stops
# the run, and a size over the cap stops it before the download, with the same caps
# admit-release.sh applies to the bytes it receives. Each file is then downloaded by its exact
# name, and the provenance attestation of every downloaded file is checked against the release
# workflow of the product. The signature of the release key is admit-release.sh's job.
#
# Exit status: 0 downloaded, 3 the release carries no .rpm asset (the caller decides whether
# that is a product that does not publish rpm yet or one that stopped), anything else a refusal.
# Requires: gh (authenticated), jq.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_DIR="$HERE/config"
MAX_RPM_BYTES="${ADMIT_MAX_RPM_BYTES:-$((300 * 1024 * 1024))}"
MAX_SIG_BYTES=4096
# What a release may weigh before anything is downloaded, since nothing of it is authenticated yet: the number of assets is
# bounded by the set the contract names (three files, at most, for each package) and the bytes of all of them together by
# a ceiling of their own, so a hundred files that are each under the cap cannot add up to a disk.
MAX_TOTAL_BYTES="${ADMIT_MAX_TOTAL_BYTES:-$((4 * 1024 * 1024 * 1024))}"
die() { echo "::error::fetch-release: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
	case "$1" in
		--config) CONFIG_DIR="${2:?--config needs a directory}"; shift 2 ;;
		--) shift; break ;;
		-*) die "unknown option $1" ;;
		*) break ;;
	esac
done
[ "$#" -eq 3 ] || die "usage: fetch-release.sh [--config <dir>] <product> <tag> <dir>"
PRODUCT="$1"; TAG="$2"; DIR="$3"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\+r[0-9]+)?$ ]] || die "tag '$TAG' is not vX.Y.Z or vX.Y.Z+rN"
workflow=""; source_ref=""
while IFS=$'\t' read -r name _kind _archs wf sref; do
	if [ "$name" = "$PRODUCT" ]; then workflow="$wf"; source_ref="$sref"; fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONFIG_DIR/products.txt")
[ -n "$workflow" ] || die "$PRODUCT is not a product of this channel"
[[ "$workflow" =~ ^[a-z0-9-]+\.yml$ ]] || die "the release workflow '$workflow' of $PRODUCT is not a file name"
[[ "$source_ref" =~ ^(tag|refs/(heads|tags)/[A-Za-z0-9._/-]+)$ ]] || die "the source ref '$source_ref' of $PRODUCT is malformed"
if [ ! -d "$DIR" ] || [ -L "$DIR" ]; then die "$DIR is not a directory"; fi
[ -z "$(ls -A "$DIR")" ] || die "$DIR is not empty; a release is fetched into a directory of its own"
REPO="Glyndor/$PRODUCT"

info="$(gh release view "$TAG" --repo "$REPO" --json tagName,assets)" || die "cannot read the release $TAG of $REPO"
[ "$(jq -r '.tagName' <<< "$info")" = "$TAG" ] || die "the release asked for as $TAG is not that tag"
mapfile -t listing < <(jq -r '.assets[] | "\(.size)\t\(.name)"' <<< "$info")

# The names the contract allows: the files of the set of this tag, as admit-release.sh derives them, in one expression.
if [[ "$TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(\+r([0-9]+))?$ ]]; then V="${BASH_REMATCH[1]}"; R="${BASH_REMATCH[3]:-1}"; fi
kind="$(grep -vE '^[[:space:]]*(#|$)' "$CONFIG_DIR/products.txt" | awk -F'\t' -v n="$PRODUCT" '$1 == n { print $2 }')"
esc() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }
if [ "$kind" = podman ]; then
	pnames="$(grep -vE '^[[:space:]]*(#|$)' "$CONFIG_DIR/podman-packages.txt" | cut -f2 | sort -u | paste -sd'|')"
	pids="$(grep -vE '^[[:space:]]*(#|$)' "$CONFIG_DIR/podman-packages.txt" | cut -f1 | sort -u | paste -sd'|')"
	if [ -z "$pnames" ] || [ -z "$pids" ]; then die "config/podman-packages.txt names no package"; fi
	expected_re="^($pnames)-[0-9][0-9A-Za-z.+~]*-$(esc "$R")\\.glyndor\\.($pids)\\.(x86_64|aarch64|noarch)\\.rpm(\\.sig|\\.mldsa65\\.sig)?$"
	max_assets=$(( $(grep -vcE '^[[:space:]]*(#|$)' "$CONFIG_DIR/podman-packages.txt") * 2 * 3 ))
else
	expected_re="^$(esc "$PRODUCT")-$(esc "$V")-1\\.glyndor\\.any\\.(x86_64|aarch64|noarch)\\.rpm(\\.sig|\\.mldsa65\\.sig)?$"
	max_assets=6
fi
count=0; declared=0
names=()
for row in "${listing[@]}"; do
	size="${row%%$'\t'*}"; name="${row#*$'\t'}"
	case "$name" in
		*.rpm | *.rpm.sig | *.rpm.mldsa65.sig) ;;
		*) continue ;;
	esac
	[[ "$name" =~ ^[A-Za-z0-9._+~-]+$ && "$name" != *..* ]] \
		|| die "the release carries an asset whose name is outside the closed alphabet: '$name'"
	[[ "$size" =~ ^[0-9]+$ ]] || die "the asset $name has a non-numeric size '$size'"
	case "$name" in
		*.sig) cap="$MAX_SIG_BYTES" ;;
		*) cap="$MAX_RPM_BYTES" ;;
	esac
	[ "$size" -le "$cap" ] || die "the asset $name is $size bytes, over the $cap-byte cap"
	[[ "$name" =~ $expected_re ]] || die "the release carries $name, which is not a file the contract names for $PRODUCT $TAG; nothing is downloaded"
	count=$((count + 1)); declared=$((declared + size))
	[ "$count" -le "$max_assets" ] || die "the release carries more than $max_assets rpm assets, the most its set can have; nothing is downloaded"
	[ "$declared" -le "$MAX_TOTAL_BYTES" ] || die "the assets of the release declare more than $MAX_TOTAL_BYTES bytes together; nothing is downloaded"
	names+=("$name")
done
if [ "${#names[@]}" -eq 0 ]; then
	echo "$REPO $TAG carries no .rpm asset"
	exit 3
fi

got=0
for name in "${names[@]}"; do
	before="$(find "$DIR" -mindepth 1 -maxdepth 1 | wc -l)"
	gh release download "$TAG" --repo "$REPO" --pattern "$name" --dir "$DIR" \
		|| die "could not download $name of $REPO $TAG"
	after="$(find "$DIR" -mindepth 1 -maxdepth 1 | wc -l)"
	if [ "$((after - before))" -ne 1 ] || [ ! -f "$DIR/$name" ] || [ -L "$DIR/$name" ]; then
		die "downloading $name did not give exactly that one regular file"
	fi
	size="$(stat -c%s -- "$DIR/$name")"
	case "$name" in *.sig) cap="$MAX_SIG_BYTES" ;; *) cap="$MAX_RPM_BYTES" ;; esac
	[ "$size" -le "$cap" ] || die "the downloaded $name is $size bytes, over the $cap-byte cap"
	# what arrived, not what the listing said: the download stops here when the bytes together are over the ceiling
	got=$((got + size))
	[ "$got" -le "$MAX_TOTAL_BYTES" ] || die "the files downloaded so far weigh $got bytes, over the $MAX_TOTAL_BYTES-byte ceiling; the rest is not downloaded"
done

# The attestation is tied to this release, not only to the product: the workflow that made it, the ref
# it ran for and, when the product releases from a tag, the commit that tag points at, so a valid
# attestation of another release of the same product does not pass for this one.
attest=(--repo "$REPO" --signer-workflow "$REPO/.github/workflows/$workflow" --deny-self-hosted-runners)
if [ "$source_ref" = tag ]; then
	commit="$(gh api "repos/$REPO/commits/$TAG" --jq .sha)" || die "cannot resolve the commit of $TAG in $REPO"
	[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "the commit of $TAG in $REPO is not a full SHA"
	attest+=(--source-ref "refs/tags/$TAG" --source-digest "$commit")
else
	attest+=(--source-ref "$source_ref")
fi
for name in "${names[@]}"; do
	gh attestation verify "$DIR/$name" "${attest[@]}" \
		> /dev/null 2>&1 || die "the provenance attestation of $name does not verify against $REPO's $workflow for $TAG"
done
echo "fetched ${#names[@]} asset(s) of $REPO $TAG, attestations verified"
