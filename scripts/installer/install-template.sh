#!/bin/sh
# Installs @PRODUCT@ from the Glyndor rpm repository (@BASE_URL@).
#
#   curl -fsSL @BASE_URL@/install/@PRODUCT@ | sudo sh
#
# What it does, in order: refuses to run unprivileged or on a distribution the repository does not
# serve; downloads the repository's public key and checks that it is the one key with the fingerprint
# written below, before anything imports it; writes the repository file with signature checks on for
# the packages and for the metadata; imports the checked key; installs @PRODUCT@ with the system's
# package manager, which verifies every package against that key before rpm opens it. Nothing here
# runs a downloaded package itself. The manual way, step by step, is in the README of the repository.
set -eu

GLYNDOR_PRODUCT="@PRODUCT@"
GLYNDOR_BASE="@BASE_URL@"
GLYNDOR_TOOLS="gpg rpm curl"
GLYNDOR_FPR="@FPR@"
GLYNDOR_ROOT="${GLYNDOR_ROOT:-}"
GLYNDOR_KEY_FILE="$GLYNDOR_ROOT/etc/pki/rpm-gpg/RPM-GPG-KEY-glyndor"

glyndor_fail() { echo "install-$GLYNDOR_PRODUCT: $*" >&2; exit 1; }

# glyndor_id <os-release ID> <VERSION_ID>: the repository id of a distribution, or nothing
glyndor_id() {
	case "$1" in
		fedora) case "$2" in 44 | 45) echo "fc$2" ;; esac ;;
		rhel | almalinux | rocky | centos | ol) case "${2%%.*}" in 9 | 10) echo "el${2%%.*}" ;; esac ;;
		amzn) if [ "$2" = 2023 ]; then echo amzn2023; fi ;;
		opensuse-leap) if [ "$2" = 16.1 ]; then echo leap16.1; fi ;;
		opensuse-tumbleweed) echo tumbleweed ;;
	esac
}

# glyndor_check_key <file>: succeeds only for a file that holds one public key, with the fingerprint
# (never a secret key, never a second primary key beside it)
glyndor_check_key() {
	info="$(gpg --batch --show-keys --with-colons "$1" 2> /dev/null)" || return 1
	[ "$(printf '%s\n' "$info" | grep -c '^pub:')" -eq 1 ] || return 1
	[ "$(printf '%s\n' "$info" | grep -c '^sec:')" -eq 0 ] || return 1
	[ "$(printf '%s\n' "$info" | awk -F: '$1 == "fpr" { print $10; exit }')" = "$GLYNDOR_FPR" ]
}

# glyndor_check_repo <file>: succeeds only for a repository file made of the lines the channel gives out, so that a
# file that was altered on its way (or by whoever serves it) cannot add an option, another repository, a priority
# or a switch that turns a check off. The key line is not read: it is replaced by the key on the disk.
glyndor_check_repo() {
	seen=" "
	while IFS= read -r line || [ -n "$line" ]; do
		# shellcheck disable=SC2016 # $basearch is the literal text of the repository file
		case "$line" in
			"[glyndor]" | "name=Glyndor" | "type=rpm-md" | "enabled=1" | "autorefresh=1" | "gpgcheck=1" | "repo_gpgcheck=1" | "pkg_gpgcheck=1" | "skip_if_unavailable=1")
				seen="$seen$line " ;;
			"baseurl=$GLYNDOR_BASE/"*'/$basearch/')
				case "${line#baseurl=}" in *[!A-Za-z0-9._/:+\$-]* | *..*) return 1 ;; esac ;;
			"includepkgs="*) case "${line#includepkgs=}" in *[!a-z0-9\ ._+-]*) return 1 ;; esac ;;
			"gpgkey="*) ;;
			*) return 1 ;;
		esac
	done < "$1"
	for need in "[glyndor]" gpgcheck=1 repo_gpgcheck=1 pkg_gpgcheck=1; do
		case "$seen" in *" $need "*) ;; *) return 1 ;; esac
	done
}

# glyndor_repo_file <file>: the checked repository file with the key line pointing at the key on the disk, never at a URL
glyndor_repo_file() {
	grep -v '^gpgkey=' "$1"
	echo "gpgkey=file://$GLYNDOR_KEY_FILE"
}

glyndor_main() {
	[ "$(id -u)" -eq 0 ] || glyndor_fail "run it as root (curl -fsSL $GLYNDOR_BASE/install/$GLYNDOR_PRODUCT | sudo sh)"
	[ -r "${GLYNDOR_OS_RELEASE:-/etc/os-release}" ] || glyndor_fail "no /etc/os-release; this repository serves Fedora, the RHEL family, openSUSE and Amazon Linux"
	# shellcheck disable=SC1090
	. "${GLYNDOR_OS_RELEASE:-/etc/os-release}"
	id="$(glyndor_id "${ID:-}" "${VERSION_ID:-}")"
	[ -n "$id" ] || glyndor_fail "${PRETTY_NAME:-this system} is not served (Fedora 44 and 45, AlmaLinux, Rocky and RHEL 9 and 10, Amazon Linux 2023, openSUSE Leap 16.1 and Tumbleweed)"
	for tool in $GLYNDOR_TOOLS; do command -v "$tool" > /dev/null 2>&1 || glyndor_fail "$tool is needed and was not found"; done

	work="$(mktemp -d)"
	trap 'rm -rf "$work"' EXIT
	curl -fsSL --max-time 60 --connect-timeout 15 --proto '=https' --tlsv1.2 -o "$work/key.asc" "$GLYNDOR_BASE/glyndor-rpm-key.asc" \
		|| glyndor_fail "cannot download the repository key"
	glyndor_check_key "$work/key.asc" || glyndor_fail "the key at $GLYNDOR_BASE is not the one with fingerprint $GLYNDOR_FPR; nothing was installed"
	curl -fsSL --max-time 60 --connect-timeout 15 --proto '=https' --tlsv1.2 -o "$work/glyndor.repo" "$GLYNDOR_BASE/$id/glyndor.repo" \
		|| glyndor_fail "cannot download the repository file of $id"
	glyndor_check_repo "$work/glyndor.repo" || glyndor_fail "the repository file at $GLYNDOR_BASE/$id is not one the channel gives out; nothing was installed"
	install -D -m 644 "$work/key.asc" "$GLYNDOR_KEY_FILE"
	rpm --import "$GLYNDOR_KEY_FILE"

	case "$id" in
		leap16.1 | tumbleweed)
			install -d "$GLYNDOR_ROOT/etc/zypp/repos.d"
			glyndor_repo_file "$work/glyndor.repo" > "$GLYNDOR_ROOT/etc/zypp/repos.d/glyndor.repo"
			install -d "$GLYNDOR_ROOT/etc/zypp/vendors.d"
			printf '[main]\nvendors = suse,opensuse,glyndor\n' > "$GLYNDOR_ROOT/etc/zypp/vendors.d/glyndor"
			zypper --non-interactive refresh glyndor
			zypper --non-interactive install --allow-vendor-change "$GLYNDOR_PRODUCT"
			;;
		*)
			install -d "$GLYNDOR_ROOT/etc/yum.repos.d"
			glyndor_repo_file "$work/glyndor.repo" > "$GLYNDOR_ROOT/etc/yum.repos.d/glyndor.repo"
			dnf -y install "$GLYNDOR_PRODUCT"
			;;
	esac
	echo "$GLYNDOR_PRODUCT installed from $GLYNDOR_BASE/$id"
}

if [ -z "${GLYNDOR_INSTALL_SOURCED:-}" ]; then glyndor_main "$@"; fi
