#!/usr/bin/env bash
#
# Print the repository file of one distribution id, the one /<id>/glyndor.repo serves.
#
# Usage: repo-file.sh [--config <dir>] <id> <base-url> <gpgkey>
#
# `includepkgs` names exactly the packages this repository may offer for the id (the Podman set of its
# release suffix, the products, and the channel's own `glyndor-release`), so a repository that is
# wrong, or stolen, cannot pin or hide any other package of the host; there is no `priority`: Podman wins
# over the distribution's by epoch and revision, and the components packaged beside it keep receiving the
# distribution's updates. `skip_if_unavailable=1` keeps a missing or mismatched Glyndor repository from
# stopping every dnf transaction on the host; it installs nothing from a repository that is skipped, so
# trust is not weakened. `gpgcheck`, `repo_gpgcheck` and `pkg_gpgcheck` are all explicit (the last one
# is zypper's).
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_DIR="$HERE/config"
die() { echo "::error::repo-file: $*" >&2; exit 1; }
if [ "${1:-}" = --config ]; then CONFIG_DIR="${2:?--config needs a directory}"; shift 2; fi
[ "$#" -eq 3 ] || die "usage: repo-file.sh [--config <dir>] <id> <base-url> <gpgkey>"
ID="$1"; BASE="$2"; KEY="$3"
suffix=""; urlpart=""
while IFS=$'\t' read -r id sfx _archs _client form; do
	if [ "$id" = "$ID" ]; then suffix="$sfx"; urlpart="$form"; fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONFIG_DIR/distros.txt")
[ -n "$suffix" ] || die "$ID is not a distribution of config/distros.txt"
names="$( {
	awk -F'\t' -v s="$suffix" '$1 !~ /^#/ && $1 == s { print $2 }' "$CONFIG_DIR/podman-packages.txt"
	awk -F'\t' '$1 !~ /^#/ && ($2 == "static" || $2 == "service") { print $1 }' "$CONFIG_DIR/products.txt"
	echo glyndor-release
} | sort -u | paste -sd' ')"
cat <<REPO
[glyndor]
name=Glyndor
baseurl=$BASE/$urlpart/\$basearch/
type=rpm-md
enabled=1
autorefresh=1
gpgcheck=1
repo_gpgcheck=1
pkg_gpgcheck=1
skip_if_unavailable=1
includepkgs=$names
gpgkey=$KEY
REPO
