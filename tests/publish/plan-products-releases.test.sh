#!/usr/bin/env bash
#
# scripts/publish/plan-products.sh and the releases it chooses from, with a stand-in for gh and a
# repository that serves nothing: a product whose releases also carry tags that are not versions of it,
# or that has no release, does not stop the plan, and a list that cannot be read does.
# What a served repository changes is in plan-products.test.sh.
# Requires: curl, gpg, jq.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
mkdir -p "$WORK/bin" "$WORK/rel"
# A gh that answers `release list` from <product>.list and `release view <tag>` from <product>@<tag>.json,
# and fails like gh does when the file is not there.
cat > "$WORK/bin/gh" <<'SH'
#!/bin/sh
case "$1 $2" in
	"release list") file="$FAKE_RELEASES/${4#Glyndor/}.list" ;;
	"release view") file="$FAKE_RELEASES/${5#Glyndor/}@$3.json" ;;
	*) echo "fake gh: unexpected call: $*" >&2; exit 2 ;;
esac
printf '%s\n' "$*" >> "$FAKE_RELEASES/calls"
[ -f "$file" ] || exit 1
cat "$file"
SH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" FAKE_RELEASES="$WORK/rel"

RPM='{"name":"x-1-1.glyndor.any.x86_64.rpm","size":4}'
NOTES='{"name":"notes.txt","size":1}'
releases() { # <product> <tag>[*]... : newest first; the tag marked * is the one GitHub calls the latest
	local product="$1" out="" t latest
	shift
	for t in "$@"; do
		latest=false
		case "$t" in *\*) latest=true; t="${t%\*}" ;; esac
		out="$out${out:+,}{\"tagName\":\"$t\",\"isLatest\":$latest}"
	done
	printf '[%s]' "$out" > "$WORK/rel/$product.list"
}
assets() { printf '{"tagName":"%s","assets":[%s]}' "$2" "$3" > "$WORK/rel/$1@$2.json"; } # <product> <tag> <assets>
plan() { ARCHIVE_URL="file://$WORK/nothing" bash "$HERE/scripts/publish/plan-products.sh" 2> "$WORK/err"; }
reset() {
	rm -f "$WORK/rel"/*
	local p
	for p in podman podup epistle helmly-agent helmly epistle-panel; do releases "$p" 'v1.0.0*'; assets "$p" v1.0.0 "$NOTES"; done
}

reset; assets podup v1.0.0 "$RPM"
check "a product whose newest version carries an rpm is planned" "podup v1.0.0" "$(plan)"
check "the releases are asked for without drafts or prereleases" 6 "$(grep -c '^release list --repo Glyndor/[a-z-]* --exclude-drafts --exclude-pre-releases ' "$WORK/rel/calls")"

reset; releases helmly 'dashboard@1.5.0*' agent@1.2.15
assets podup v1.0.0 "$RPM"
out="$(plan)"; status=$?
check "a product with no version tag among its releases does not stop the run" 0 "$status"
check "and the others are planned" "podup v1.0.0" "$out"
check "and it is skipped with a notice that says so" 1 "$(grep -c '::notice::Glyndor/helmly has no version release' "$WORK/err")"

reset; releases epistle-panel; assets podup v1.0.0 "$RPM"
out="$(plan)"; status=$?
check "a product with no release at all does not stop the run" 0 "$status"
check "and the others are planned all the same" "podup v1.0.0" "$out"
check "and it is skipped with its own notice" 1 "$(grep -c '::notice::Glyndor/epistle-panel has no version release' "$WORK/err")"

reset; releases helmly 'dashboard@1.5.0*' v2.0.0 v1.9.0; assets helmly v2.0.0 "$RPM"; assets helmly v1.9.0 "$NOTES"
check "the newest version tag is chosen when the latest release is not one" "helmly v2.0.0" "$(plan)"

reset; releases podman v6.3.0 'v6.2.1+r5*'; assets podman 'v6.2.1+r5' "$RPM"; assets podman v6.3.0 "$RPM"
check "the release marked latest is chosen over a newer version" "podman v6.2.1+r5" "$(plan)"

reset; rm "$WORK/rel/epistle.list"
out="$(plan)"; status=$?
check "a release list that cannot be read stops the run" 1 "$status"
check "and says which" 1 "$(grep -c 'cannot list the releases of Glyndor/epistle' "$WORK/err")"

reset; rm "$WORK/rel/epistle@v1.0.0.json"
plan > /dev/null; status=$?
check "a chosen release that cannot be read stops the run" 1 "$status"
check "and names the release" 1 "$(grep -c 'cannot read the release v1.0.0 of Glyndor/epistle' "$WORK/err")"

reset; printf 'not json' > "$WORK/rel/epistle.list"
plan > /dev/null; status=$?
check "a release list that is not JSON stops the run" 1 "$status"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
