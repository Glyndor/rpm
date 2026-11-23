#!/usr/bin/env bash
#
# Purge the Cloudflare cache of the files that change in place, by URL.
#
# Usage: purge-cache.sh <base-url> <tree> [<budget-seconds>]
#
# CF_TOKEN and CF_ZONE come from the environment. The list is derived from the tree that was just
# published: every repomd.xml and its signature, every repository file, the public key, the
# installers and the index page. Files whose name carries their checksum are never purged: they never
# change. The zone is shared with the rest of glyndor.net, so this purges by URL and never everything,
# at most 30 URLs a request (Cloudflare's limit), with a deadline for the whole purge. The token goes
# to curl through a config file on stdin, never argv. Every batch must answer success:true.
# Requires: curl, jq.
set -euo pipefail
export LC_ALL=C

die() { echo "::error::purge-cache: $*" >&2; exit 1; }
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then die "usage: purge-cache.sh <base-url> <tree> [<budget-seconds>]"; fi
BASE="${1%/}"; TREE="$2"; BUDGET="${3:-120}"
[[ "$BASE" =~ ^https://[a-z0-9.-]+$ ]] || die "the base URL '$BASE' is not an https origin"
[[ "$BUDGET" =~ ^[0-9]+$ ]] || die "the budget '$BUDGET' is not a number of seconds"
[ -d "$TREE" ] || die "$TREE is not a directory"
if [ -z "${CF_TOKEN:-}" ] || [ -z "${CF_ZONE:-}" ]; then die "CF_TOKEN and CF_ZONE must be set"; fi
[[ "$CF_ZONE" =~ ^[0-9a-f]{32}$ ]] || die "CF_ZONE is not a zone id"
API="${CF_API:-https://api.cloudflare.com/client/v4}"

# One group per id (its repository file and the two files of each architecture's index), so that the signature
# and the index it signs are purged in the same request: a batch never splits a group.
mapfile -t GROUPS_ < <(cd "$TREE" && find . -type f -printf '%P\n' | sort | while IFS= read -r f; do
	case "$f" in
		*/Packages/*) ;;
		*/repodata/repomd.xml | */repodata/repomd.xml.asc | */glyndor.repo) printf '%s\t%s/%s\n' "${f%%/*}" "$BASE" "$f" ;;
		glyndor-rpm-key.asc | index.html) printf '%s\t%s/%s\n' "$f" "$BASE" "$f" ;;
		install/*) printf 'install\t%s/%s\n' "$BASE" "$f" ;;
	esac
done | awk -F'\t' '{ g[$1] = g[$1] (g[$1] == "" ? "" : " ") $2 } END { for (k in g) print g[k] }' | sort)
[ "${#GROUPS_[@]}" -ge 1 ] || die "nothing to purge in $TREE"
GROUPS_+=("$BASE/")

deadline=$((SECONDS + BUDGET))
n=0
batch=()
flush() {
	[ "${#batch[@]}" -gt 0 ] || return 0
	[ "$SECONDS" -lt "$deadline" ] || die "the budget of ${BUDGET}s ran out after $n URL(s)"
	local body left resp
	body="$(printf '%s\n' "${batch[@]}" | jq -R . | jq -sc '{files: .}')"
	left=$((deadline - SECONDS))
	resp="$(
		printf 'header = "Authorization: Bearer %s"\n' "$CF_TOKEN" | \
			curl --max-time "$left" --connect-timeout 10 --silent --show-error --retry 2 --retry-delay 3 --config - \
				-X POST -H 'Content-Type: application/json' --data "$body" "$API/zones/$CF_ZONE/purge_cache"
	)" || die "the purge request failed after $n URL(s)"
	[ "$(jq -r '.success' <<< "$resp" 2>/dev/null)" = true ] || die "Cloudflare did not answer success after $n URL(s)"
	n=$((n + ${#batch[@]}))
	batch=()
}
for group in "${GROUPS_[@]}"; do
	read -r -a urls <<< "$group"
	if [ "${#urls[@]}" -gt 30 ]; then
		# an `install` or a very large group has no pair to keep together: it is cut at 30
		for ((i = 0; i < ${#urls[@]}; i += 30)); do batch=("${urls[@]:i:30}"); flush; done
		continue
	fi
	if [ $((${#batch[@]} + ${#urls[@]})) -gt 30 ]; then flush; fi
	batch+=("${urls[@]}")
done
flush
echo "purged $n URL(s)"
