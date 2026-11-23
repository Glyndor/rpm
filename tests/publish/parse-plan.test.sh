#!/usr/bin/env bash
#
# scripts/publish/parse-plan.sh: the plan string the plan job prints is read only in its closed form.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/scripts/publish/parse-plan.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
pp() { PLAN_CONFIG="$HERE/config/products.txt" parse_plan "$1" "$WORK/plan" > /dev/null 2>&1; echo $?; }

check "one product is read" 0 "$(pp 'podup v1.2.3')"
check "as one line" "podup v1.2.3" "$(cat "$WORK/plan")"
check "several products are read" 0 "$(pp 'podup v1.2.3,podman v6.2.0+r12,helmly-agent v0.4.0')"
check "one line each, in order" "podup v1.2.3
podman v6.2.0+r12
helmly-agent v0.4.0" "$(cat "$WORK/plan")"
for bad in '' 'podup' 'podup main' 'podup v1.2' 'podup v1.2.3-rc1' 'podup  v1.2.3' ' podup v1.2.3' 'podup v1.2.3 ' 'nginx v1.2.3' \
	'Podup v1.2.3' 'podup v1.2.3,' ',podup v1.2.3' 'podup v1.2.3;rm -rf /' 'podup v1.2.3,,podman v6.2.0' 'po.up v1.2.3' 'podup v1.2.3+r' \
	'podup v1.2.3
podman v6.2.0'; do
	check "'$(printf '%s' "$bad" | tr '\n' '|')' is refused" 1 "$(pp "$bad")"
done
check "a refused plan leaves nothing usable" 0 "$([ -s "$WORK/plan" ] && echo 1 || echo 0)"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
