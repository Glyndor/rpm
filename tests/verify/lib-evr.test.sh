#!/usr/bin/env bash
#
# scripts/verify/lib-evr.sh: how a tag becomes the version of a package and how rpm orders two of them, and that a
# failure of rpm is a status, never an answer.
# Requires: rpm.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/scripts/verify/lib-evr.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
check "a Podman tag without a revision is revision 1" "6.2.0+r1" "$(evr_of v6.2.0 podman)"
check "a Podman tag keeps its revision" "6.2.0+r12" "$(evr_of v6.2.0+r12 podman)"
check "another product is the version alone" "1.2.3" "$(evr_of v1.2.3 static)"
check "another product with a revision is refused" 1 "$(evr_of v1.2.3+r2 static > /dev/null; echo $?)"
check "a tag that is not a version is refused" 1 "$(evr_of 1.2.3 podman > /dev/null; echo $?)"
check "a tag with a quote is refused" 1 "$(evr_of "v1.2.3'" podman > /dev/null; echo $?)"
check "r9 is below r10, as rpm orders them" -1 "$(vercmp 6.2.0+r9 6.2.0+r10)"
check "r10 is above r9" 1 "$(vercmp 6.2.0+r10 6.2.0+r9)"
check "r19 is below r20" -1 "$(vercmp 6.2.0+r19 6.2.0+r20)"
check "the same version is equal" 0 "$(vercmp 6.2.0+r12 6.2.0+r12)"
check "a revision is above the version without one" 1 "$(vercmp 6.2.0+r1 6.2.0)"
check "a text that is not a version is refused" 1 "$(vercmp "1'; os.exit(0) --" 1.0 > /dev/null; echo $?)"
mkdir "$WORK/bin"
stubbed() { local o rc=0; o="$(PATH="$WORK/bin:$PATH" vercmp 1.0 2.0)" || rc=$?; echo "$rc|$o"; }
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/rpm"; chmod +x "$WORK/bin/rpm"
check "an rpm that fails is a status of failure and no answer" "1|" "$(stubbed)"
printf '#!/bin/sh\necho 7\n' > "$WORK/bin/rpm"
check "an rpm that answers something else than -1, 0 or 1 is a failure" "1|" "$(stubbed)"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
