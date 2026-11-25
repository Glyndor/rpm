#!/usr/bin/env bash
#
# What each entry of a package and each scriptlet may be, read from the signed bytes: the interpreters of the
# scriptlets (an array, of which only /bin/sh alone is accepted), a hash of the scriptlets that cannot read one way for
# two packages, and the kind of every file (no device, pipe or socket, no set-id bit, no capability, and a link only
# where its own kind may install and to a place its kind may install).
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
SRC="podup-1.2.3-1.glyndor.any.x86_64.rpm"
fx_static_release "$WORK/base" podup 1.2.3 x86_64,aarch64
fx_podman_release "$WORK/podman" 6.2.0 12
PF="podman-6.2.0+r12-12.glyndor.el9.x86_64.rpm"
DF="podman-docker-6.2.0+r12-12.glyndor.el9.noarch.rpm"
P=(podup 1.2.3 1.glyndor.any x86_64)

variant() { # <release dir> <file the contract expects> <package fields...>
	local dir="$1" file="$2"; shift 2
	rm -rf "$WORK/v"; cp -r "$dir" "$WORK/v"; mkdir -p "$WORK/mk"; rm -f "${WORK:?}/mk"/*
	fx_rpm "$WORK/mk" "$@" || return 1
	rm -f "$WORK/v/$file" "$WORK/v/$file.sig"; mv "$WORK/mk"/*.rpm "$WORK/v/$file"; fx_sign "$WORK/v/$file"
}
run() { # <product> <tag>
	rc=0; out="$("$ADMIT" --keyring "$WORK/keyring" "$1" "$2" "$WORK/v" 2>&1)" || rc=$?
}
refused() { # <description> <product> <tag> <fragment>
	run "$2" "$3"; check "$1: refused" 1 "$rc"; check "$1: says why" 1 "$(printf '%s' "$out" | grep -cF -- "$4")"
}
accepted() { run "$2" "$3"; check "$1: admitted" 0 "$rc"; }
hash_of() { printf '%s' "$out" | grep -oE 'sha256 [0-9a-f]{64}' | head -1 | cut -d' ' -f2; }

# --- the interpreter of a scriptlet ----------------------------------------------------------------------
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup post=true postprog="/bin/sh"
run podup v1.2.3; check "a %post run by /bin/sh reaches the list of scriptlets, which has none for this kind" 1 "$rc"
check "and the refusal is the one of the list, with a hash" 1 "$(printf '%s' "$out" | grep -c 'config/scriptlets.txt does not list')"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup post=true postprog="'/bin/sh -c true'"
refused "a %post whose interpreter has arguments" podup v1.2.3 "/bin/sh"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup post=true postprog="/usr/bin/python3"
refused "a %post run by another interpreter" podup v1.2.3 "interpreter"

# --- the hash of the scriptlets ----------------------------------------------------------------------------
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup pre="aa" post="bbcc"; run podup v1.2.3; h1="$(hash_of)"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup pre="aabb" post="cc"; run podup v1.2.3; h2="$(hash_of)"
check "the same text split another way between %pre and %post gives another hash" 1 "$([ -n "$h1" ] && [ -n "$h2" ] && [ "$h1" != "$h2" ] && echo 1 || echo 0)"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup post="aabb"; run podup v1.2.3; h3="$(hash_of)"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup preun="aabb"; run podup v1.2.3; h4="$(hash_of)"
check "the same text in %post and in %preun gives another hash" 1 "$([ -n "$h3" ] && [ "$h3" != "$h4" ] && echo 1 || echo 0)"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup post="aabb"; run podup v1.2.3; h5="$(hash_of)"
check "the same package gives the same hash twice" "$h3" "$h5"

# --- the kind of each entry --------------------------------------------------------------------------------
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup attr=0755:/usr/bin/podup
accepted "a plain executable" podup v1.2.3
for m in 0777 0775 0666 0757 0772; do
	variant "$WORK/base" "$SRC" "${P[@]}" provides=podup attr=$m:/usr/bin/podup
	refused "an executable with the mode $m, which its group or others can replace" podup v1.2.3 "that its group or others can write"
done
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup attr=0555:/usr/bin/podup
accepted "an executable with the mode 0555" podup v1.2.3
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup attr=0644:/usr/lib/podup/data
accepted "a data file with the mode 0644" podup v1.2.3
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup dirattr=0775:/usr/lib/podup/d
refused "a folder its group can write" podup v1.2.3 "that its group or others can write"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup dirattr=1777:/usr/lib/podup/d
refused "a sticky folder anyone can write" podup v1.2.3 "that its group or others can write"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup dirattr=0755:/usr/lib/podup/d
accepted "a folder with the mode 0755" podup v1.2.3
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup attr=4755:/usr/bin/podup
refused "a setuid executable" podup v1.2.3 "set-id bit"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup attr=2755:/usr/bin/podup
refused "a setgid executable" podup v1.2.3 "set-id bit"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup dev=/usr/lib/podup/null
refused "a device" podup v1.2.3 "a device, a pipe or a socket"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup symlink=/usr/lib/podup/l:/etc/shadow
refused "a link under a place whose rule admits children" podup v1.2.3 "where its kind may install files under it"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup symlink=/usr/bin/podup:/etc/shadow
refused "a link to a place the kind may not install" podup v1.2.3 "which its kind may not install"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup symlink=/usr/bin/podup:../../../../etc/shadow
refused "a link that climbs out of the root" podup v1.2.3 "leaves the root"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup symlink=/usr/bin/podup:../lib/podup/bin
accepted "a link at a place with no children, to a place its kind installs" podup v1.2.3
# the podman kinds: podman-remote points at podman; podmansh and docker are the listed links of the companion
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman symlink=/usr/bin/podman-remote:podman
accepted "podman-remote as a link to podman" podman v6.2.0+r12
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman symlink=/usr/libexec/podman/netavark:/etc/passwd
refused "a link inside /usr/libexec/podman" podman v6.2.0+r12 "where its kind may install files under it"
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman attr=0755:/usr/libexec/podman/netavark
accepted "an executable under /usr/libexec/podman" podman v6.2.0+r12
variant "$WORK/podman" "$DF" podman-docker 6.2.0+r12 12.glyndor.el9 noarch epoch=6 provides=podman-docker symlink=/usr/bin/docker:podman
accepted "docker as the listed link to podman" podman v6.2.0+r12
variant "$WORK/podman" "$DF" podman-docker 6.2.0+r12 12.glyndor.el9 noarch epoch=6 provides=podman-docker symlink=/usr/bin/docker:/usr/bin/bash
refused "docker as a link to something else" podman v6.2.0+r12 "which its kind may not install"

# --- who owns what: root, unless a line of config/owners.txt says otherwise, and never under /usr -----------------
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup owner=nobody:nobody:/var/lib/podup/state
refused "a file of the account nobody, with no line that lists it" podup v1.2.3 "owned by 'nobody:nobody'"
rm -rf "$WORK/cfgo"; mkdir "$WORK/cfgo"; cp "$HERE/config/"* "$WORK/cfgo/"
printf 'static\t/var/lib/NAME(/.*)?\tnobody:nobody\n' >> "$WORK/cfgo/owners.txt"
run_cfg() { rc=0; out="$("$ADMIT" --config "$WORK/cfgo" --keyring "$WORK/keyring" "$1" "$2" "$WORK/v" 2>&1)" || rc=$?; }
run_cfg podup v1.2.3; check "the same file, with a line that lists the path and the account, is admitted" 0 "$rc"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup owner=daemon:daemon:/var/lib/podup/state
run_cfg podup v1.2.3; check "another account than the one listed is refused" 1 "$rc"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup owner=nobody:nobody:/usr/lib/podup/data
printf 'static\t/usr/lib/NAME(/.*)?\tnobody:nobody\n' >> "$WORK/cfgo/owners.txt"
run_cfg podup v1.2.3; check "a file under /usr owned by someone else is refused even when a line lists it" 1 "$rc"
check "and says it is not root's" 1 "$(printf '%s' "$out" | grep -c "owned by 'nobody:nobody'")"

# --- rich dependencies ---------------------------------------------------------------------------------------------
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup "requires=(curl if bash);"
refused "a rich dependency in a static product" podup v1.2.3 "is a rich dependency that config/rich-dependencies.txt does not list"
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman "requires=(container-selinux if selinux-policy);"
accepted "the exact condition of the contract in podman" podman v6.2.0+r12
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman "requires=(evil if selinux-policy);"
refused "another condition in podman" podman v6.2.0+r12 "is a rich dependency that config/rich-dependencies.txt does not list"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
