#!/usr/bin/env bash
#
# Refuse a tree that would take the repository backwards.
#
# Usage: check-release-order.sh [--config <dir>] <served-base-url> <tree> <public-key.asc> [<retired-file>]
#
# For every distribution and architecture the channel serves, the state served at <served-base-url>
# (served-state.sh) is compared with the one in <tree> (repo-state.py order): a higher revision, no
# package dropped, none older, and a version that was published is the same file. A repository the
# server does not have yet is a first publication only when config/published.txt says it is new; one that the server
# has and the tree does not is a repository about to disappear and is refused.
# Requires: what served-state.sh requires.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_DIR="$HERE/config"
die() { echo "::error::check-release-order: $*" >&2; exit 1; }
if [ "${1:-}" = --config ]; then CONFIG_DIR="${2:?--config needs a directory}"; shift 2; fi
if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then die "usage: check-release-order.sh [--config <dir>] <served-base-url> <tree> <public-key.asc> [<retired-file>]"; fi
BASE="$1"; TREE="$2"; PUB="$3"; RETIRED="${4:-}"
[ -d "$TREE" ] || die "$TREE is not a directory"
# The time the revisions are judged against; the tests give another one.
NOW="${ORDER_NOW:-$(date +%s)}"
[[ "$NOW" =~ ^[0-9]{9,11}$ ]] || die "ORDER_NOW is not an epoch"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The repositories that were published are written down (config/published.txt, `<id> <arch> new|published`): the first
# publication is explicit and the move from new to published is a change that is reviewed, not a state this script
# infers from an answer an attacker can give.
PUBLISHED="$CONFIG_DIR/published.txt"
if [ ! -f "$PUBLISHED" ] || [ -L "$PUBLISHED" ] || [ ! -r "$PUBLISHED" ]; then die "$PUBLISHED is not a readable regular file"; fi
published_state() { # <id> <arch>: new, published, or nothing
	grep -vE '^[[:space:]]*(#|$)' "$PUBLISHED" | awk -v i="$1" -v a="$2" '$1 == i && $2 == a { print $3 }'
}
published_field() { # <id> <arch> <column>: the revision (4) or the sha256 of repomd.xml (5) written for a published repository
	grep -vE '^[[:space:]]*(#|$)' "$PUBLISHED" | awk -v i="$1" -v a="$2" -v c="$3" '$1 == i && $2 == a { print $c }'
}
# A published repository records the last revision known to have been served and the sha256 of its repomd.xml: what is
# served may not be older than that (metadata signed long ago can be put back, and the format has no expiry), and at the
# same revision it is that very file. A line that says `published` without them is refused: no data, no judgement.
declare -A SEEN=()
while read -r pid parch pstate prev psha pextra; do
	[ -n "$pid" ] || continue
	[ "${pid:0:1}" != "#" ] || continue
	[ -z "$pextra" ] || die "$PUBLISHED has a malformed line for '$pid $parch'"
	[ -z "${SEEN[$pid/$parch]:-}" ] || die "$PUBLISHED has two lines for '$pid $parch'"
	SEEN[$pid/$parch]=1
	case "$pstate" in
		new) [ -z "$prev$psha" ] || die "$PUBLISHED gives a revision to '$pid $parch', which is new" ;;
		published) [[ "$prev" =~ ^[0-9]{9,11}$ && "$psha" =~ ^[0-9a-f]{64}$ ]] || die "$PUBLISHED says '$pid $parch' is published and gives no readable revision and sha256 of its repomd.xml" ;;
		*) die "$PUBLISHED has a malformed line for '$pid $parch'" ;;
	esac
done < "$PUBLISHED"
bad=0; compared=0
while IFS=$'\t' read -r id _suffix archs _client _form; do
	for arch in ${archs//,/ }; do
		mkdir -p "$WORK/$id-$arch"
		# the state of the repository is read once, before anything branches on it, and it is `new` or `published` or the
		# run ends: an unlisted repository is not judged by a path that happens not to look at its state
		state="$(published_state "$id" "$arch")"
		case "$state" in new | published) ;; *) die "$id/$arch is not declared in $PUBLISHED as new or published" ;; esac
		rc=0
		"$HERE/scripts/verify/served-state.sh" "$BASE" "$id" "$arch" "$WORK/$id-$arch" "$PUB" > "$WORK/log" 2>&1 || rc=$?
		cat "$WORK/log" >&2
		have=0
		if [ -f "$TREE/$id/$arch/repodata/repomd.xml" ]; then
			have=1
			# A revision that is not about now would either be taken for the newest forever or be old
			# news; one far in the future served today would stop every later publication.
			rev="$(python3 -I "$HERE/scripts/verify/repo-state.py" revision "$TREE/$id/$arch/repodata/repomd.xml")" \
				|| die "unreadable repomd.xml in the tree for $id/$arch"
			[[ "$rev" =~ ^[0-9]{9,11}$ ]] || die "$id/$arch: the revision '$rev' of the new tree is not a number"
			if [ "$rev" -ge $((NOW - 3600)) ] && [ "$rev" -le $((NOW + 600)) ]; then :; else
				die "$id/$arch: the revision $rev of the new tree is not within an hour before and ten minutes after now ($NOW)"
			fi
		fi
		if [ "$rc" -eq 10 ]; then
			# nothing served: acceptable only for a repository declared new; for one that was published it is the
			# repository vanishing (or an answer forced to 404), and the order check does not go quiet
			case "$state" in
				new) echo "$id/$arch: declared as not published yet; a first publication" >&2; continue ;;
				published) die "$id/$arch was published and now answers nothing: refusing, since that is the repository disappearing" ;;
			esac
		fi
		[ "$rc" -eq 0 ] || die "the served state of $id/$arch cannot be read or verified"
		served_rev="$(python3 -I "$HERE/scripts/verify/repo-state.py" revision "$WORK/$id-$arch/repomd.xml")"
		[[ "$served_rev" =~ ^[0-9]{9,11}$ ]] || die "$id/$arch: the served revision '$served_rev' is not a number"
		[ "$served_rev" -le $((NOW + 600)) ] || die "$id/$arch: the served revision $served_rev is in the future (now $NOW)"
		if [ "$state" = published ]; then
			rec_rev="$(published_field "$id" "$arch" 4)"; rec_sha="$(published_field "$id" "$arch" 5)"
			[ "$served_rev" -ge "$rec_rev" ] || die "$id/$arch: what is served has the revision $served_rev, older than the $rec_rev recorded in $PUBLISHED: an old signed repository was put back"
			if [ "$served_rev" -eq "$rec_rev" ] && [ "$(sha256sum "$WORK/$id-$arch/repomd.xml" | cut -d' ' -f1)" != "$rec_sha" ]; then
				die "$id/$arch: what is served has the recorded revision $rec_rev and not the recorded repomd.xml"
			fi
		fi
		if [ "$have" -eq 0 ]; then echo "::error::$id/$arch is served and the new tree has none" >&2; bad=1; continue; fi
		dir="$TREE/$id/$arch/repodata"
		prim="$(python3 -I "$HERE/scripts/verify/repo-state.py" primary "$dir/repomd.xml")" || die "unreadable repomd.xml in the tree for $id/$arch"
		args=("$WORK/$id-$arch/repomd.xml" "$WORK/$id-$arch/primary.xml.gz" "$dir/repomd.xml" "$TREE/$id/$arch/$prim")
		[ -z "$RETIRED" ] || args+=("$RETIRED")
		python3 -I "$HERE/scripts/verify/repo-state.py" order "${args[@]}" || { echo "::error::$id/$arch goes backwards" >&2; bad=1; }
		compared=$((compared + 1))
	done
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONFIG_DIR/distros.txt")
[ "$bad" -eq 0 ] || exit 1
echo "release order: $compared repository(ies) compared with what is served; none goes backwards"
