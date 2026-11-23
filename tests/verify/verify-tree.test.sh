#!/usr/bin/env bash
#
# scripts/verify/verify-tree.sh: a tree built by build-repo.sh passes, and each way a tree can be
# wrong on its way to the bucket (an altered package, a package missing or extra, an altered or
# unsigned repomd.xml, another key, an altered repository file) is refused.
# Requires: rpm, createrepo_c, gpg, python3 with cryptography.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/tree.sh"
VERIFY="$HERE/scripts/verify/verify-tree.sh"
WORK="$(mktemp -d)"
trap 'fx_stop_agent; rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
fx_init "$WORK"; fx_archive_key; fx_other_key "$WORK/other.asc"
fx_admitted "$WORK/in"
fx_build_tree "$WORK/good" "$FX_T1" "$WORK/in" > /dev/null 2>&1
out="$("$VERIFY" "$WORK/good" "$WORK/archive.asc" 2>&1)"; check "a built tree is accepted" 0 "$?"
check "it says what it read" 1 "$(printf '%s' "$out" | grep -c 'verified 14 repository(ies)')"

bad() { # <description> <fragment> <mutation command run inside a copy of the tree>
	local d="$1" frag="$2" o rc=0
	rm -rf "${WORK:?}/t"; cp -r "$WORK/good" "$WORK/t"
	( cd "$WORK/t" && eval "$3" ) > /dev/null 2>&1
	o="$("$VERIFY" "$WORK/t" "$WORK/archive.asc" 2>&1)" || rc=$?
	check "$d: refused" 1 "$rc"
	check "$d: says why" 1 "$(printf '%s' "$o" | grep -cF -- "$frag")"
}
R=fc45/x86_64
bad "a package altered after the metadata was made" "does not match its checksum" "printf x >> $R/Packages/podup-1.2.3-1.glyndor.any.x86_64.rpm"
bad "a package that is listed and gone" "is listed and missing" "rm $R/Packages/podup-1.2.3-1.glyndor.any.x86_64.rpm"
bad "a package that nothing lists" "do not list the same files" "cp $R/Packages/podup-1.2.3-1.glyndor.any.x86_64.rpm $R/Packages/extra-1-1.glyndor.any.x86_64.rpm"
bad "a listed package replaced by a link" "type 'l'" "mv $R/Packages/podup-1.2.3-1.glyndor.any.x86_64.rpm /tmp/x-\$\$ ; ln -s /etc/hostname $R/Packages/podup-1.2.3-1.glyndor.any.x86_64.rpm"
bad "a repomd.xml altered after it was signed" "is not signed by the archive key" "sed -i 's/<revision>/<revision>9/' $R/repodata/repomd.xml"
bad "a repomd.xml with no signature" "repomd.xml is not signed" "rm $R/repodata/repomd.xml.asc"
bad "a repomd.xml signed by another key" "is not signed by the archive key" "cp $WORK/other.asc $R/repodata/repomd.xml.asc"
bad "the primary metadata missing" "is missing" "rm $R/repodata/*-primary.xml.gz"
bad "the public key of the tree is another one" "is not " "cp $WORK/other.asc glyndor-rpm-key.asc"
bad "a repository file that says something else" "is not the repository file the channel gives out" "sed -i 's/gpgcheck=1/gpgcheck=0/' el9/glyndor.repo"
bad "a repository file with the repo gpgcheck off" "is not the repository file" "sed -i 's/repo_gpgcheck=1/repo_gpgcheck=0/' fc44/glyndor.repo"
bad "an architecture missing from an id" "has no aarch64 repository" "rm -rf el10/aarch64"
bad "a file at the root that nothing lists" "the tree holds what nothing lists: payload.sh" "echo x > payload.sh"
bad "a file in an id folder that nothing lists" "the tree holds what nothing lists: el9/extra.rpm" "echo x > el9/extra.rpm"
bad "a file in repodata that repomd.xml does not list" "the tree holds what nothing lists" "echo x > $R/repodata/stray.xml"
bad "a folder that nothing lists" "the tree holds what nothing lists" "mkdir el9/hidden"
bad "a hidden file" "the tree holds what nothing lists: .env" "echo x > .env"
bad "a file that the group can write" "can write" "chmod g+w el9/glyndor.repo"
bad "a folder that others can write" "can write" "chmod o+w el9"
bad "a package that anyone can write" "can write" "chmod 666 $R/Packages/podup-1.2.3-1.glyndor.any.x86_64.rpm"
bad "a file whose name ends in a space, which a trimming reader would take for the repository file" "closed alphabet" "cp el9/glyndor.repo 'el9/glyndor.repo '"
bad "a file whose name starts with a space" "closed alphabet" "echo x > 'el9/ x'"
bad "a file with a tab in its name" "closed alphabet" "echo x > \"el9/a\tb\""
bad "a file with a line feed in its name" "closed alphabet" "echo x > \"el9/a\nb\""
bad "a folder with a space in its name" "closed alphabet" "mkdir 'el9/a b'"
bad "a name with a non-ASCII letter" "closed alphabet" "echo x > el9/caf$(printf '\303\251')"
bad "a symbolic link anywhere" "type 'l'" "ln -s /etc/passwd el9/passwd"
bad "a symbolic link in place of a folder" "type 'l'" "rm -rf el10/aarch64 && ln -s x86_64 el10/aarch64"
bad "a fifo" "type 'p'" "mkfifo el9/pipe"
bad "an installer of something that is not a product" "install/nginx" "mkdir -p install && echo x > install/nginx"
bad "an installer named like a product but not literally one" "install/po.up" "mkdir -p install && echo x > install/po.up"
bad "an index page with nothing in the repository to compare it with" "index.html" "echo x > index.html"
bad "an id folder that is gone" "is a distribution of config/distros.txt and the tree has no folder for it" "rm -rf leap16.1"
bad "a data file of repomd.xml that is altered" "does not match the checksum repomd.xml gives it" "for f in $R/repodata/*-other.xml.gz; do printf x >> \$f; done"
bad "a data file of repomd.xml that is gone" "is listed by repomd.xml and missing" "rm $R/repodata/*-filelists.xml.gz"
FPR="$(gpg --list-secret-keys --with-colons | awk -F: '$1 == "fpr" { print $10; exit }')"
bad "a package signed by nobody, with metadata made to match" "x86_64.rpm: " "rpmsign --delsign $R/Packages/podup-1.2.3-1.glyndor.any.x86_64.rpm; rm -rf $R/repodata; createrepo_c --quiet --revision $FX_T1 --set-timestamp-to-revision --compress-type gz --general-compress-type gz --workers 1 $R; gpg --batch --yes --armor --detach-sign --faked-system-time '$FX_T1!' -u $FPR -o $R/repodata/repomd.xml.asc $R/repodata/repomd.xml"
bad "a repository file that offers every package of the host" "is not the repository file the channel gives out" "sed -i '/^includepkgs=/d' el9/glyndor.repo"
bad "a repository file without its last line feed" "is not the repository file the channel gives out" "truncate -s -1 el9/glyndor.repo"
bad "a repository file with a NUL at its end" "is not the repository file the channel gives out" "printf '\\0' >> el9/glyndor.repo"
bad "a repository file with a priority" "is not the repository file the channel gives out" "echo priority=50 >> el9/glyndor.repo"
bad "a repository file that no longer skips an unavailable repository" "is not the repository file the channel gives out" "sed -i '/skip_if_unavailable/d' el9/glyndor.repo"
bad "a repository file at an address another id would use" "is not the repository file the channel gives out" "sed -i 's#/el9/#/el10/#' el9/glyndor.repo"
# two products that ship the same file
mkdir -p "$WORK/dup/podup" "$WORK/dup/epistle"
fx_rpm "$WORK/dup/podup" podup 1.2.3 1.glyndor.any noarch provides=podup file=/usr/bin/shared
fx_rpm "$WORK/dup/epistle" epistle 0.4.0 1.glyndor.any noarch provides=epistle file=/usr/bin/shared
"$HERE/scripts/build/build-repo.sh" "$WORK/archive.asc" "$FX_T1" "$WORK/dup" "$WORK/duptree" > /dev/null 2>&1
o="$("$VERIFY" "$WORK/duptree" "$WORK/archive.asc" 2>&1)"; rc=$?
check "two packages that own the same file make the tree refused" 1 "$rc"
check "and the file is named" 1 "$(printf '%s' "$o" | grep -c "two packages own the file '/usr/bin/shared'")"
mkdir -p "$WORK/empty"
o="$("$VERIFY" "$WORK/empty" "$WORK/archive.asc" 2>&1)"; check "a tree with no repository is refused" 1 "$?"
o="$("$VERIFY" "$WORK/good" 2>&1)"; check "a missing argument is refused" 1 "$?"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
