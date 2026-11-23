#!/usr/bin/env bash
#
# The package kind `service`: a product that installs a systemd unit (epistle, when it ships one; no product is one yet,
# so the cases run on a copy of the config that makes epistle a service). Without scriptlets, removing the package leaves
# the process running with no binary, so the kind must carry exactly the expansion of the three systemd macros
# (%systemd_post, %systemd_preun, %systemd_postun_with_restart) as the text the channel lists, no other scriptlet, and a
# closed list of Requires with their versions.
# Requires: rpm (rpmbuild), python3 with cryptography.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
ADMIT="$HERE/scripts/verify/admit-release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
fx_init "$WORK"
N=epistle
fx_static_release "$WORK/base" "$N" 0.4.0 x86_64,aarch64

# The config of this run: epistle is a service with a closed list of Requires, and no text of scriptlets is listed yet.
rm -rf "$WORK/cfg0"; mkdir "$WORK/cfg0"; cp "$HERE/config/"* "$WORK/cfg0/"
sed -i 's/^epistle\tstatic\t/epistle\tservice\t/' "$WORK/cfg0/products.txt"
printf 'epistle\tpodman|>=|6.2.0\nepistle\tpodup|>=|6.0.0\nepistle\tnftables||\nepistle\tca-certificates||\n' >> "$WORK/cfg0/service-requires.txt"
check "the copy of the config makes epistle a service" 1 "$(grep -c '^epistle	service	' "$WORK/cfg0/products.txt")"

# The expansion of the three macros for the unit, as measured on the family of Fedora, EL and Amazon Linux; each text
# starts with the blank line rpm writes.
POST=$'\nif [ $1 -eq 1 ] && [ -x "/usr/lib/systemd/systemd-update-helper" ]; then\n    # Initial installation\n    /usr/lib/systemd/systemd-update-helper install-system-units epistle.service || :\nfi'
PREUN=$'\nif [ $1 -eq 0 ] && [ -x "/usr/lib/systemd/systemd-update-helper" ]; then\n    # Package removal, not upgrade\n    /usr/lib/systemd/systemd-update-helper remove-system-units epistle.service || :\nfi'
POSTUN=$'\nif [ $1 -ge 1 ] && [ -x "/usr/lib/systemd/systemd-update-helper" ]; then\n    # Package upgrade, not uninstall\n    /usr/lib/systemd/systemd-update-helper mark-restart-system-units epistle.service || :\nfi'
REQ="podman >= 6.2.0;podup >= 6.0.0;nftables;ca-certificates;systemd"

# svc <extra fields>: replaces the packages of $WORK/base by a service with the given scriptlets and requirements
svc() {
	local arch f
	rm -rf "$WORK/v"; cp -r "$WORK/base" "$WORK/v"; mkdir -p "$WORK/mk"; rm -f "${WORK:?}/mk"/*
	for arch in x86_64 aarch64; do
		f="$N-0.4.0-1.glyndor.any.$arch.rpm"
		fx_rpm "$WORK/mk" "$N" 0.4.0 1.glyndor.any "$arch" provides="$N" "$@" || return 1
		rm -f "$WORK/v/$f" "$WORK/v/$f.sig"; mv "$WORK/mk/$f" "$WORK/v/$f"; fx_sign "$WORK/v/$f"
	done
}
run() { # [config dir] -> $out, $rc
	rc=0; out="$("$ADMIT" --config "${1:-$WORK/cfg}" --keyring "$WORK/keyring" "$N" v0.4.0 "$WORK/v" 2>&1)" || rc=$?
}
verdict() { # <description> <fragment>: refused with that reason, on the config that lists the text
	run; check "$1: refused" 1 "$rc"; check "$1: says why" 1 "$(printf '%s' "$out" | grep -cF -- "$2")"
}

# a person reads the text the first package prints and lists its hash
svc post="$POST" preun="$PREUN" postun="$POSTUN" requires="$REQ"
run "$WORK/cfg0"; check "the exact macros are refused while no person has listed their text" 1 "$rc"
sum="$(printf '%s' "$out" | grep -oE 'sha256 [0-9a-f]{64}' | head -1 | cut -d' ' -f2)"
check "the refusal prints the hash and the key service:epistle" 1 "$(printf '%s' "$out" | grep -cF "for 'service:epistle'")"
rm -rf "$WORK/cfg"; cp -r "$WORK/cfg0" "$WORK/cfg"; printf 'service:epistle\t%s\n' "$sum" >> "$WORK/cfg/scriptlets.txt"
run; check "with the hash listed the exact package, with the exact Requires, is admitted" 0 "$rc"
check "the committed config lists no service text: no product has one yet" 0 "$(grep -c '^service:' "$HERE/config/scriptlets.txt")"

svc post="$POST" preun="$PREUN" postun="${POSTUN/mark-restart-system-units/restart}" requires="$REQ"
verdict "a postun that does something else" "does not list for 'service:epistle'"
svc post="$POST" preun="$PREUN" postun="$POSTUN" requires="$REQ" pretrans=true
verdict "a service with a %pretrans besides the macros" "may carry only"
svc preun="$PREUN" postun="$POSTUN" requires="$REQ"
verdict "a service that forgets the %post" "does not list for 'service:epistle'"
svc requires="$REQ"
verdict "a service with no scriptlet at all" "carries no scriptlet"
svc post="$POST" preun="$PREUN" postun="$POSTUN" requires="$REQ;curl"
verdict "a Requires that is not in the closed list" "curl|"
svc post="$POST" preun="$PREUN" postun="$POSTUN" requires="${REQ/podman >= 6.2.0/podman >= 6.0.0}"
verdict "the right name with another version" "podman|>=|6.0.0"
svc post="$POST" preun="$PREUN" postun="$POSTUN" requires="${REQ/podman >= 6.2.0/podman}"
verdict "the right name with no version" "podman||"
svc post="$POST" preun="$PREUN" postun="$POSTUN" requires="$REQ" recommends=certbot
verdict "a Recommends" "which is not a name"
svc post="$POST" preun="$PREUN" postun="$POSTUN" requires="$REQ" file=/etc/cron.d/epistle
verdict "a file outside the paths of a service" "not an install path"

# the same scriptlets under a static product are refused, even when their hash is listed for the service
rm -rf "$WORK/v"; cp -r "$WORK/base" "$WORK/v"; mkdir -p "$WORK/mk"; rm -f "${WORK:?}/mk"/*
for arch in x86_64 aarch64; do
	f="$N-0.4.0-1.glyndor.any.$arch.rpm"
	fx_rpm "$WORK/mk" "$N" 0.4.0 1.glyndor.any "$arch" provides="$N" post="$POST" preun="$PREUN" postun="$POSTUN" || exit 1
	rm -f "$WORK/v/$f" "$WORK/v/$f.sig"; mv "$WORK/mk/$f" "$WORK/v/$f"; fx_sign "$WORK/v/$f"
done
rc=0; out="$("$ADMIT" --config "$HERE/config" --keyring "$WORK/keyring" "$N" v0.4.0 "$WORK/v" 2>&1)" || rc=$?
check "the same scriptlets under a static product (the config of the repository) are refused" 1 "$rc"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
