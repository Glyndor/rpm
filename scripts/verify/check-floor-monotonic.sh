#!/usr/bin/env bash
#
# Refuse a floor that went down: config/floor.txt may only rise.
#
# Usage: check-floor-monotonic.sh <floor of the base> <floor of the change>
#
# The floor is the lowest release of a product the channel will admit, and it is the record that keeps an old release
# from being published again. A change that lowers a number, or drops the line of a product, would switch that off
# without anything in the code noticing, so the pull request is judged against the file of its base: every product
# of the base is still there, and with a version that rpm does not order below the one it had. A new product may
# appear. Requires: rpm.
set -euo pipefail
export LC_ALL=C
die() { echo "::error::check-floor-monotonic: $*" >&2; exit 1; }
# the same reading of a tag as the admission, from the same file (beside this script, so the copy of the base brings its own)
# shellcheck disable=SC1091 # the path is resolved at run time
. "$(dirname "${BASH_SOURCE[0]}")/lib-evr.sh"
[ "$#" -eq 2 ] || die "usage: check-floor-monotonic.sh <floor of the base> <floor of the change>"
for f in "$1" "$2"; do
	if [ ! -f "$f" ] || [ -L "$f" ] || [ ! -r "$f" ]; then die "$f is not a readable regular file"; fi
done
declare -A OLD=() NEW=()
read_floor() { # <file> <array name>
	local -n into="$2"
	local name tag extra
	while read -r name tag extra || [ -n "$name" ]; do
		if [ -z "$name" ] || [ "${name:0:1}" = "#" ]; then continue; fi
		if [ -n "$extra" ] || [ -z "$tag" ] || [[ ! "$name" =~ ^[a-z0-9-]+$ ]] || [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\+r[0-9]+)?$ ]]; then die "$1 has a malformed line for '$name'"; fi
		[ -z "${into[$name]:-}" ] || die "$1 has two lines for '$name'"
		kind=static; [ "$name" != podman ] || kind=podman
		into["$name"]="$(evr_of "$tag" "$kind")" || die "$1 has a tag that is not a version of $name: '$tag'"
	done < "$1"
}
read_floor "$1" OLD
read_floor "$2" NEW
for name in "${!OLD[@]}"; do
	[ -n "${NEW[$name]:-}" ] || die "the floor of $name (v${OLD[$name]}) is gone"
	r="$(vercmp "${OLD[$name]}" "${NEW[$name]}")" || die "rpm cannot compare the floors of $name; refusing, since a comparison that cannot be made is not a pass"
	case "$r" in
		-1 | 0) ;;
		1) die "the floor of $name went down, from ${OLD[$name]} to ${NEW[$name]}" ;;
		*) die "rpm answered '$r' to the comparison of the floors of $name" ;;
	esac
done
echo "the floor only rose or stayed"
