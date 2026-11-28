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
#      when anything is off, the previous pairs are put back, the bucket is read again, and the run
#      ends red saying which repositories could not be confirmed to hold their previous pair and
#      which had none to go back to.
#   0. before anything goes up, a repository whose revision in the bucket is higher than the tree's is refused.
# Nothing is ever deleted from the bucket. What left the tree stays there: an index a client still holds may
# name it, and nothing signed says when it stopped being part of the repository.
# Requires: aws (CLI v2), jq, gpg, gpgv, sha256sum.
set -euo pipefail
export LC_ALL=C

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
		put_pair "$r" "$WORK/previous/$r" || echo "::error::sync-tree: an upload of the previous pair of $r failed" >&2
	done
}
# Prints the repositories whose bucket could not be confirmed to hold, byte for byte, the pair that
# was kept. A failed upload of the rollback does not decide it: the object may never have changed.
# The signature is not checked here, since a pair that did not verify before the run is put back as it was.
not_restored() {
	local r file lost=""
	for r in "${PAIRS[@]}"; do
		[ -n "${TOUCHED[$r]:-}" ] || continue
		[ -f "$WORK/previous/$r/repomd.xml" ] || continue
		mkdir -p "$WORK/restored/$r"
		for file in repomd.xml repomd.xml.asc; do
			if s3 cp "s3://$BUCKET/$r/repodata/$file" "$WORK/restored/$r/$file" &&
				cmp -s "$WORK/previous/$r/$file" "$WORK/restored/$r/$file"; then continue; fi
			lost="$lost $r"
			break
		done
	done
	printf '%s' "${lost# }"
}
roll_back() { # <what went wrong>: put the previous pairs back and end the run saying what the bucket holds
	local r lost kept="" fresh="" outcome
	restore
	lost="$(not_restored)"
	for r in "${PAIRS[@]}"; do
		[ -n "${TOUCHED[$r]:-}" ] || continue
		if [ -f "$WORK/previous/$r/repomd.xml" ]; then kept="$kept $r"; else fresh="$fresh $r"; fi
	done
	if [ -n "$lost" ]; then
		outcome="the bucket could not be confirmed to hold the previous pair of $lost"
	elif [ -n "$kept" ]; then
		outcome="the previous pairs were put back"
	else
		outcome="there was no previous pair to put back"
	fi
	[ -z "$fresh" ] || outcome="$outcome; no previous pair for ${fresh# }, so what this run uploaded there stays in the bucket"
	die "$1; $outcome"
}
for r in "${PAIRS[@]}"; do
	TOUCHED[$r]=1
	put_pair "$r" "$TREE/$r/repodata" || roll_back "cannot upload the metadata of $r"
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
	[ "$ok" -eq 1 ] || roll_back "$r reads back different from what was uploaded"
done

echo "uploaded ${#FILES[@]} file(s) of the tree, ${#PAIRS[@]} repository pair(s) verified from the bucket"
