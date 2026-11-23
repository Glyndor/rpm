#!/usr/bin/env bash
#
# scripts/verify/check-release-order.sh over every id and architecture: the first publication, the
# normal ones, and the ways a publication could take the repository backwards or make part of it
# disappear. Plus the checks on the revision that stop a forged one from blocking every later run.
# Requires: rpm, createrepo_c, gpg, curl, python3 with cryptography.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/tree.sh"
ORDER="$HERE/scripts/verify/check-release-order.sh"
WORK="$(mktemp -d)"
trap 'fx_stop_agent; rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
fx_init "$WORK"; fx_archive_key
mkdir -p "$WORK/v1/p" "$WORK/v2/p"
fx_rpm "$WORK/v1/p" podup 1.2.3 1.glyndor.any noarch
fx_rpm "$WORK/v2/p" podup 1.2.4 1.glyndor.any noarch
NOW=$((FX_T2 + 60))
export ORDER_NOW="$NOW"
fx_build_tree "$WORK/served" "$FX_T1" "$WORK/v1" > /dev/null 2>&1
fx_build_tree "$WORK/next" "$FX_T2" "$WORK/v1" > /dev/null 2>&1
fx_build_tree "$WORK/newer" "$FX_T2" "$WORK/v2" > /dev/null 2>&1
run() { "$ORDER" "$@" > "$WORK/log" 2>&1; echo $?; }
S="file://$WORK/served"

check "a first publication has nothing to compare (nothing served)" 0 "$(run "file://$WORK/nothing" "$WORK/served" "$WORK/archive.asc")"
check "and says it compared none" 1 "$(grep -c '0 repository(ies) compared' "$WORK/log")"
# The first publication is explicit: config/published.txt says which repositories exist, and a 404 for one that does is a refusal.
mkdir -p "$WORK/cfg"; cp "$HERE/config/"* "$WORK/cfg/"
runc() { "$ORDER" --config "$WORK/cfg" "$@" > "$WORK/log" 2>&1; echo $?; }
check "every repository of the config is declared in published.txt, once" 14 "$(grep -vcE '^[[:space:]]*(#|$)' "$HERE/config/published.txt")"
check "and the real file declares them all as new, since nothing is published" 14 "$(grep -vE '^#' "$HERE/config/published.txt" | grep -c ' new$')"
# published_of <tree> [id to leave as new]: published.txt as it would be after a publication of that tree
published_of() {
	local id arch
	while read -r id arch; do
		if [ "$id" = "${2:-}" ]; then echo "$id $arch new"; continue; fi
		echo "$id $arch published $(python3 -I "$HERE/scripts/verify/repo-state.py" revision "$1/$id/$arch/repodata/repomd.xml") $(sha256sum "$1/$id/$arch/repodata/repomd.xml" | cut -d' ' -f1)"
	done < <(grep -vE '^[[:space:]]*(#|$)' "$HERE/config/published.txt" | cut -d' ' -f1,2)
}
published_of "$WORK/served" > "$WORK/cfg/published.txt"
check "a repository declared published that answers nothing is refused" 1 "$(runc "file://$WORK/nothing" "$WORK/served" "$WORK/archive.asc")"
check "and says it is the repository disappearing" 1 "$(grep -c 'was published and now answers nothing' "$WORK/log")"
rm -rf "${WORK:?}/partial"; cp -r "$WORK/served" "$WORK/partial"; rm -rf "$WORK/partial/el10"
check "some repositories served and the rest answering 404 without being declared new is refused" 1 "$(runc "file://$WORK/partial" "$WORK/next" "$WORK/archive.asc")"
{ published_of "$WORK/served" | grep -v '^el10 '; printf 'el10 x86_64 new\nel10 aarch64 new\n'; } > "$WORK/cfg/published.txt"
check "the same, with the missing ones declared new, is accepted" 0 "$(runc "file://$WORK/partial" "$WORK/next" "$WORK/archive.asc")"
grep -v '^el10 x86_64 ' "$WORK/cfg/published.txt" > "$WORK/cfg/p2" && mv "$WORK/cfg/p2" "$WORK/cfg/published.txt"
check "a repository that is not declared at all is refused when it answers nothing" 1 "$(runc "file://$WORK/partial" "$WORK/next" "$WORK/archive.asc")"
check "and says it is not declared" 1 "$(grep -c 'is not declared in' "$WORK/log")"
printf 'el9 x86_64 maybe\n' >> "$WORK/cfg/published.txt"
check "a line with another state is refused" 1 "$(runc "file://$WORK/partial" "$WORK/next" "$WORK/archive.asc")"
# the state is read once and is new or published, whichever way the answer comes
published_of "$WORK/served" > "$WORK/cfg/published.txt"; echo 'el9 x86_64 new' >> "$WORK/cfg/published.txt"
check "two lines for one repository are refused" 1 "$(runc "$S" "$WORK/next" "$WORK/archive.asc")"
check "and the refusal names the repository" 1 "$(grep -c "two lines for 'el9 x86_64'" "$WORK/log")"
published_of "$WORK/served" | grep -v '^el9 x86_64 ' > "$WORK/cfg/published.txt"
check "a repository that is served and is not declared at all is refused, though nothing 404s" 1 "$(runc "$S" "$WORK/next" "$WORK/archive.asc")"
check "and says it is not declared as new or published" 1 "$(grep -c 'is not declared in .* as new or published' "$WORK/log")"
published_of "$WORK/served" | sed 's/^el9 x86_64 .*/el9 x86_64/' > "$WORK/cfg/published.txt"
check "a line with no state is refused" 1 "$(runc "$S" "$WORK/next" "$WORK/archive.asc")"
check "a repository declared new that is served is accepted: the first publication happened and the file waits for its pull request" 0 \
	"$(published_of "$WORK/served" | sed 's/^el9 x86_64 .*/el9 x86_64 new/' > "$WORK/cfg/published.txt"; runc "$S" "$WORK/next" "$WORK/archive.asc")"
# rollback: signed metadata of the past put back is refused against the revision and the file recorded
published_of "$WORK/next" > "$WORK/cfg/published.txt"
check "a server that serves a repository older than the one recorded is refused (an old signed one put back)" 1 "$(runc "$S" "$WORK/newer" "$WORK/archive.asc")"
check "and says it was put back" 1 "$(grep -c 'an old signed repository was put back' "$WORK/log")"
published_of "$WORK/served" > "$WORK/cfg/published.txt"
check "the repository recorded as served is accepted when it is the one served" 0 "$(runc "$S" "$WORK/next" "$WORK/archive.asc")"
python3 - "$WORK/cfg/published.txt" <<'PY'
import sys, re
p = sys.argv[1]
lines = open(p).read().split("\n")
for i, l in enumerate(lines):
    f = l.split(" ")
    if len(f) == 5 and f[0] == "el9" and f[1] == "x86_64":
        f[4] = "0" * 64
        lines[i] = " ".join(f)
open(p, "w").write("\n".join(lines))
PY
check "a different repomd.xml at the recorded revision is refused" 1 "$(runc "$S" "$WORK/next" "$WORK/archive.asc")"
check "and says it is not the recorded one" 1 "$(grep -c 'and not the recorded repomd.xml' "$WORK/log")"
published_of "$WORK/served" | sed 's/^\(el9 x86_64 published\) .*/\1/' > "$WORK/cfg/published.txt"
check "a published line without its revision and sha256 is refused, no data being no judgement" 1 "$(runc "$S" "$WORK/next" "$WORK/archive.asc")"
check "and says what is missing" 1 "$(grep -c 'gives no readable revision and sha256' "$WORK/log")"
published_of "$WORK/served" | sed "s/^el9 x86_64 .*/el9 x86_64 new 1795000000 $(printf '0%.0s' $(seq 64))/" > "$WORK/cfg/published.txt"
check "a line that is new and carries a revision is refused" 1 "$(runc "$S" "$WORK/next" "$WORK/archive.asc")"
check "and says so" 1 "$(grep -c 'gives a revision to' "$WORK/log")"
rm -f "$WORK/cfg/published.txt"
check "a published.txt that is missing is refused" 1 "$(runc "file://$WORK/nothing" "$WORK/served" "$WORK/archive.asc")"
check "the same packages at a later revision are accepted" 0 "$(run "$S" "$WORK/next" "$WORK/archive.asc")"
check "all fourteen repositories were compared" 1 "$(grep -c '14 repository(ies) compared' "$WORK/log")"
check "a newer version is accepted" 0 "$(run "$S" "$WORK/newer" "$WORK/archive.asc")"
check "the tree that is already served is refused (same revision)" 1 "$(run "$S" "$WORK/served" "$WORK/archive.asc")"
check "an older version is refused" 1 "$(run "file://$WORK/newer" "$WORK/next" "$WORK/archive.asc")"
check "and the package is named" 1 "$(grep -c 'podup.noarch would go from' "$WORK/log" | sed 's/^[1-9][0-9]*$/1/')"

rm -rf "${WORK:?}/part"; cp -r "$WORK/next" "$WORK/part"; rm -rf "$WORK/part/el9/aarch64"
check "an id and architecture that would disappear is refused" 1 "$(run "$S" "$WORK/part" "$WORK/archive.asc")"
check "and named" 1 "$(grep -c 'el9/aarch64 is served and the new tree has none' "$WORK/log")"
mkdir -p "$WORK/v3/p"; fx_rpm "$WORK/v3/p" other 1.0.0 1.glyndor.any noarch
fx_build_tree "$WORK/swap" "$FX_T2" "$WORK/v3" > /dev/null 2>&1
check "a product that is no longer built is refused" 1 "$(run "$S" "$WORK/swap" "$WORK/archive.asc")"
printf 'podup\n' > "$WORK/retired.txt"
check "unless it was retired on purpose" 0 "$(run "$S" "$WORK/swap" "$WORK/archive.asc" "$WORK/retired.txt")"

# the served state itself cannot be read: an error, never a first publication
rm -rf "${WORK:?}/bad"; cp -r "$WORK/served" "$WORK/bad"; rm "$WORK/bad/fc45/x86_64/repodata/repomd.xml.asc"
check "a served repository with no signature stops the run" 1 "$(run "file://$WORK/bad" "$WORK/next" "$WORK/archive.asc")"
check "and says it cannot be verified" 1 "$(grep -c 'cannot be read or verified' "$WORK/log")"

# a revision from the future would block every later publication
rm -rf "${WORK:?}/future"; cp -r "$WORK/served" "$WORK/future"
# a repomd.xml signed at a good time that claims a revision a day from now
FUT="$WORK/future/fc45/x86_64"
createrepo_c --quiet --revision "$((NOW + 86400))" --set-timestamp-to-revision --compress-type gz --general-compress-type gz \
	--workers 1 "$FUT" > /dev/null 2>&1
gpg --batch --yes --armor --detach-sign --faked-system-time "$FX_T1!" -u "$(gpg --list-secret-keys --with-colons | awk -F: '$1 == "fpr" {print $10; exit}')" \
	-o "$FUT/repodata/repomd.xml.asc" "$FUT/repodata/repomd.xml" > /dev/null 2>&1
check "a served revision from the future stops the run" 1 "$(run "file://$WORK/future" "$WORK/next" "$WORK/archive.asc")"
check "and says so" 1 "$(grep -c 'in the future' "$WORK/log")"
check "a candidate revision from the future is refused" 1 "$(run "$S" "$WORK/future" "$WORK/archive.asc")"
check "a candidate revision from long ago is refused" 1 "$(ORDER_NOW=$((NOW + 86400)) run "file://$WORK/nothing" "$WORK/served" "$WORK/archive.asc")"
check "and says so" 1 "$(grep -c 'is not within an hour before' "$WORK/log")"

check "a missing argument is refused" 1 "$(run "$S" "$WORK/next")"
check "a tree that is not a folder is refused" 1 "$(run "$S" "$WORK/none" "$WORK/archive.asc")"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
