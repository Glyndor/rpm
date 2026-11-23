#!/usr/bin/env bash
#
# scripts/verify/admit-lib.sh, the functions the admission reads a package with, each on its own: the form of a path, a link
# resolved by its text, and the rule of a relation.
# Requires: bash.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC2034 # read by the library
CONFIG_DIR="$HERE/config"; PRODUCT=podup; WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
die() { echo "die: $*" >&2; exit 1; }
rows() { grep -vE '^[[:space:]]*(#|$)' "$1" || true; }
escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/scripts/verify/admit-lib.sh"
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
check "/bin is read as /usr/bin" "/usr/bin/podup" "$(canon_of /bin/podup)"
check "/lib64 is read as /usr/lib64" "/usr/lib64/podup/x" "$(canon_of /lib64/podup/x)"
check "another path stays as it is" "/etc/podup/a" "$(canon_of /etc/podup/a)"
check "a link is resolved against its folder" "/usr/lib/podup/bin" "$(resolve_lexical /usr/bin ../lib/podup/bin)"
check "an absolute target is taken as it is" "/usr/bin/podman" "$(resolve_lexical /usr/bin /usr/bin/podman)"
check "a target that climbs out of the root is nothing" "none" "$(resolve_lexical /usr/bin ../../../etc/passwd > /dev/null && echo some || echo none)"
check "a plain Requires of a static product is allowed" 0 "$(relation_ok static requires ca-certificates '' ''; echo $?)"
check "with an upper bound it is not" 1 "$(relation_ok static requires ca-certificates '<=' 2020; echo $?)"
check "a lower bound is not either, for a kind that names no version" 1 "$(relation_ok static requires ca-certificates '>=' 2020; echo $?)"
check "podman may require crun with a lower bound" 0 "$(relation_ok podman requires crun '>=' 1.21; echo $?)"
check "but not with an upper bound" 1 "$(relation_ok podman requires crun '<' 2; echo $?)"
check "rpm's own entries carry their own comparison" 0 "$(relation_ok static requires 'rpmlib(CompressedFileNames)' '<=' 3.0.4-1; echo $?)"
check "a rich dependency is allowed only as the exact line of a kind" 0 "$(rich_ok podman requires '(container-selinux if selinux-policy)'; echo $?)"
check "another expression is not" 1 "$(rich_ok podman requires '(evil if x)'; echo $?)"
check "nor the same one for another kind" 1 "$(rich_ok static requires '(container-selinux if selinux-policy)'; echo $?)"
check "a kind that lists one has rich dependencies" 0 "$(rich_kind podman; echo $?)"
check "a kind that lists none has not" 1 "$(rich_kind static; echo $?)"
check "an owner is refused under /usr, whatever is listed" 1 "$(owner_ok static /usr/lib/podup/x nobody:nobody -rw-r--r--; echo $?)"
check "and for a file that can be executed" 1 "$(owner_ok static /var/lib/podup/x nobody:nobody -rwxr-xr-x; echo $?)"
check "and where no line lists it" 1 "$(owner_ok static /var/lib/podup/x nobody:nobody -rw-r--r--; echo $?)"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
