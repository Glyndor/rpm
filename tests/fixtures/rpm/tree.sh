#!/usr/bin/env bash
# Helpers for the tests that build a repository tree. Sourced after lib.sh. The archive key is made
# at a fixed time in the past, so the signing times the tests use (FX_T1, FX_T2) come after it and
# before now, and rpm and gpg accept the signatures.
# shellcheck disable=SC2034 # read by the tests that source this file
FX_T0=1790000000
# shellcheck disable=SC2034
FX_T1=1790000100
# shellcheck disable=SC2034
FX_T2=1790000200

fx_archive_key() { # makes $FX_WORK/gnupg with one Ed25519 key and exports it to $FX_WORK/archive.asc
	GNUPGHOME="$FX_WORK/gnupg"; export GNUPGHOME
	mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
	gpg --batch --pinentry-mode loopback --passphrase '' --faked-system-time "$FX_T0!" \
		--quick-gen-key 'Test archive <archive@example.invalid>' ed25519 sign never > /dev/null 2>&1
	gpg --batch --armor --export > "$FX_WORK/archive.asc"
}

fx_stop_agent() {
	local d="${GNUPGHOME:-}"
	[ -n "$d" ] || return 0
	# The agent of the temporary keyring is closed before its folder goes, and its socket folder with it.
	timeout 10 gpgconf --homedir "$d" --kill all > /dev/null 2>&1 || true
	gpgconf --homedir "$d" --remove-socketdir > /dev/null 2>&1 || true
}

# fx_admitted <root>: root/podup (static, two architectures), root/epistle-panel (noarch) and
# root/podman with the whole set, as the admission would have let them in
fx_admitted() {
	local root="$1"
	fx_static_release "$root/podup" podup 1.2.3 x86_64,aarch64
	fx_static_release "$root/epistle-panel" epistle-panel 0.9.1 noarch
	fx_podman_release "$root/podman" 6.2.0 12
	rm -f "$root"/*/*.sig
}

fx_build_tree() { # <out> <epoch> <root>
	"$FX_REPO/scripts/build/build-repo.sh" "$FX_WORK/archive.asc" "$2" "$3" "$1"
}

fx_other_key() { # <file>: the public key of a second key, to stand for "another key"
	local h="$FX_WORK/gother"
	mkdir -p "$h"; chmod 700 "$h"
	GNUPGHOME="$h" gpg --batch --pinentry-mode loopback --passphrase '' --faked-system-time "$FX_T0!" \
		--quick-gen-key 'Other <other@example.invalid>' ed25519 sign never > /dev/null 2>&1
	GNUPGHOME="$h" gpg --batch --armor --export > "$1"
	# The agent of the temporary keyring is closed before its folder goes, and its socket folder with it.
	timeout 10 gpgconf --homedir "$h" --kill all > /dev/null 2>&1 || true
	gpgconf --homedir "$h" --remove-socketdir > /dev/null 2>&1 || true
}
