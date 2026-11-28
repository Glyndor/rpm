#!/usr/bin/env bash
# Sourced by the scripts that read the plan. `parse_plan <string> <file>` turns what the plan job
# printed, "<product> <tag>,<product> <tag>", into one `<product> <tag>` per line, after checking each
# entry against the closed forms: a product name of config/products.txt and a release tag.

parse_plan() { # <string> <file>
	local entry product tag known out=""
	: > "$2"
	case "$1" in
		'' | , | ,* | *, | *,,* | *$'\n'*) echo "::error::the plan is empty, or has an empty or a multi line entry" >&2; return 1 ;;
	esac
	IFS=',' read -r -a entries <<< "$1"
	for entry in "${entries[@]}"; do
		[[ "$entry" =~ ^([a-z0-9-]+)\ (v[0-9]+\.[0-9]+\.[0-9]+(\+r[0-9]+)?)$ ]] || { echo "::error::malformed plan entry '$entry'" >&2; return 1; }
		product="${BASH_REMATCH[1]}"; tag="${BASH_REMATCH[2]}"
		known="$(awk -F'\t' -v p="$product" '$1 == p { print $1 }' "${PLAN_CONFIG:-config/products.txt}")"
		[ "$known" = "$product" ] || { echo "::error::'$product' is not a product of the channel" >&2; return 1; }
		out="$out$product $tag"$'\n'
	done
	printf '%s' "$out" > "$2"
}
