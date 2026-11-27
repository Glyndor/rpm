#!/usr/bin/env bash
#
# scripts/verify/served-state.sh against a tree served as file:// and over a local http server:
# "nothing served" is told apart from every kind of failure, and what is served is checked with the
# archive key before anything is compared with it.
# Requires: rpm, createrepo_c, gpg, curl, python3 with cryptography.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/tree.sh"
SERVED="$HERE/scripts/verify/served-state.sh"
WORK="$(mktemp -d)"
SERVER_PID=""
trap 'fx_stop_agent; [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
fx_init "$WORK"; fx_archive_key; fx_other_key "$WORK/other.asc"
fx_admitted "$WORK/in"
fx_build_tree "$WORK/tree" "$FX_T1" "$WORK/in" > /dev/null 2>&1
served() { rm -rf "$WORK/out"; mkdir "$WORK/out"; "$SERVED" "$@" 2>&1; }

rm -rf "$WORK/out"; mkdir "$WORK/out"; "$SERVED" "file://$WORK/tree" fc45 x86_64 "$WORK/out" "$WORK/archive.asc" > /dev/null 2>&1; rc=$?
check "a served repository is fetched" 0 "$rc"
check "its repomd.xml and primary metadata are kept" "primary.xml.gz repomd.xml" "$(fx_names "$WORK/out")"
rm -rf "$WORK/out"; mkdir "$WORK/out"; "$SERVED" "file://$WORK/tree" leap16.1 x86_64 "$WORK/out" "$WORK/archive.asc" > /dev/null 2>&1
check "the same for a zypper id" 0 "$?"
rm -rf "$WORK/out"; mkdir "$WORK/out"; "$SERVED" "file://$WORK/none" fc45 x86_64 "$WORK/out" "$WORK/archive.asc" > /dev/null 2>&1
check "a repository that is not there reads as nothing served (10)" 10 "$?"

fail_case() { # <description> <fragment> <mutation> ; the tree is a mutated copy
	local d="$1" frag="$2" o rc=0
	rm -rf "${WORK:?}/t"; cp -r "$WORK/tree" "$WORK/t"; ( cd "$WORK/t" && eval "$3" ) > /dev/null 2>&1
	rm -rf "$WORK/out"; mkdir "$WORK/out"
	o="$("$SERVED" "file://$WORK/t" fc45 x86_64 "$WORK/out" "$WORK/archive.asc" 2>&1)" || rc=$?
	check "$d: a failure, not 'nothing served'" 1 "$([ "$rc" -ne 0 ] && [ "$rc" -ne 10 ] && echo 1 || echo 0)"
	check "$d: says why" 1 "$(printf '%s' "$o" | grep -cF -- "$frag")"
}
fail_case "no signature served" "has no signature" "rm fc45/x86_64/repodata/repomd.xml.asc"
fail_case "an altered repomd.xml" "is not signed by the archive key" "sed -i 's/<revision>/<revision>9/' fc45/x86_64/repodata/repomd.xml"
fail_case "a signature of another key" "is not signed by the archive key" "gpg --version >/dev/null; cp $WORK/other.asc fc45/x86_64/repodata/repomd.xml.asc"
fail_case "a primary file that is gone" "answers 404" "rm fc45/x86_64/repodata/*-primary.xml.gz"
fail_case "a primary file altered" "does not match its repomd.xml" "for f in fc45/x86_64/repodata/*-primary.xml.gz; do printf x >> \$f; done"

for url in 'http://example.com' 'ftp://x/y' 'https://evil.example/../x' 'https://a b' 'file://relative/path' ''; do
	o="$(served "$url" fc45 x86_64 "$WORK/out" "$WORK/archive.asc")"; check "the base URL '$url' is refused" 1 "$?"
done
o="$(served "file://$WORK/tree" 'fc45/../x' x86_64 "$WORK/out" "$WORK/archive.asc")"; check "an id with a path in it is refused" 1 "$?"
for badid in '..' '.' 'leap16.' '16.1.2'; do
	o="$(served "file://$WORK/tree" "$badid" x86_64 "$WORK/out" "$WORK/archive.asc")"; check "the id '$badid' is refused" 1 "$?"
done
o="$(served "file://$WORK/tree" fc45 x86_64 "$WORK/none" "$WORK/archive.asc")"; check "an output folder that is not there is refused" 1 "$?"
o="$(served "file://$WORK/tree" fc45 x86_64 "$WORK/out" "$WORK/none.asc")"; check "a key file that is not there is refused" 1 "$?"
o="$(served "file://$WORK/tree" fc45)"; check "too few arguments are refused" 1 "$?"

# over HTTP: a 404 is nothing served, and a server error is not
mkdir -p "$WORK/www"; cp -r "$WORK/tree" "$WORK/www/ok"
( cd "$WORK/www" && exec python3 -m http.server 18431 --bind 127.0.0.1 > /dev/null 2>&1 ) &
SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl --silent --max-time 2 --connect-timeout 2 -o /dev/null http://127.0.0.1:18431/ && break; sleep 1; done
rm -rf "$WORK/out"; mkdir "$WORK/out"; "$SERVED" http://127.0.0.1:18431/ok fc45 x86_64 "$WORK/out" "$WORK/archive.asc" > /dev/null 2>&1
check "a local http URL with a path is not allowed" 1 "$?"
rm -rf "$WORK/out"; mkdir "$WORK/out"
cat > "$WORK/www/ok/.keep" < /dev/null
"$SERVED" "http://127.0.0.1:18431" fc45 x86_64 "$WORK/out" "$WORK/archive.asc" > /dev/null 2>&1
check "a 404 over http is nothing served (10)" 10 "$?"
kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""
( cd "$WORK/tree" && exec python3 -m http.server 18432 --bind 127.0.0.1 > /dev/null 2>&1 ) &
SERVER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl --silent --max-time 2 --connect-timeout 2 -o /dev/null http://127.0.0.1:18432/ && break; sleep 1; done
rm -rf "$WORK/out"; mkdir "$WORK/out"; "$SERVED" http://127.0.0.1:18432 fc45 x86_64 "$WORK/out" "$WORK/archive.asc" > /dev/null 2>&1
check "the tree served over http is fetched and verified" 0 "$?"
kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""
rm -rf "$WORK/out"; mkdir "$WORK/out"; rc=0
"$SERVED" http://127.0.0.1:18433 fc45 x86_64 "$WORK/out" "$WORK/archive.asc" > /dev/null 2>&1 || rc=$?
check "a server that is not there is an error, not nothing served" 1 "$([ "$rc" -ne 0 ] && [ "$rc" -ne 10 ] && echo 1 || echo 0)"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
