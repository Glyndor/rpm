#!/usr/bin/env bash
#
# Read a built repository tree the way a client would, and refuse it when anything is off.
#
# Usage: verify-tree.sh [--config <dir>] <tree> <public-key.asc>
#
# For every distribution and architecture directory of the tree: repomd.xml is signed by the archive
# key, the primary metadata matches the checksum repomd.xml gives it, every package the metadata lists
# is in Packages/ with the checksum it lists and a valid signature (digests and signature, by rpm,
# against a scratch database that holds only the archive key), and Packages/ holds nothing the metadata
# does not list. Around them: the repository file of each id is the one the channel gives out, and the
# public key of the tree is the committed one, byte for byte. A tree is either all of this or refused.
# Requires: rpm, gpg, gpgv, python3.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_DIR="$HERE/config"
BASE_URL="${REPO_BASE_URL:-https://rpm.glyndor.net}"
die() { echo "::error::verify-tree: $*" >&2; exit 1; }
if [ "${1:-}" = --config ]; then CONFIG_DIR="${2:?--config needs a directory}"; shift 2; fi
[ "$#" -eq 2 ] || die "usage: verify-tree.sh [--config <dir>] <tree> <public-key.asc>"
TREE="$1"; PUB="$2"
if [ ! -d "$TREE" ] || [ ! -f "$PUB" ]; then die "$TREE is not a directory or $PUB is not a file"; fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
state() { python3 -I "$HERE/scripts/verify/repo-state.py" "$@"; }

cmp -s "$PUB" "$TREE/glyndor-rpm-key.asc" || die "the key at the root of the tree is not $PUB"
gpg --batch --no-default-keyring --keyring "$WORK/ring.kbx" --import "$PUB" > /dev/null 2>&1 || die "cannot read $PUB"
mkdir "$WORK/db"
rpmkeys --dbpath "$WORK/db" --import "$PUB" || die "rpm cannot import $PUB"

# The whole tree is read, not only the folders that are expected: anything else in it would be published.
# A link or a special file is refused, and at the end every file must be one that something above listed.
: > "$WORK/expected-files"; : > "$WORK/expected-dirs"
# The records end in NUL, so a name with a space, a tab or a line feed at its edge cannot be trimmed into another name, and
# every path is first held to a closed alphabet: nothing that needs quoting is ever published.
while IFS=$'\t' read -r -d '' kind rel; do
	case "$kind" in f | d) ;; *) die "'$rel' is not a regular file or a folder (type '$kind'); a link or a special file is never published" ;; esac
	[[ "$rel" =~ ^[A-Za-z0-9._+~/-]+$ ]] || die "the tree holds a path outside the closed alphabet (letters, digits and . _ + ~ / -): '$rel'"
done < <(find "$TREE" -mindepth 1 -printf '%y\t%P\0')
# nothing of the tree may be written by its group or by others: what is signed and uploaded must be what this job
# made, and a tree another process could still change is not
writable="$(find "$TREE" ! -type l -perm /022 -printf '%m %P\n' | head -3)"
[ -z "$writable" ] || die "the tree has files or folders that its group or others can write: $(printf '%s' "$writable" | tr '\n' ',')"
echo glyndor-rpm-key.asc >> "$WORK/expected-files"

repos=0; packages=0
while IFS=$'\t' read -r id _suffix archs _client _form; do
	[ -d "$TREE/$id" ] || die "$id is a distribution of config/distros.txt and the tree has no folder for it"
	echo "$id" >> "$WORK/expected-dirs"; echo "$id/glyndor.repo" >> "$WORK/expected-files"
	# written to a file and compared byte by byte: a command substitution drops the line feeds at the end and cannot
	# hold a NUL, so two different files could read as the same one
	"$HERE/scripts/build/repo-file.sh" --config "$CONFIG_DIR" "$id" "$BASE_URL" "$BASE_URL/glyndor-rpm-key.asc" > "$WORK/expected.repo" \
		|| die "cannot render the repository file of $id"
	cmp -s "$WORK/expected.repo" "$TREE/$id/glyndor.repo" || die "$id/glyndor.repo is not the repository file the channel gives out"
	for arch in ${archs//,/ }; do
		repo="$TREE/$id/$arch"
		printf '%s\n' "$id/$arch" "$id/$arch/Packages" "$id/$arch/repodata" >> "$WORK/expected-dirs"
		printf '%s\n' "$id/$arch/repodata/repomd.xml" "$id/$arch/repodata/repomd.xml.asc" >> "$WORK/expected-files"
		[ -d "$repo" ] || die "$id has no $arch repository; every id is served for every architecture"
		gpgv --keyring "$WORK/ring.kbx" "$repo/repodata/repomd.xml.asc" "$repo/repodata/repomd.xml" > /dev/null 2>&1 \
			|| die "$id/$arch: repomd.xml is not signed by the archive key"
		href="$(state primary "$repo/repodata/repomd.xml")" || die "$id/$arch: unreadable repomd.xml"
		[ -f "$repo/$href" ] || die "$id/$arch: the primary metadata $href is missing"
		state locations "$repo/repodata/repomd.xml" > "$WORK/located" || die "$id/$arch: repomd.xml lists a file of a form the channel does not publish"
		while IFS=$'\t' read -r lhref lsum; do
			if [ ! -f "$repo/$lhref" ] || [ -L "$repo/$lhref" ]; then die "$id/$arch: $lhref is listed by repomd.xml and missing"; fi
			[ "$(sha256sum "$repo/$lhref" | cut -d' ' -f1)" = "$lsum" ] || die "$id/$arch: $lhref does not match the checksum repomd.xml gives it"
			echo "$id/$arch/$lhref" >> "$WORK/expected-files"
		done < "$WORK/located"
		state packages "$repo/repodata/repomd.xml" "$repo/$href" > "$WORK/list" || die "$id/$arch: unreadable primary metadata"
		: > "$WORK/listed"
		while IFS=$'\t' read -r name _a _e _v _r sum loc; do
			[[ "$loc" =~ ^Packages/[A-Za-z0-9._+~-]+\.rpm$ ]] || die "$id/$arch: $name is listed at '$loc'"
			if [ ! -f "$repo/$loc" ] || [ -L "$repo/$loc" ]; then die "$id/$arch: $loc is listed and missing"; fi
			[ "$(sha256sum "$repo/$loc" | cut -d' ' -f1)" = "$sum" ] || die "$id/$arch: $loc does not match its checksum"
			out="$(rpmkeys --dbpath "$WORK/db" -K "$repo/$loc" 2>&1)" || die "$id/$arch: rpm refuses $loc: $out"
			case "$out" in *"digests signatures OK") ;; *) die "$id/$arch: $loc: $out" ;; esac
			printf '%s\n' "${loc#Packages/}" >> "$WORK/listed"
			echo "$id/$arch/$loc" >> "$WORK/expected-files"
			packages=$((packages + 1))
		done < "$WORK/list"
		# two packages of one repository must not own the same file: every upgrade of both would fail
		: > "$WORK/owned"
		while IFS=$'\t' read -r _n _a _e _v _r _sum loc; do
			rpm --dbpath "$WORK/db" -qp --nomanifest --nosignature --nodigest --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$repo/$loc" 2> /dev/null \
				| grep -v '^d' | cut -d' ' -f2- | sed "s|\$|\t$loc|" >> "$WORK/owned" || true
		done < "$WORK/list"
		dup="$(cut -f1 "$WORK/owned" | sort | uniq -d | head -1)"
		if [ -n "$dup" ]; then die "$id/$arch: two packages own the file '$dup'"; fi
		(cd "$repo/Packages" && find . -mindepth 1 -printf '%P\n') | sort > "$WORK/present"
		sort "$WORK/listed" | cmp -s - "$WORK/present" || die "$id/$arch: Packages/ and the metadata do not list the same files"
		repos=$((repos + 1))
	done
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONFIG_DIR/distros.txt")
[ "$repos" -ge 1 ] || die "the tree holds no repository"
# The installers (one per product of the channel) and the index page are the only other files, and each is the very file
# this repository renders: a name is no proof of what a file does when people run it as root. With no trusted source to
# render it from, the file is refused.
if [ -d "$TREE/install" ]; then
	echo install >> "$WORK/expected-dirs"
	while IFS= read -r name; do
		if [ ! -x "$HERE/scripts/build/build-installers.sh" ] || [ ! -f "$HERE/scripts/installer/install-template.sh" ]; then
			die "install/$name: the tree has an installer and this repository has nothing to render it from"
		fi
		[[ "$name" =~ ^[a-z0-9-]+$ ]] || die "install/$name is not the name of a product"
		rows="$(grep -vE '^[[:space:]]*(#|$)' "$CONFIG_DIR/products.txt" | awk -F'\t' -v n="$name" '$1 == n' | wc -l)"
		[ "$rows" -eq 1 ] || die "install/$name is not the installer of a product of config/products.txt"
		"$HERE/scripts/build/build-installers.sh" "$PUB" "$WORK/installers" "$name" > /dev/null || die "cannot render the installer of $name"
		cmp -s "$WORK/installers/$name" "$TREE/install/$name" || die "install/$name is not what scripts/installer/install-template.sh renders for $name"
		echo "install/$name" >> "$WORK/expected-files"
	done < <(find "$TREE/install" -mindepth 1 -maxdepth 1 -type f -printf '%f\n')
fi
if [ -e "$TREE/index.html" ]; then
	[ -f "$HERE/site/index.html" ] || die "the tree has an index.html and this repository has no site/index.html to compare it with"
	cmp -s "$HERE/site/index.html" "$TREE/index.html" || die "index.html is not site/index.html of this repository"
	echo index.html >> "$WORK/expected-files"
fi
# what is there against what was listed, whole lines and nothing trimmed (the alphabet above leaves no space or tab to lose)
sort -u "$WORK/expected-files" > "$WORK/expected-files.sorted"; sort -u "$WORK/expected-dirs" > "$WORK/expected-dirs.sorted"
(cd "$TREE" && find . -mindepth 1 -type f -printf '%P\n') | sort > "$WORK/present-files"
(cd "$TREE" && find . -mindepth 1 -type d -printf '%P\n') | sort > "$WORK/present-dirs"
extra="$({ comm -13 "$WORK/expected-files.sorted" "$WORK/present-files"; comm -13 "$WORK/expected-dirs.sorted" "$WORK/present-dirs" | sed 's|$|/|'; } | head -3)"
[ -z "$extra" ] || die "the tree holds what nothing lists: $(printf '%s' "$extra" | tr '\n' ' ')"
echo "verified $repos repository(ies), $packages package(s)"
