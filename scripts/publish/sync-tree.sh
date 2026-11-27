#!/usr/bin/env bash
#
# Upload a verified repository tree to the bucket in an order that never leaves it half done.
#
# Usage: sync-tree.sh <tree> <bucket> <work-dir>
#
# AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and AWS_ENDPOINT_URL come from the environment (the
# endpoint is a secret and never reaches argv). Stages, in this order:
#
#   1. packages and the metadata files whose name carries their checksum: uploaded only when the key
#      is not in the bucket. A key that is there must hold the same bytes (its sha256 is stored as
#      object metadata when it is written), or the run stops: an identity that was published never
#      changes its bytes, and nothing here compares by size.
#   2. the files that change in place and that no metadata points into: repository files, the key,
#      the installers, the index page.
#   3. the previous repomd.xml and repomd.xml.asc of every repository are kept in <work-dir>.
#   4. for each repository, the signature and then repomd.xml. This is the one moment a client can
#      see an index and a signature that do not match, and it fails closed (the client refuses it).
#   5. every pair is read back from the bucket (not through the cache) and checked against the key;
#      when anything is off, the previous pairs are put back, the bucket is read back again to prove
#      that the rollback worked, and the run ends red naming the repository that was left broken.
#   0. before anything goes up, a repository whose revision in the bucket is higher than the tree's is refused.
#   6. objects that left the tree are noted in state/retired.tsv and deleted KEEP_DAYS (15) days after
#      that, never earlier and never from a first level folder that is not in the tree.
# Requires: aws (CLI v2), jq, gpg, gpgv, sha256sum.
set -euo pipefail
export LC_ALL=C

KEEP_DAYS="${KEEP_DAYS:-15}"
die() { echo "::error::sync-tree: $*" >&2; exit 1; }
[ "$#" -eq 3 ] || die "usage: sync-tree.sh <tree> <bucket> <work-dir>"
TREE="$1"; BUCKET="$2"; WORK="$3"
[[ "$BUCKET" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "the bucket name '$BUCKET' is not a bucket name"
if [ ! -d "$TREE" ] || [ ! -d "$WORK" ]; then die "$TREE and $WORK must be directories"; fi
[ -n "${AWS_ENDPOINT_URL:-}" ] || die "AWS_ENDPOINT_URL is empty; refusing to talk to the default endpoint"
if [ -n "${AWS_ENDPOINT_URL_S3:-}" ] || [ -n "${AWS_IGNORE_CONFIGURED_ENDPOINT_URLS:-}" ]; then die "a variable that redirects the endpoint is set"; fi
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then die "the bucket credentials are not set"; fi
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
[ -f "$TREE/glyndor-rpm-key.asc" ] || die "$TREE is not a built tree"
s3() { aws s3 "$@" --only-show-errors --no-progress; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

mapfile -t FILES < <(cd "$TREE" && find . -type f -printf '%P\n' | sort)
declare -A IN_TREE=()
for f in "${FILES[@]}"; do IN_TREE[$f]=1; done
aws s3api list-objects-v2 --bucket "$BUCKET" --output json > "$WORK/listing.json" || die "cannot list the bucket"
declare -A THERE=()
while IFS=$'\t' read -r key _modified; do THERE[$key]=1; done \
	< <(jq -r '(.Contents // [])[] | [.Key, .LastModified] | @tsv' "$WORK/listing.json")

is_final() { case "$1" in */repodata/repomd.xml | */repodata/repomd.xml.asc) return 0 ;; *) return 1 ;; esac; }
is_by_hash() { # packages and checksum-named metadata
	case "$1" in */Packages/*.rpm) return 0 ;; */repodata/*) [[ "${1##*/}" =~ ^[0-9a-f]{64}- ]] && return 0 ;; esac
	return 1
}

# --- 0: the previous pairs, and nothing goes back --------------------------------------------------------
# The tree was checked against what was served when it was built, which may have been hours ago: what the bucket holds
# NOW is what decides, so a repository whose current revision is higher than the tree's is refused before anything is
# written, and the previous pair of every repository is kept for the case that the read back fails.
mapfile -t PAIRS < <(for f in "${FILES[@]}"; do case "$f" in */repodata/repomd.xml) echo "${f%/repodata/repomd.xml}" ;; esac; done)
mkdir -p "$WORK/previous" "$WORK/back"
revision_of() { # <repomd.xml>: its revision, or nothing
	local r
	r="$(head -c 1048576 "$1" | sed -n 's|.*<revision>\([0-9]*\)</revision>.*|\1|p' | head -1)"
	[[ "$r" =~ ^[0-9]{9,11}$ ]] && printf '%s' "$r"
	return 0
}
for r in "${PAIRS[@]}"; do
	mkdir -p "$WORK/previous/$r"
	if [ -n "${THERE[$r/repodata/repomd.xml]:-}" ]; then
		s3 cp "s3://$BUCKET/$r/repodata/repomd.xml" "$WORK/previous/$r/repomd.xml" || die "cannot keep the previous $r/repodata/repomd.xml"
		s3 cp "s3://$BUCKET/$r/repodata/repomd.xml.asc" "$WORK/previous/$r/repomd.xml.asc" || die "cannot keep the previous signature of $r"
		have="$(revision_of "$WORK/previous/$r/repomd.xml")"
		[ -n "$have" ] || die "the repomd.xml of $r in the bucket has no revision I can read; refusing to replace it"
		want="$(revision_of "$TREE/$r/repodata/repomd.xml")"
		[ -n "$want" ] || die "the repomd.xml of $r in the tree has no revision I can read"
		[ "$have" -le "$want" ] || die "the bucket holds $r at revision $have, newer than the tree's $want; a repository never goes back"
	fi
done

# --- 1: by checksum, only what is new ------------------------------------------------------------
for f in "${FILES[@]}"; do
	is_by_hash "$f" || continue
	want="$(sha "$TREE/$f")"
	if [ -n "${THERE[$f]:-}" ]; then
		have="$(aws s3api head-object --bucket "$BUCKET" --key "$f" --output json | jq -r '.Metadata.sha256 // ""')" \
			|| die "cannot read the object $f"
		[ "$have" = "$want" ] || die "$f is in the bucket with other bytes ($have), and a published identity does not change"
		continue
	fi
	s3 cp "$TREE/$f" "s3://$BUCKET/$f" --metadata "sha256=$want" --cache-control "public, max-age=31536000, immutable" \
		|| die "cannot upload $f"
done

# --- 2: what changes in place ----------------------------------------------------------------------
for f in "${FILES[@]}"; do
	is_by_hash "$f" && continue
	is_final "$f" && continue
	ctype="application/octet-stream"
	case "$f" in *.repo | install/*) ctype="text/plain" ;; *.asc) ctype="application/pgp-keys" ;; *.html) ctype="text/html" ;; esac
	s3 cp "$TREE/$f" "s3://$BUCKET/$f" --metadata "sha256=$(sha "$TREE/$f")" --cache-control "public, max-age=300" \
		--content-type "$ctype" || die "cannot upload $f"
done

# --- 3 to 5: the pairs (the previous ones were kept before anything went up) -----------------------------
put_pair() { # <repository> <directory holding repomd.xml and repomd.xml.asc>
	s3 cp "$2/repomd.xml.asc" "s3://$BUCKET/$1/repodata/repomd.xml.asc" --cache-control "public, max-age=60" || return 1
	s3 cp "$2/repomd.xml" "s3://$BUCKET/$1/repodata/repomd.xml" --cache-control "public, max-age=60" || return 1
}
gpg --batch --no-default-keyring --keyring "$WORK/ring.kbx" --import "$TREE/glyndor-rpm-key.asc" > /dev/null 2>&1 || die "cannot read the archive key"
declare -A TOUCHED=()
restore() { # put the previous pairs back; the run still ends red
	local r
	for r in "${PAIRS[@]}"; do
		[ -n "${TOUCHED[$r]:-}" ] || continue
		[ -f "$WORK/previous/$r/repomd.xml" ] || continue
		put_pair "$r" "$WORK/previous/$r" || echo "::error::could not put back the previous pair of $r" >&2
	done
}
check_previous() { # the pairs the bucket holds are the ones that were kept; prints the ones that are not
	local r bad=""
	for r in "${PAIRS[@]}"; do
		[ -n "${TOUCHED[$r]:-}" ] || continue
		[ -f "$WORK/previous/$r/repomd.xml" ] || continue
		s3 cp "s3://$BUCKET/$r/repodata/repomd.xml" "$WORK/previous/$r/repomd.xml.now" || { bad="$bad $r"; continue; }
		s3 cp "s3://$BUCKET/$r/repodata/repomd.xml.asc" "$WORK/previous/$r/repomd.xml.asc.now" || { bad="$bad $r"; continue; }
		cmp -s "$WORK/previous/$r/repomd.xml" "$WORK/previous/$r/repomd.xml.now" || { bad="$bad $r"; continue; }
		cmp -s "$WORK/previous/$r/repomd.xml.asc" "$WORK/previous/$r/repomd.xml.asc.now" || { bad="$bad $r"; continue; }
		gpgv --keyring "$WORK/ring.kbx" "$WORK/previous/$r/repomd.xml.asc.now" "$WORK/previous/$r/repomd.xml.now" > /dev/null 2>&1 || { bad="$bad $r"; continue; }
	done
	printf '%s' "${bad# }"
}
for r in "${PAIRS[@]}"; do
	TOUCHED[$r]=1
	put_pair "$r" "$TREE/$r/repodata" || {
		restore
		bad="$(check_previous)"
		if [ -n "$bad" ]; then
			die "cannot upload the metadata of $r; the previous pair of $bad could not be put back and the bucket holds a pair that does not match"
		fi
		die "cannot upload the metadata of $r; the previous pairs were put back"
	}
done
for r in "${PAIRS[@]}"; do
	mkdir -p "$WORK/back/$r"
	ok=1
	s3 cp "s3://$BUCKET/$r/repodata/repomd.xml" "$WORK/back/$r/repomd.xml" || ok=0
	s3 cp "s3://$BUCKET/$r/repodata/repomd.xml.asc" "$WORK/back/$r/repomd.xml.asc" || ok=0
	if [ "$ok" -eq 1 ]; then
		cmp -s "$WORK/back/$r/repomd.xml" "$TREE/$r/repodata/repomd.xml" || ok=0
		cmp -s "$WORK/back/$r/repomd.xml.asc" "$TREE/$r/repodata/repomd.xml.asc" || ok=0
		gpgv --keyring "$WORK/ring.kbx" "$WORK/back/$r/repomd.xml.asc" "$WORK/back/$r/repomd.xml" > /dev/null 2>&1 || ok=0
	fi
	if [ "$ok" -eq 0 ]; then
		restore
		bad="$(check_previous)"
		if [ -n "$bad" ]; then
			die "$r reads back different from what was uploaded; the previous pair of $bad could not be put back and the bucket holds a pair that does not match"
		fi
		die "$r reads back different from what was uploaded; the previous pairs were put back"
	fi
done

# --- 6: what left the tree is deleted only after the metadata that referenced it has expired ------------
# The tree is rebuilt every run, so nothing in it says when an object stopped being part of it; state/retired.tsv
# in the bucket does (`<key> <TAB> <epoch it was first seen out of the tree>`). An object is deleted once that
# was KEEP_DAYS ago (14 days, the longest validity apt gives its signed metadata, and one more of cache), never
# by the date it was uploaded. It fails closed: nothing is deleted from a folder that is not in the tree of this
# run, whatever the config says, so the folder of an id that is finished stays with its last signed repomd.xml.
NOW="${SYNC_NOW:-$(date +%s)}"
declare -A RET=()
if [ -n "${THERE[state/retired.tsv]:-}" ]; then
	s3 cp "s3://$BUCKET/state/retired.tsv" "$WORK/retired.tsv" || die "cannot read state/retired.tsv"
	while IFS=$'\t' read -r key since; do
		[[ "$since" =~ ^[0-9]{9,11}$ ]] || die "state/retired.tsv has a malformed line for '$key'"
		RET[$key]="$since"
	done < "$WORK/retired.tsv"
fi
limit=$((NOW - KEEP_DAYS * 86400))
deleted=0
declare -A NEXT=()
for key in "${!THERE[@]}"; do
	case "$key" in state/*) continue ;; esac
	[ -z "${IN_TREE[$key]:-}" ] || continue
	# only what lives in a folder this run is publishing may be deleted: a key with no folder, or in a folder that is not
	# in the tree (an id that is finished, one the config forgot, one nobody has heard of), is never touched or noted
	case "$key" in */*) ;; *) continue ;; esac
	[ -d "$TREE/${key%%/*}" ] || continue
	if [ -z "${RET[$key]:-}" ]; then NEXT[$key]="$NOW"; continue; fi
	if [ "${RET[$key]}" -gt "$limit" ]; then NEXT[$key]="${RET[$key]}"; continue; fi
	aws s3api delete-object --bucket "$BUCKET" --key "$key" > /dev/null || die "cannot delete $key"
	deleted=$((deleted + 1))
done
for key in "${!NEXT[@]}"; do printf '%s\t%s\n' "$key" "${NEXT[$key]}"; done | sort > "$WORK/retired.new"
s3 cp "$WORK/retired.new" "s3://$BUCKET/state/retired.tsv" --cache-control "no-store" || die "cannot write state/retired.tsv"
echo "uploaded ${#FILES[@]} file(s) of the tree, ${#PAIRS[@]} repository pair(s) verified from the bucket, ${#NEXT[@]} object(s) retired, $deleted deleted"
