#!/usr/bin/env bash
#
# The publication deletes nothing from the bucket: not what left the tree, not what a list in the bucket
# names, whatever the clock or the environment say. Nothing signs such a list, so whoever can write one
# object could choose what is deleted. What may be deleted, and from which signed state, is a change of
# its own, and it replaces this suite.
#
# The upload is run over small trees made here, signed with a throwaway key, against a bucket that is a
# folder. The tree of a real build is in sync-tree.test.sh.
# Requires: gpg, gpgv, jq, sha256sum.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
export GNUPGHOME="$WORK/gnupg"
trap 'timeout 10 gpgconf --kill gpg-agent > /dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
for tool in gpg gpgv jq sha256sum; do
	command -v "$tool" > /dev/null 2>&1 || { echo "FAIL  $tool is needed by this suite and was not found"; exit 1; }
done

# --- no command that deletes, anywhere the channel runs one -------------------------------------------
DELETES='delete-objects?([^a-z]|$)|delete-bucket|s3[[:space:]]+(rm|mv|rb)([[:space:]]|$)|s3[[:space:]]+sync[^#]*--delete'
deleting() { # <root>: the lines of the scripts and workflows of the tree that delete from a bucket
	local found
	found="$(grep -rnE -- "$DELETES" "$1/scripts" "$1/.github/workflows" 2> /dev/null)"
	[ -z "$found" ] || printf '%s\n' "${found//"$1/"/}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
	return 0
}
n=0
# shellcheck disable=SC2016 # the planted lines are text, with the variables left as they are
for line in 'aws s3api delete-object --bucket b --key k' 'aws s3api delete-objects --bucket b' 's3 rm "s3://$BUCKET/$key"' \
	'aws s3 sync tree s3://b --delete' 'aws s3 mv s3://b/a s3://b/c'; do
	n=$((n + 1)); mkdir -p "$WORK/planted$n/scripts/publish" "$WORK/planted$n/.github/workflows"
	printf '%s\n' "$line" > "$WORK/planted$n/scripts/publish/x.sh"
	check "the search finds: $line" 1 "$(deleting "$WORK/planted$n" | wc -l)"
done
check "no script and no workflow of this repository deletes from a bucket" "" "$(deleting "$HERE")"

# --- what the upload does -----------------------------------------------------------------------------
mkdir -m 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key 'Glyndor test <test@example.invalid>' ed25519 sign 1d > /dev/null 2>&1 \
	|| { echo "FAIL  cannot make the throwaway key"; exit 1; }
tree() { # <folder> <revision> <version>: one repository with one package of that version
	local repo="$1/fc45/x86_64" hex
	mkdir -p "$repo/Packages" "$repo/repodata"
	gpg --batch --armor --export > "$1/glyndor-rpm-key.asc"
	printf 'package %s\n' "$3" > "$repo/Packages/podup-$3.rpm"
	hex="$(printf '%s' "$3" | sha256sum | cut -d' ' -f1)"
	printf 'primary %s\n' "$3" > "$repo/repodata/$hex-primary.xml.gz"
	printf '<repomd><revision>%s</revision></repomd>\n' "$2" > "$repo/repodata/repomd.xml"
	gpg --batch --pinentry-mode loopback --passphrase '' --armor --detach-sign --output "$repo/repodata/repomd.xml.asc" "$repo/repodata/repomd.xml"
}
tree "$WORK/t1" 1790000000 1.2.3
tree "$WORK/t2" 1790000300 1.2.4
mkdir -p "$WORK/bin"
cp "$HERE/tests/fixtures/rpm/fake-aws.sh" "$WORK/bin/aws"; chmod +x "$WORK/bin/aws"
export PATH="$WORK/bin:$PATH" FAKE_S3="$WORK/s3" FAKE_S3_LOG="$WORK/log"
export AWS_ENDPOINT_URL="https://example.invalid" AWS_ACCESS_KEY_ID=k AWS_SECRET_ACCESS_KEY=s
sync() { # <tree>: upload it, with every variable that ever shortened a window set against the bucket
	rm -rf "${WORK:?}/w"; mkdir "$WORK/w"; : > "$FAKE_S3_LOG"
	KEEP_DAYS=0 SYNC_NOW=1999999999 "$HERE/scripts/publish/sync-tree.sh" "$1" b "$WORK/w" > "$WORK/out" 2>&1; echo $?
}
there() { [ -f "$FAKE_S3/b/o/$1" ] && echo 1 || echo 0; }
OLD=fc45/x86_64/Packages/podup-1.2.3.rpm
OLDMETA="fc45/x86_64/repodata/$(printf '1.2.3' | sha256sum | cut -d' ' -f1)-primary.xml.gz"

check "the first upload succeeds" 0 "$(sync "$WORK/t1")"
check "and writes no list of retired objects" 0 "$(there state/retired.tsv)"
check "a newer tree is uploaded" 0 "$(sync "$WORK/t2")"
check "the package that left the tree is still in the bucket" 1 "$(there "$OLD")"
check "and so is its metadata" 1 "$(there "$OLDMETA")"

# a list in the bucket that names what left the tree, a package that is served, and a stray key, all long overdue
mkdir -p "$FAKE_S3/b/o/state" "$FAKE_S3/b/o/fc45/stray"
printf 'x' > "$FAKE_S3/b/o/fc45/stray/x"
printf '%s\t1700000000\n' "$OLD" "$OLDMETA" fc45/x86_64/Packages/podup-1.2.4.rpm fc45/stray/x > "$FAKE_S3/b/o/state/retired.tsv"
before="$(sha256sum < "$FAKE_S3/b/o/state/retired.tsv")"
check "a run with a list in the bucket that names them all succeeds" 0 "$(sync "$WORK/t2")"
check "the package that left the tree is kept" 1 "$(there "$OLD")"
check "the metadata that left the tree is kept" 1 "$(there "$OLDMETA")"
check "the package of the tree is kept" 1 "$(there fc45/x86_64/Packages/podup-1.2.4.rpm)"
check "a key the tree never had is kept" 1 "$(there fc45/stray/x)"
check "the list is neither read nor written" 0 "$(grep -c 'state/' "$FAKE_S3_LOG")"
check "and is left as it was" "$before" "$(sha256sum < "$FAKE_S3/b/o/state/retired.tsv")"
check "and no call asks the bucket to delete anything" 0 "$(grep -cE -- "$DELETES" "$FAKE_S3_LOG")"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
