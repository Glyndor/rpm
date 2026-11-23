#!/usr/bin/env bash
#
# The committed description of what the channel serves: the products, the Podman package set per
# distribution id, what a package may claim, the pinned release key, and the contract the
# products read. A change to any of them is a change of what is admitted and published, so each is
# pinned here to the value the owner decided, and the product contract document is tied to the
# constants the admission script enforces.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
rows() { grep -vE '^[[:space:]]*(#|$)' "$1"; }

# --- products ---------------------------------------------------------------------------------
check "the channel serves exactly the six products" \
	"epistle epistle-panel helmly helmly-agent podman podup" "$(rows "$HERE/config/products.txt" | cut -f1 | sort | tr '\n' ' ' | sed 's/ $//')"
check "every product row has five fields" 0 "$(rows "$HERE/config/products.txt" | awk -F'\t' 'NF != 5' | wc -l)"
check "every product is attested against its tag" "tag" "$(rows "$HERE/config/products.txt" | cut -f5 | sort -u)"
check "the kinds in use are podman and static; service is for the first product that installs a unit" "podman static" "$(rows "$HERE/config/products.txt" | cut -f2 | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "only podman has the podman kind" "podman" "$(rows "$HERE/config/products.txt" | awk -F'\t' '$2 == "podman" { print $1 }')"
check "no product is a service yet, until epistle ships a unit" "" "$(rows "$HERE/config/products.txt" | awk -F'\t' '$2 == "service" { print $1 }')"
check "the architectures are the two of the .deb, or noarch" "noarch x86_64,aarch64" \
	"$(rows "$HERE/config/products.txt" | cut -f3 | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "only epistle-panel is architecture independent" "epistle-panel" "$(rows "$HERE/config/products.txt" | awk -F'\t' '$3 == "noarch" { print $1 }')"
check "helmly is attested by its dashboard release workflow" "release-dashboard.yml" \
	"$(rows "$HERE/config/products.txt" | awk -F'\t' '$1 == "helmly" { print $4 }')"
check "every other product by release.yml" "release.yml" \
	"$(rows "$HERE/config/products.txt" | awk -F'\t' '$1 != "helmly" { print $4 }' | sort -u)"

# --- the Podman set ---------------------------------------------------------------------------
P="$HERE/config/podman-packages.txt"
check "the seven distribution ids of the contract" "amzn2023 el10 el9 fc44 fc45 leap161 tumbleweed" \
	"$(rows "$P" | cut -f1 | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "every row has five fields" 0 "$(rows "$P" | awk -F'\t' 'NF != 5' | wc -l)"
epochs="$(rows "$P" | awk -F'\t' '$2 == "podman" { printf "%s=%s ", $1, $4 }' | sort | tr -d '\n' | sed 's/ $//')"
check "the epochs of the distributions' own podman (measured 2026-11-23)" \
	"amzn2023=0 el10=7 el9=6 fc44=5 fc45=5 leap161=0 tumbleweed=0" "$(printf '%s\n' "$epochs" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
check "podman is built per architecture on every id" 7 "$(rows "$P" | awk -F'\t' '$2 == "podman" && $3 == "arch"' | wc -l)"
check "podman-docker and podmansh are noarch on every id" 14 "$(rows "$P" | awk -F'\t' '($2 == "podman-docker" || $2 == "podmansh") && $3 == "noarch"' | wc -l)"
check "their epoch is the epoch of podman" 0 "$(rows "$P" | awk -F'\t' '$2 == "podman" { e[$1] = $4 } ($2 == "podman-docker" || $2 == "podmansh") && e[$1] != $4' | wc -l)"
extras="$(rows "$P" | awk -F'\t' '$5 == "extra" { printf "%s:%s:%s ", $1, $2, $4 }' | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
check "the components packaged beside podman, and the epoch of each" \
	"amzn2023:catatonit:0 amzn2023:conmon:2 amzn2023:crun:0 el9:catatonit:0 leap161:crun:0 leap161:passt:0" "$extras"
check "no package has another name than the contract's" "catatonit conmon crun passt podman podman-docker podmansh" \
	"$(rows "$P" | cut -f2 | sort -u | tr '\n' ' ' | sed 's/ $//')"

# --- relations ---------------------------------------------------------------------------------
R="$HERE/config/relations.txt"
check "each of the five package kinds has a rule for each of the eight relations" 40 "$(rows "$R" | wc -l)"
check "and no kind has two" 0 "$(rows "$R" | cut -f1,2 | sort | uniq -d | wc -l)"
check "nothing may supplement or enhance another package, in any kind" 10 "$(rows "$R" | awk -F'\t' '($2 == "supplements" || $2 == "enhances") && $3 == "NONE"' | wc -l)"
check "a static product recommends and suggests nothing" 2 "$(rows "$R" | awk -F'\t' '$1 == "static" && ($2 == "recommends" || $2 == "suggests") && $3 == "NONE"' | wc -l)"
check "a static product may require only a short list" 0 "$(rows "$R" | awk -F'\t' '$1 == "static" && $2 == "requires" && $3 == ".*"' | wc -l)"
check "conflicts are never allowed" "" "$(rows "$R" | awk -F'\t' '$2 == "conflicts" && $3 != "NONE"')"
check "only podman and the docker companion may obsolete anything" "companion podman" \
	"$(rows "$R" | awk -F'\t' '$2 == "obsoletes" && $3 != "NONE" { print $1 }' | sort | tr '\n' ' ' | sed 's/ $//')"
check "a static product obsoletes nothing" NONE "$(rows "$R" | awk -F'\t' '$1 == "static" && $2 == "obsoletes" { print $3 }')"
check "a service has the rules of a static product, but for what it requires" "" \
	"$(diff <(rows "$R" | awk -F'\t' '$1 == "static" && $2 != "requires" { print $2 "\t" $3 }') <(rows "$R" | awk -F'\t' '$1 == "service" && $2 != "requires" { print $2 "\t" $3 }'))"
check "a service may require only what rpm adds by itself and systemd, the rest is in service-requires.txt" "(rpmlib\\(.*\\)|config\\(NAME\\)|(user|group)\\([a-z_][a-z0-9_-]*\\)|/bin/sh|systemd)" \
	"$(rows "$R" | awk -F'\t' '$1 == "service" && $2 == "requires" { print $3 }')"
SR="$HERE/config/service-requires.txt"
check "every service-requires row is a service of products.txt" 0 "$(rows "$SR" | cut -f1 | sort -u | while read -r p; do rows "$HERE/config/products.txt" | awk -F'\t' -v p="$p" '$1 == p && $2 == "service" { f = 1 } END { exit f }' && echo "$p"; done | wc -l)"
check "every one is name|comparison|version, with a version when there is a comparison" 0 \
	"$(rows "$SR" | cut -f2 | grep -vcE '^[a-z0-9][a-z0-9._+-]*\|(>=|=|)\|[0-9A-Za-z.:+~^-]*$')"
check "no service lists a Requires yet" 0 "$(rows "$SR" | wc -l)"

check "no floor is recorded yet, since nothing is published" 0 "$(rows "$HERE/config/floor.txt" | wc -l)"

# --- paths and scriptlets -------------------------------------------------------------------------
PA="$HERE/config/paths.txt"
LK="$HERE/config/links.txt"
check "the listed links are three fields, for a kind that has path rules" 0 "$(rows "$LK" | awk -F'\t' 'NF != 3' | wc -l)"
check "only the companion of podman lists links, and only to podman" "companion	/usr/bin/podman" "$(rows "$LK" | awk -F'\t' '{ print $1 "\t" $3 }' | sort -u)"
check "the path rules are for the five kinds" "companion extra podman service static" "$(rows "$PA" | cut -f1 | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "every path rule is anchored under /usr, /etc or /var" 0 "$(rows "$PA" | cut -f2 | sed 's/^dir://' | grep -vcE '^/(usr|etc|var)/')"
check "nothing but the folder /etc/containers itself may be under it, in any kind" 0 "$(rows "$PA" | grep -E '/etc/containers' | grep -vc 'dir:')"
check "no path rule reaches a folder of the package manager" 0 "$(rows "$PA" | cut -f2 | grep -cE '^/etc/(yum\.repos\.d|zypp|pki|dnf|pacman)|^/usr/lib/rpm|^/usr/share/pacman')"
check "a static product may install its man pages, licence, completions and units" 1 "$(rows "$PA" | grep -c 'static.*vendor_completions')"
check "no scriptlet text is listed yet: the Podman scriptlets and the first service are not here" 0 "$(rows "$HERE/config/scriptlets.txt" | wc -l)"
check "a service has the paths of a static product" "" "$(diff <(rows "$PA" | awk -F'\t' '$1 == "static" { print $2 }') <(rows "$PA" | awk -F'\t' '$1 == "service" { print $2 }'))"

# --- keys --------------------------------------------------------------------------------------
check "the release public key is the Ed25519 key of the organization" "HFv7vg5FCY7YyKUDbJhaQSfB9SboJGSblJtFbLmLHzM" \
	"$(rows "$HERE/keyring/glyndor-release-ed25519.b64")"
check "no ML-DSA-65 key is committed yet" 0 "$(rows "$HERE/keyring/glyndor-release-mldsa65.b64" | wc -l)"
check "no product requires the second signature yet" 0 "$(rows "$HERE/keyring/pq-required-products" | wc -l)"

# --- the contract the products read ------------------------------------------------------------
DOC="$HERE/docs/product-contract.md"
ADMIT="$HERE/scripts/verify/admit-release.sh"
for value in 'Glyndor <noreply@glyndor.net>' '1.glyndor.any' 'Vendor' '300 MiB' '4096 bytes' 'format | 4' 'config/paths.txt' 'config/scriptlets.txt' 'AutoProv: no' 'glyndor-release'; do
	check "the product contract says '$value'" 1 "$(grep -cF -- "$value" "$DOC" | sed 's/^[1-9][0-9]*$/1/')"
done
check "the packager of the contract is the one the script enforces" 1 "$(grep -cF 'PACKAGER="Glyndor <noreply@glyndor.net>"' "$ADMIT")"
check "the size cap of the contract is the one the script enforces" 1 "$(grep -cF '300 * 1024 * 1024' "$ADMIT")"
for product in podup epistle helmly-agent helmly epistle-panel; do
	check "the contract names $product" 1 "$(grep -cF -- "$product" "$DOC" | sed 's/^[1-9][0-9]*$/1/')"
done

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
