#!/usr/bin/env bash
#
# scripts/build/repo-file.sh: the repository file of each id, with the exact names it may offer, the
# address form measured for it, no priority, and the options that keep one bad repository from stopping a host.
# shellcheck disable=SC2016 # the patterns are literal text of the repository file
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RF="$HERE/scripts/build/repo-file.sh"
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
B=https://rpm.glyndor.net; K=$B/glyndor-rpm-key.asc
rf() { "$RF" "$1" "$B" "$K"; }
field() { rf "$1" | grep "^$2=" | cut -d= -f2-; }

check "Fedora follows the release of the host" 'https://rpm.glyndor.net/fc$releasever/$basearch/' "$(field fc45 baseurl)"
check "fc44 and fc45 are the same file" "$(rf fc45)" "$(rf fc44)"
check "EL has a fixed id per major (el9)" 'https://rpm.glyndor.net/el9/$basearch/' "$(field el9 baseurl)"
check "and el10" 'https://rpm.glyndor.net/el10/$basearch/' "$(field el10 baseurl)"
check "Amazon Linux is fixed" 'https://rpm.glyndor.net/amzn2023/$basearch/' "$(field amzn2023 baseurl)"
check "Leap follows \$releasever" 'https://rpm.glyndor.net/leap$releasever/$basearch/' "$(field leap16.1 baseurl)"
check "Tumbleweed is fixed" 'https://rpm.glyndor.net/tumbleweed/$basearch/' "$(field tumbleweed baseurl)"
check "fc45 offers podman, its companions, the products and the bootstrap package, and nothing else" \
	"epistle epistle-panel glyndor-release helmly helmly-agent podman podman-docker podmansh podup" "$(field fc45 includepkgs)"
check "el9 adds catatonit" "catatonit epistle epistle-panel glyndor-release helmly helmly-agent podman podman-docker podmansh podup" "$(field el9 includepkgs)"
check "amzn2023 adds crun, conmon and catatonit" "catatonit conmon crun epistle epistle-panel glyndor-release helmly helmly-agent podman podman-docker podmansh podup" "$(field amzn2023 includepkgs)"
check "leap16.1 adds crun and passt" "crun epistle epistle-panel glyndor-release helmly helmly-agent passt podman podman-docker podmansh podup" "$(field leap16.1 includepkgs)"
for id in fc45 fc44 el9 el10 amzn2023 leap16.1 tumbleweed; do
	check "$id checks packages and metadata, explicitly" "1 1 1" "$(rf $id | grep -cx 'gpgcheck=1') $(rf $id | grep -cx 'repo_gpgcheck=1') $(rf $id | grep -cx 'pkg_gpgcheck=1')"
	check "$id skips a repository that is unavailable" 1 "$(rf $id | grep -cx 'skip_if_unavailable=1')"
	check "$id has no priority" 0 "$(rf $id | grep -c '^priority')"
	check "$id names the key it was given" "$K" "$(field $id gpgkey)"
done
check "the key of a local file is passed through as it is" "file:///etc/pki/rpm-gpg/RPM-GPG-KEY-glyndor" "$("$RF" fc45 "$B" file:///etc/pki/rpm-gpg/RPM-GPG-KEY-glyndor | grep '^gpgkey=' | cut -d= -f2-)"
check "an id that is not in the config is refused" 1 "$("$RF" ubuntu "$B" "$K" > /dev/null 2>&1; echo $?)"
check "too few arguments are refused" 1 "$("$RF" fc45 > /dev/null 2>&1; echo $?)"
check "an id that is a path is refused" 1 "$("$RF" ../fc45 "$B" "$K" > /dev/null 2>&1; echo $?)"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
