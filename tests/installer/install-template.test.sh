#!/usr/bin/env bash
#
# The installer a product is given at /install/<product>: which distribution ids it maps, that it
# imports only a key with the fingerprint written in it, that it fails before touching the system when
# something is off, and the exact commands it runs on dnf and on zypper, with the system's own tools
# replaced by stand-ins that record what they are asked to do.
# Requires: gpg, rpm (for the key fixtures), python3 with cryptography.
# shellcheck disable=SC2016 # the patterns are literal text of the repository file
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
fx_init "$WORK"; fx_archive_key; fx_other_key "$WORK/other.asc"
"$HERE/scripts/build/build-installers.sh" "$WORK/archive.asc" "$WORK/inst" podup > /dev/null 2>&1
INST="$WORK/inst/podup"
FPR="$(gpg --batch --show-keys --with-colons "$WORK/archive.asc" | awk -F: '$1 == "fpr" { print $10; exit }')"

# --- the pieces ---------------------------------------------------------------------------------------
# shellcheck disable=SC1090
GLYNDOR_INSTALL_SOURCED=1 . "$INST"
set +e # the installer turns it on for itself
idof() { glyndor_id "$1" "$2"; }
while read -r osid ver want; do
	check "$osid $ver is '${want:--}'" "${want:-}" "$(idof "$osid" "$ver")"
done <<'TABLE'
fedora 45 fc45
fedora 44 fc44
fedora 43
fedora 46
rhel 9.4 el9
rhel 10.1 el10
almalinux 9.9 el9
almalinux 10.3 el10
rocky 9.9 el9
rocky 10.3 el10
centos 9 el9
rhel 8.10
rhel 11
amzn 2023 amzn2023
amzn 2
opensuse-leap 16.1 leap16.1
opensuse-leap 15.6
opensuse-leap 16.0
opensuse-tumbleweed 20261120 tumbleweed
ubuntu 26.04
debian 13
arch
TABLE
check "an empty id maps to nothing" "" "$(idof '' '')"

gk() { glyndor_check_key "$1" && echo yes || echo no; }
check "the committed key passes" yes "$(gk "$WORK/archive.asc")"
check "another key is refused" no "$(gk "$WORK/other.asc")"
cat "$WORK/archive.asc" "$WORK/other.asc" > "$WORK/two.asc"
check "a file with the right key and another beside it is refused" no "$(gk "$WORK/two.asc")"
cat "$WORK/other.asc" "$WORK/archive.asc" > "$WORK/two2.asc"
check "in either order" no "$(gk "$WORK/two2.asc")"
printf 'not a key\n' > "$WORK/junk.asc"
check "text that is not a key is refused" no "$(gk "$WORK/junk.asc")"
: > "$WORK/empty.asc"
check "an empty file is refused" no "$(gk "$WORK/empty.asc")"
check "a file that is not there is refused" no "$(gk "$WORK/none.asc")"
gpg --batch --armor --export-secret-keys > "$WORK/secret.asc" 2> /dev/null
check "a block with the secret key is refused" no "$(gk "$WORK/secret.asc")"
check "the installer is the file build-installers wrote, with the fingerprint in it" 1 "$(grep -c "GLYNDOR_FPR=\"$FPR\"" "$INST")"
check "no placeholder is left" 0 "$(grep -c '@[A-Z_]*@' "$INST")"
check "the product is in the script" 1 "$(grep -c 'GLYNDOR_PRODUCT="podup"' "$INST")"

# --- the whole run, with stand-ins ----------------------------------------------------------------------
mkdir -p "$WORK/bin"
for tool in dnf zypper rpm; do
	# shellcheck disable=SC2016 # the stand-in expands its own variables when it runs
	printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >> "$FAKE_LOG"\n' "$tool" > "$WORK/bin/$tool"
done
# shellcheck disable=SC2016 # the stand-in expands its own variables when it runs
printf '#!/bin/sh\nif [ "$1" = -u ]; then echo "${FAKE_UID:-0}"; else /usr/bin/id "$@"; fi\n' > "$WORK/bin/id"
# curl: writes the key to the -o file and records that it was asked for over https with a deadline
cat > "$WORK/bin/curl" <<'SH'
#!/bin/sh
printf 'curl %s\n' "$*" >> "$FAKE_LOG"
url=""; out=""
while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then out="$2"; fi; url="$1"; shift; done
case "$url" in */glyndor.repo) cp "$FAKE_REPO" "$out" ;; *) cp "$FAKE_KEY" "$out" ;; esac
SH
chmod +x "$WORK"/bin/*
REPOS="$WORK/repos"; mkdir -p "$REPOS"
for rid in fc45 el9 amzn2023 leap16.1 tumbleweed; do
	"$HERE/scripts/build/repo-file.sh" "$rid" https://rpm.glyndor.net https://rpm.glyndor.net/glyndor-rpm-key.asc > "$REPOS/$rid.repo"
done
run() { # <os id> <version> [key file] [repository file]: runs the installer in a scratch root; prints its exit status
	local root="$WORK/root-$1-$2" repo="${4:-}"
	if [ -z "$repo" ]; then
		case "$1-$2" in fedora-4*) repo="$REPOS/fc${2}.repo" ;; rocky-*|almalinux-*|rhel-*) repo="$REPOS/el${2%%.*}.repo" ;; amzn-*) repo="$REPOS/amzn2023.repo" ;; opensuse-leap-*) repo="$REPOS/leap16.1.repo" ;; *) repo="$REPOS/tumbleweed.repo" ;; esac
	fi
	rm -rf "$root"; mkdir -p "$root"
	printf 'ID=%s\nVERSION_ID="%s"\nPRETTY_NAME="Test"\n' "$1" "$2" > "$root/os-release"
	: > "$WORK/log"
	GLYNDOR_ROOT="$root" GLYNDOR_OS_RELEASE="$root/os-release" FAKE_LOG="$WORK/log" FAKE_KEY="${3:-$WORK/archive.asc}" FAKE_REPO="$repo" \
		PATH="$WORK/bin:$PATH" sh "$INST" > "$WORK/out" 2>&1
	echo $?
}
check "Fedora 45 installs" 0 "$(run fedora 45)"
R="$WORK/root-fedora-45"
check "the key was asked for over https, with deadlines" 1 "$(grep -c "^curl .*--max-time 60 .*--proto =https .*/glyndor-rpm-key.asc" "$WORK/log")"
check "the checked key is installed for rpm" 1 "$([ -f "$R/etc/pki/rpm-gpg/RPM-GPG-KEY-glyndor" ] && cmp -s "$WORK/archive.asc" "$R/etc/pki/rpm-gpg/RPM-GPG-KEY-glyndor" && echo 1 || echo 0)"
check "rpm imports it" 1 "$(grep -c "^rpm --import $R/etc/pki/rpm-gpg/RPM-GPG-KEY-glyndor" "$WORK/log")"
check "the import comes before the install" "rpm dnf" "$(grep -E '^(rpm|dnf)' "$WORK/log" | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
check "dnf installs the product, unattended" 1 "$(grep -c '^dnf -y install podup$' "$WORK/log")"
check "the repository file is the one the channel serves, but for the key line, which names the key on disk" "$(grep -v '^gpgkey=' "$REPOS/fc45.repo")
gpgkey=file://$R/etc/pki/rpm-gpg/RPM-GPG-KEY-glyndor" "$(cat "$R/etc/yum.repos.d/glyndor.repo")"
check "no URL is left in a file the installer writes for the key" 0 "$(grep -c '^gpgkey=https' "$R/etc/yum.repos.d/glyndor.repo")"
check "the repository file was downloaded from the folder of the id, over https" 1 "$(grep -c '^curl .*--proto =https .*/fc45/glyndor.repo$' "$WORK/log")"
check "Rocky 9.9 gets el9" 1 "$(run rocky 9.9 > /dev/null; grep -c '/el9/' "$WORK/root-rocky-9.9/etc/yum.repos.d/glyndor.repo")"
check "Amazon Linux 2023 installs" 0 "$(run amzn 2023)"
check "Leap 16.1 installs" 0 "$(run opensuse-leap 16.1)"
L="$WORK/root-opensuse-leap-16.1"
check "zypper refreshes, then installs with vendor change allowed" "zypper --non-interactive refresh glyndor zypper --non-interactive install --allow-vendor-change podup" \
	"$(grep '^zypper' "$WORK/log" | tr '\n' ' ' | sed 's/ $//')"
check "the vendor file lists glyndor" "[main]
vendors = suse,opensuse,glyndor" "$(cat "$L/etc/zypp/vendors.d/glyndor")"
# shellcheck disable=SC2016 # the pattern is literal text of the repository file
check "the repository file is in the zypper folder" 1 "$(grep -c '/leap$releasever/' "$L/etc/zypp/repos.d/glyndor.repo")"
check "Tumbleweed installs" 0 "$(run opensuse-tumbleweed 20261120)"

# --- what stops it before the system is touched ------------------------------------------------------------
check "another key at the same URL stops it" 1 "$(run fedora 45 "$WORK/other.asc")"
check "and nothing was imported or installed" 0 "$(grep -c -E '^(rpm|dnf|zypper)' "$WORK/log")"
check "and no repository file was written" 0 "$(find "$WORK/root-fedora-45/etc/yum.repos.d" -type f 2> /dev/null | wc -l)"
check "and it says which fingerprint it wanted" 1 "$(grep -c "$FPR" "$WORK/out")"
check "two keys at the URL stop it" 1 "$(run fedora 45 "$WORK/two.asc")"
check "a page that is not a key stops it" 1 "$(run fedora 45 "$WORK/junk.asc")"
check "an unsupported release stops it" 1 "$(run fedora 43)"
check "and says what is served" 1 "$(grep -c 'is not served' "$WORK/out")"
check "and runs nothing" 0 "$(grep -c -E '^(curl|rpm|dnf|zypper)' "$WORK/log")"
check "Ubuntu is not served" 1 "$(run ubuntu 26.04)"
# a repository file that the channel did not give out is refused before the system is touched
badrepo() { # <description> <sed expression or "append: line">
	cp "$REPOS/fc45.repo" "$WORK/bad.repo"
	case "$2" in append:*) printf '%s\n' "${2#append:}" >> "$WORK/bad.repo" ;; *) sed -i "$2" "$WORK/bad.repo" ;; esac
	check "a repository file with $1 is refused" 1 "$(run fedora 45 "$WORK/archive.asc" "$WORK/bad.repo")"
	check "and nothing is imported or installed ($1)" 0 "$(grep -c -E '^(rpm|dnf|zypper)' "$WORK/log")"
}
badrepo "a priority" "append:priority=1"
badrepo "an exclude" "append:exclude=bash"
badrepo "a second repository" "append:[evil]"
badrepo "gpgcheck off" 's/^gpgcheck=1/gpgcheck=0/'
badrepo "the repository check off" 's/^repo_gpgcheck=1/repo_gpgcheck=0/'
badrepo "no repository check at all" '/^repo_gpgcheck/d'
badrepo "no package check" '/^pkg_gpgcheck/d'
badrepo "another host in the address" 's#https://rpm.glyndor.net/#https://evil.example/#'
badrepo "a path that climbs" 's#/fc$releasever/#/../x/#'
badrepo "a package name with a shell character" 's/^includepkgs=.*/includepkgs=podup;rm/'
badrepo "a command in an option" "append:baseurl=https://rpm.glyndor.net/\$(id)/\$basearch/"
check "a repository file with no gpgkey line gets the key on disk" 0 "$(grep -v '^gpgkey=' "$REPOS/fc45.repo" > "$WORK/nokey.repo"; run fedora 45 "$WORK/archive.asc" "$WORK/nokey.repo")"
check "a non root user is refused" 1 "$(FAKE_UID=1000 run fedora 45)"
check "and told how to run it" 1 "$(grep -c 'run it as root' "$WORK/out")"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
