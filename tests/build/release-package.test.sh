#!/usr/bin/env bash
#
# scripts/build/release-package.sh: the bootstrap package is the same bytes in any folder and on any run,
# carries the key and the repository file for its id, and refuses what it cannot build.
# Requires: rpm (rpm2archive), tar.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
RP="$HERE/scripts/build/release-package.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
echo 'a stand-in for a public key' > "$WORK/key.asc"
mkdir -p "$WORK/a" "$WORK/b/deeper"
"$RP" fc45 "$WORK/key.asc" "$WORK/a" > /dev/null 2>&1; check "the package is built" 0 "$?"
F="$WORK/a/glyndor-release-1-1.glyndor.fc45.noarch.rpm"
check "it has the name the repository serves" 1 "$([ -f "$F" ] && echo 1 || echo 0)"
sleep 1
"$RP" fc45 "$WORK/key.asc" "$WORK/b/deeper" > /dev/null 2>&1
check "built again, in another folder and a second later, it is the same file" "$(sha256sum < "$F")" "$(sha256sum < "$WORK/b/deeper/glyndor-release-1-1.glyndor.fc45.noarch.rpm")"
q() { rpm -qp --nomanifest --nosignature --qf "$1" "$F"; }
check "name, version, release, arch" "glyndor-release|1|1.glyndor.fc45|noarch" "$(q '%{NAME}|%{VERSION}|%{RELEASE}|%{ARCH}')"
check "vendor and packager" "Glyndor|Glyndor <noreply@glyndor.net>" "$(q '%{VENDOR}|%{PACKAGER}')"
check "package format 4" "4" "$(q '%{RPMFORMAT}')"
check "build time is the one of the config" "1795392000" "$(q '%{BUILDTIME}')"
check "it provides nothing but itself" "glyndor-release" "$(rpm -qp --nomanifest --provides "$F" | sed 's/ = .*//' | sort | tr '\n' ' ' | sed 's/ $//')"
check "and requires nothing but rpm's own" 0 "$(rpm -qp --nomanifest --requires "$F" | grep -vc '^rpmlib(')"
check "it holds the key and the dnf repository file" "/etc/pki/rpm-gpg/RPM-GPG-KEY-glyndor /etc/yum.repos.d/glyndor.repo" "$(rpm -qp --nomanifest -l "$F" | tr '\n' ' ' | sed 's/ $//')"
check "the key is the file it was given" 1 "$(fx_cat "$F" /etc/pki/rpm-gpg/RPM-GPG-KEY-glyndor | cmp -s - "$WORK/key.asc" && echo 1 || echo 0)"
check "the repository file reads the key from the disk" 1 "$(fx_cat "$F" /etc/yum.repos.d/glyndor.repo | grep -c '^gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-glyndor$')"
check "and is a configuration file that is not overwritten" 1 "$(rpm -qp --nomanifest --qf '[%{FILEFLAGS:fflags} %{FILENAMES}\n]' "$F" | grep -c 'cn.*glyndor.repo')"
mkdir "$WORK/z"; "$RP" leap16.1 "$WORK/key.asc" "$WORK/z" > /dev/null 2>&1
Z="$WORK/z/glyndor-release-1-1.glyndor.leap161.noarch.rpm"
check "for zypper it ships the repository file in the zypp folder and the vendor file" "/etc/pki/rpm-gpg/RPM-GPG-KEY-glyndor /etc/zypp/repos.d/glyndor.repo /etc/zypp/vendors.d/glyndor" "$(rpm -qp --nomanifest -l "$Z" | tr '\n' ' ' | sed 's/ $//')"
check "and the vendor file lists glyndor beside the distribution's" "[main]
vendors = suse,opensuse,glyndor" "$(fx_cat "$Z" /etc/zypp/vendors.d/glyndor)"
mkdir "$WORK/cfg"; cp "$HERE/config/"* "$WORK/cfg/"; sed -i 's/^release\t1$/release\t2/' "$WORK/cfg/glyndor-release.txt"; mkdir "$WORK/c2"
"$RP" --config "$WORK/cfg" fc45 "$WORK/key.asc" "$WORK/c2" > /dev/null 2>&1
check "raising the release in the config changes the name" 1 "$([ -f "$WORK/c2/glyndor-release-1-2.glyndor.fc45.noarch.rpm" ] && echo 1 || echo 0)"
sed -i 's/^epoch\t[0-9]*$/epoch\tsoon/' "$WORK/cfg/glyndor-release.txt"
check "a malformed config is refused" 1 "$("$RP" --config "$WORK/cfg" fc45 "$WORK/key.asc" "$WORK/c2" > /dev/null 2>&1; echo $?)"
check "an id that is not served is refused" 1 "$("$RP" ubuntu "$WORK/key.asc" "$WORK/a" > /dev/null 2>&1; echo $?)"
check "a key that is not there is refused" 1 "$("$RP" fc45 "$WORK/none" "$WORK/a" > /dev/null 2>&1; echo $?)"
check "too few arguments are refused" 1 "$("$RP" fc45 > /dev/null 2>&1; echo $?)"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
