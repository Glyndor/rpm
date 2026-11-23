#!/usr/bin/env bash
#
# scripts/build/build-repo.sh over a fake admission: where each package lands, that the metadata
# and the packages are signed, that building twice gives the same files, what the repository file
# says, and the inputs it refuses.
# Requires: rpm, createrepo_c, gpg, python3 with cryptography.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/tree.sh"
WORK="$(mktemp -d)"
trap 'fx_stop_agent; rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
fx_init "$WORK"; fx_archive_key
fx_admitted "$WORK/in"
fx_build_tree "$WORK/t1" "$FX_T1" "$WORK/in" > /dev/null 2>&1; check "the tree is built" 0 "$?"
T="$WORK/t1"
ids="amzn2023 el10 el9 fc44 fc45 leap16.1 tumbleweed"
check "the tree is not writable by its group or by others" 0 "$(find "$T" -perm /022 | wc -l)"
( umask 000; "$HERE/scripts/build/build-repo.sh" "$WORK/archive.asc" "$FX_T1" "$WORK/in" "$WORK/t0" > /dev/null 2>&1 )
check "even when the caller's umask is 000" 0 "$(find "$WORK/t0" -perm /022 | wc -l)"
check "a repository for each id" "$ids" "$(fx_names "$T" | sed 's/ glyndor-rpm-key.asc//')"
for id in $ids; do
	check "$id has both architectures" "aarch64 x86_64" "$(fx_names "$T/$id" | sed 's/ glyndor.repo//')"
done
list() { fx_names "$T/$1/$2/Packages"; }
check "a static product is in every id and architecture" 14 "$(fx_count "$T" '*/Packages/podup-1.2.3-1.glyndor.any.*')"
check "the x86_64 one is not in the aarch64 repository" 0 "$(fx_count "$T" '*/aarch64/Packages/podup-*x86_64*')"
check "a noarch package is in both architectures of every id" 14 "$(fx_count "$T" '*/Packages/epistle-panel-*.noarch.rpm')"
check "a package for fc45 is in fc45 alone" 2 "$(fx_count "$T" '*/Packages/podman-6.2.0+r12-12.glyndor.fc45.*')"
check "and the catatonit extra is in el9 and amzn2023 alone" 4 "$(fx_count "$T" '*/Packages/catatonit-*')"
check "fc45 holds podman for its own architecture, the companions, and the products" \
	"epistle-panel-0.9.1-1.glyndor.any.noarch.rpm glyndor-release-1-1.glyndor.fc45.noarch.rpm podman-6.2.0+r12-12.glyndor.fc45.x86_64.rpm podman-docker-6.2.0+r12-12.glyndor.fc45.noarch.rpm podmansh-6.2.0+r12-12.glyndor.fc45.noarch.rpm podup-1.2.3-1.glyndor.any.x86_64.rpm" \
	"$(list fc45 x86_64)"
check "the signatures of the release are not published" 0 "$(find "$T" -name '*.sig' | wc -l)"
check "the public key is at the root, the same bytes" 0 "$(cmp "$WORK/archive.asc" "$T/glyndor-rpm-key.asc"; echo $?)"
check "repomd.xml has the build time as its revision" "$FX_T1" "$(python3 -I "$HERE/scripts/verify/repo-state.py" revision "$T/fc45/x86_64/repodata/repomd.xml")"
check "and a signature beside it" 1 "$([ -s "$T/fc45/x86_64/repodata/repomd.xml.asc" ] && echo 1 || echo 0)"
check "the metadata is named by its checksum" 1 "$(fx_names "$T/fc45/x86_64/repodata" | tr ' ' '\n' | grep -cE '^[0-9a-f]{64}-primary\.xml\.gz$')"
check "the repository file of fc45 is exactly the one given out" "[glyndor]
name=Glyndor
baseurl=https://rpm.glyndor.net/fc\$releasever/\$basearch/
type=rpm-md
enabled=1
autorefresh=1
gpgcheck=1
repo_gpgcheck=1
pkg_gpgcheck=1
skip_if_unavailable=1
includepkgs=epistle epistle-panel glyndor-release helmly helmly-agent podman podman-docker podmansh podup
gpgkey=https://rpm.glyndor.net/glyndor-rpm-key.asc" "$(cat "$T/fc45/glyndor.repo")"
check "no repository file sets a priority" 0 "$(grep -c '^priority' "$T"/*/glyndor.repo | grep -vc ':0$')"
# shellcheck disable=SC2016 # the pattern is literal text of the repository file
check "a tree for a test server writes its own base URL" 1 \
	"$(REPO_BASE_URL=http://127.0.0.1:8123 fx_build_tree "$WORK/t3" "$FX_T1" "$WORK/in" > /dev/null 2>&1; grep -c 'baseurl=http://127.0.0.1:8123/fc\$releasever/' "$WORK/t3/fc45/glyndor.repo")"
# shellcheck disable=SC2016 # the pattern is literal text of the repository file
check "the folder of Leap is the one \$releasever names" 1 "$(grep -c 'baseurl=https://rpm.glyndor.net/leap\$releasever/' "$T/leap16.1/glyndor.repo")"
check "the packages for the leap161 suffix are in the leap16.1 folder" 2 "$(fx_count "$T" '*/leap16.1/*/Packages/crun-*')"
check "every repository has the bootstrap package" 14 "$(fx_count "$T" '*/Packages/glyndor-release-1-1.glyndor.*.noarch.rpm')"
check "which says Glyndor, no epoch, and ships the key and the file" "Glyndor|(none)|/etc/pki/rpm-gpg/RPM-GPG-KEY-glyndor,/etc/yum.repos.d/glyndor.repo" \
	"$(rpm -qp --nomanifest --nosignature --qf '%{VENDOR}|%{EPOCH}|' "$T/fc45/x86_64/Packages/glyndor-release-1-1.glyndor.fc45.noarch.rpm" 2> /dev/null | tr -d '\n'; rpm -qp --nomanifest --nosignature -l "$T/fc45/x86_64/Packages/glyndor-release-1-1.glyndor.fc45.noarch.rpm" | paste -sd,)"
check "on zypper it also carries the vendor file" 1 "$(rpm -qp --nomanifest --nosignature -l "$T/leap16.1/x86_64/Packages/glyndor-release-1-1.glyndor.leap161.noarch.rpm" | grep -c vendors.d)"
check "and its repository file reads the key from the disk, not from a URL" 1 \
	"$(fx_cat "$T/fc45/x86_64/Packages/glyndor-release-1-1.glyndor.fc45.noarch.rpm" /etc/yum.repos.d/glyndor.repo | grep -c '^gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-glyndor$')"

# --- the same inputs give the same files ---------------------------------------------------------
fx_build_tree "$WORK/t2" "$FX_T1" "$WORK/in" > /dev/null 2>&1
check "a second build at the same time is the same tree, byte for byte" "$(cd "$T" && find . -type f -exec sha256sum {} + | sort | sha256sum)" \
	"$(cd "$WORK/t2" && find . -type f -exec sha256sum {} + | sort | sha256sum)"
fx_build_tree "$WORK/t4" "$FX_T2" "$WORK/in" > /dev/null 2>&1
check "the packages do not depend on the build time of the repository more than their signature" 1 \
	"$([ "$(python3 -I "$HERE/scripts/verify/repo-state.py" revision "$WORK/t4/fc45/x86_64/repodata/repomd.xml")" = "$FX_T2" ] && echo 1 || echo 0)"

# --- refusals ----------------------------------------------------------------------------------
refuse() { # <description> <fragment> <args...>
	local d="$1" frag="$2" o rc=0; shift 2
	o="$("$HERE/scripts/build/build-repo.sh" "$@" 2>&1)" || rc=$?
	check "$d: refused" 1 "$rc"
	check "$d: says why" 1 "$(printf '%s' "$o" | grep -cF -- "$frag")"
}
refuse "an output folder that exists" "exists" "$WORK/archive.asc" "$FX_T1" "$WORK/in" "$WORK/t1"
refuse "a time that is not an epoch" "is not an epoch" "$WORK/archive.asc" soon "$WORK/in" "$WORK/x1"
mkdir -p "$WORK/empty"
refuse "nothing to publish" "refusing to build an empty repository" "$WORK/archive.asc" "$FX_T1" "$WORK/empty" "$WORK/x2"
mkdir -p "$WORK/odd/p"; fx_rpm "$WORK/odd/p" podup 1.0.0 1.glyndor.el8 x86_64
refuse "a package for a distribution the channel does not serve" "which this channel does not serve" "$WORK/archive.asc" "$FX_T1" "$WORK/odd" "$WORK/x3"
mkdir -p "$WORK/odd2/p"; fx_rpm "$WORK/odd2/p" podup 1.0.0 3 x86_64
refuse "a release that names no distribution" "names no distribution" "$WORK/archive.asc" "$FX_T1" "$WORK/odd2" "$WORK/x4"
mkdir -p "$WORK/odd3/p" "$WORK/odd3/q"; fx_rpm "$WORK/odd3/p" podup 1.0.0 1.glyndor.any noarch; cp "$WORK/odd3/p"/*.rpm "$WORK/odd3/q"/
refuse "the same file from two products" "two products carry" "$WORK/archive.asc" "$FX_T1" "$WORK/odd3" "$WORK/x5"
mkdir -p "$WORK/odd4/p"; fx_rpm "$WORK/odd4/p" podup 1.0.0 1.glyndor.any ppc64le
refuse "an architecture the id does not serve" "does not serve" "$WORK/archive.asc" "$FX_T1" "$WORK/odd4" "$WORK/x6"
mkdir -p "$WORK/odd5/p"; fx_rpm "$WORK/odd5/p" podup 1.0.0 1.glyndor.any noarch; ln -s "$WORK/odd5/p/podup-1.0.0-1.glyndor.any.noarch.rpm" "$WORK/odd5/p/link.rpm"
refuse "a link in place of a package" "not a regular file" "$WORK/archive.asc" "$FX_T1" "$WORK/odd5" "$WORK/x7"
refuse "a missing argument" "usage" "$WORK/archive.asc" "$FX_T1" "$WORK/in"
refuse "an unknown option" "unknown option" --bogus "$WORK/archive.asc" "$FX_T1" "$WORK/in" "$WORK/x8"
refuse "a root that is not a directory" "is not a directory" "$WORK/archive.asc" "$FX_T1" "$WORK/none" "$WORK/x9"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
