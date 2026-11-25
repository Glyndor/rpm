#!/usr/bin/env bash
#
# Build glyndor-release for one distribution id: the key and the repository file, as an rpm.
#
# Usage: release-package.sh [--config <dir>] <id> <public-key.asc> <out-dir>
#
# Writes <out-dir>/glyndor-release-1-<release>.glyndor.<suffix>.noarch.rpm, unsigned (sign-packages.sh signs it
# with everything else). The same inputs give the same bytes in any folder and any day: the build time, the
# file times and the build host are fixed, and the package format is 4.
# Requires: rpmbuild.
set -euo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_DIR="$HERE/config"
die() { echo "::error::release-package: $*" >&2; exit 1; }
if [ "${1:-}" = --config ]; then CONFIG_DIR="${2:?--config needs a directory}"; shift 2; fi
[ "$#" -eq 3 ] || die "usage: release-package.sh [--config <dir>] <id> <public-key.asc> <out-dir>"
ID="$1"; PUB="$2"; OUT="$3"
if [ ! -f "$PUB" ] || [ ! -d "$OUT" ]; then die "$PUB is not a file or $OUT is not a directory"; fi
suffix=""; client=""
while IFS=$'\t' read -r id sfx _archs cl _form; do
	if [ "$id" = "$ID" ]; then suffix="$sfx"; client="$cl"; fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONFIG_DIR/distros.txt")
[ -n "$suffix" ] || die "$ID is not a distribution of config/distros.txt"
number="$(awk -F'\t' '$1 == "release" { print $2 }' "$CONFIG_DIR/glyndor-release.txt")"
epoch="$(awk -F'\t' '$1 == "epoch" { print $2 }' "$CONFIG_DIR/glyndor-release.txt")"
[[ "$number" =~ ^[0-9]+$ && "$epoch" =~ ^[0-9]{9,11}$ ]] || die "config/glyndor-release.txt is malformed"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
case "$client" in
	zypper) repodir=/etc/zypp/repos.d ;;
	*) repodir=/etc/yum.repos.d ;;
esac
mkdir -p "$WORK/src"
cp "$PUB" "$WORK/src/key.asc"
"$HERE/scripts/build/repo-file.sh" --config "$CONFIG_DIR" "$ID" "${REPO_BASE_URL:-https://rpm.glyndor.net}" \
	"file:///etc/pki/rpm-gpg/RPM-GPG-KEY-glyndor" > "$WORK/src/glyndor.repo"
if [ "$client" = zypper ]; then printf '[main]\nvendors = suse,opensuse,glyndor\n' > "$WORK/src/vendor"; fi
find "$WORK/src" -type f -exec touch -d "@$epoch" {} +
{
	cat <<SPEC
Name: glyndor-release
Version: 1
Release: $number.glyndor.$suffix
Summary: Glyndor repository key and configuration
License: MIT
Vendor: Glyndor
Packager: Glyndor <noreply@glyndor.net>
URL: https://rpm.glyndor.net
BuildArch: noarch
AutoReqProv: no
%description
The key the Glyndor repository is signed with and the repository file that names it.
%install
install -D -m 644 $WORK/src/key.asc %{buildroot}/etc/pki/rpm-gpg/RPM-GPG-KEY-glyndor
install -D -m 644 $WORK/src/glyndor.repo %{buildroot}$repodir/glyndor.repo
SPEC
	[ "$client" != zypper ] || echo "install -D -m 644 $WORK/src/vendor %{buildroot}/etc/zypp/vendors.d/glyndor"
	printf '%%files\n/etc/pki/rpm-gpg/RPM-GPG-KEY-glyndor\n%%config(noreplace) %s/glyndor.repo\n' "$repodir"
	[ "$client" != zypper ] || echo "%config(noreplace) /etc/zypp/vendors.d/glyndor"
} > "$WORK/p.spec"
mkdir -p "$WORK/top"/{BUILD,RPMS,SRPMS,SOURCES,SPECS}
SOURCE_DATE_EPOCH="$epoch" rpmbuild --define "_topdir $WORK/top" --define '_rpmformat 4' --define '_build_name_fmt %{NAME}.rpm' \
	--define 'use_source_date_epoch_as_buildtime 1' --define 'clamp_mtime_to_source_date_epoch 1' --define '_buildhost glyndor' \
	--define 'source_date_epoch_from_changelog 0' --define '_binary_payload w9.gzdio' --target noarch-linux -bb "$WORK/p.spec" > "$WORK/log" 2>&1 \
	|| { cat "$WORK/log" >&2; die "rpmbuild failed"; }
built="$(find "$WORK/top/RPMS" -name '*.rpm')"
mv "$built" "$OUT/glyndor-release-1-$number.glyndor.$suffix.noarch.rpm"
