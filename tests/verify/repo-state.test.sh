#!/usr/bin/env bash
#
# scripts/verify/repo-state.py: the version comparison agrees with rpm's own, the metadata it reads
# is checked against the checksum repomd.xml gives it, and `order` refuses a repository that goes
# backwards: lower or equal revision, a dropped package, an older one, the same version with other
# bytes, a revision from the future.
# Requires: rpm, createrepo_c, gpg, python3 with cryptography.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/tree.sh"
RS="$HERE/scripts/verify/repo-state.py"
WORK="$(mktemp -d)"
trap 'fx_stop_agent; rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
rs() { python3 -I "$RS" "$@"; }

# --- the comparison is rpm's: the script asks rpm, and says what rpm says, on the cases that differ between implementations
while read -r a b; do
	want="$(rpm --eval "%{lua: print(rpm.vercmp('$a', '$b'))}")"
	check "vercmp $a $b is rpm's answer ($want)" "$want" "$(rs vercmp "$a" "$b")"
done <<'PAIRS'
1.0 1.0
1.0 1.1
1.10 1.9
01 1
1.01 1.1
1.0.01 1.0.1
1.0.001 1.0.1
1.00 1
0001 2
6.2.0+r12 6.2.0
6.2.0 6.2.0+r12
6.2.0+r12 6.2.1
6.2.0+r9 6.2.0+r12
1.0~rc1 1.0
1.0~~ 1.0~
1.0^1 1.0
1.0 1.0^1
1.0^1 1.0.1
1.0^20260101 1.0^2026
12.glyndor.fc45 12.glyndor.fc44
1.0a 1.0
1.0 1.0a
1.0a 1.0b
a b
10 9a
1.0.0 1.0
0^20260716 0^20260612
1 1.0
1_0 1.0
1-0 1.0
PAIRS
check "a version with a character rpm is not asked about is refused" 1 "$(rs vercmp '1.0;x' 1.0 > /dev/null 2>&1; echo $?)"
check "so is an empty one" 1 "$(rs vercmp '' 1.0 > /dev/null 2>&1; echo $?)"
check "and one with a quote that could end the program" 1 "$(rs vercmp '1"}' 1.0 > /dev/null 2>&1; echo $?)"

# --- reading --------------------------------------------------------------------------------------
fx_init "$WORK"; fx_archive_key
mkdir -p "$WORK/in/p"; fx_rpm "$WORK/in/p" tiny 1.0.0 1.glyndor.any x86_64; fx_rpm "$WORK/in/p" other 2.0.0 1.glyndor.any x86_64
fx_build_tree "$WORK/old" "$FX_T1" "$WORK/in" > /dev/null 2>&1
O="$WORK/old/fc45/x86_64"
href="$(rs primary "$O/repodata/repomd.xml")"
check "the primary metadata is the one named by its checksum" 1 "$(printf '%s' "$href" | grep -cE '^repodata/[0-9a-f]{64}-primary\.xml\.gz$')"
check "the two packages and the bootstrap package are listed" 3 "$(rs packages "$O/repodata/repomd.xml" "$O/$href" | wc -l)"
check "each row carries name, arch, epoch, version, release and a sha256" 1 \
	"$(rs packages "$O/repodata/repomd.xml" "$O/$href" | grep -cE '^tiny	x86_64	0	1.0.0	1.glyndor.any	[0-9a-f]{64}	Packages/tiny-1.0.0-1.glyndor.any.x86_64.rpm$')"
cp "$O/$href" "$WORK/p.gz"; printf 'x' >> "$WORK/p.gz"
check "a primary file that does not match its checksum is refused" 1 "$(rs packages "$O/repodata/repomd.xml" "$WORK/p.gz" > /dev/null 2>&1; echo $?)"
sed 's#repodata/[0-9a-f]\{64\}-primary#../../etc/passwd-primary#' "$O/repodata/repomd.xml" > "$WORK/bad.xml"
check "an href outside repodata/ is refused" 1 "$(rs primary "$WORK/bad.xml" > /dev/null 2>&1; echo $?)"
printf '<repomd' > "$WORK/broken.xml"
check "a broken repomd.xml is refused, not read as empty" 1 "$(rs revision "$WORK/broken.xml" > /dev/null 2>&1; echo $?)"
check "no arguments is a usage error" 2 "$(rs > /dev/null 2>&1; echo $?)"

# --- order -------------------------------------------------------------------------------------------
build() { # <name> <epoch> <root>: a tree of fc45 only
	fx_build_tree "$WORK/$1" "$2" "$3" > /dev/null 2>&1
}
state() { # <tree name> -> the two files `order` wants for fc45/x86_64
	local d="$WORK/$1/fc45/x86_64"; echo "$d/repodata/repomd.xml $d/$(rs primary "$d/repodata/repomd.xml")"
}
order() { # <served tree> <next tree> [retired file]
	# shellcheck disable=SC2046 # two words each
	rs order $(state "$1") $(state "$2") ${3:+"$3"}
}
order_rc() { order "$@" > "$WORK/order.out" 2>&1; echo $?; }
build same "$FX_T2" "$WORK/in"
check "the same packages at a later revision are accepted" 0 "$(order_rc old same)"
check "the same revision is refused" 1 "$(order_rc old old)"
check "an older revision is refused" 1 "$(order_rc same old)"
check "and says so" 1 "$(order old same >/dev/null 2>&1; order same old 2>&1 | grep -c 'is not greater than the served')"

mkdir -p "$WORK/in2/p"; fx_rpm "$WORK/in2/p" tiny 1.0.1 1.glyndor.any x86_64; cp "$WORK/in/p/other-2.0.0-1.glyndor.any.x86_64.rpm" "$WORK/in2/p/"
build newer "$FX_T2" "$WORK/in2"
check "a newer version is accepted" 0 "$(order_rc old newer)"
check "going back to the older version is refused" 1 "$(order_rc newer old)"
check "even at a later revision" 1 "$(build back 1790000300 "$WORK/in"; order_rc newer back)"
check "and says which package" 1 "$(grep -c 'tiny.x86_64 would go from' "$WORK/order.out")"

mkdir -p "$WORK/in3/p"; cp "$WORK/in/p/tiny-1.0.0-1.glyndor.any.x86_64.rpm" "$WORK/in3/p/"
build dropped "$FX_T2" "$WORK/in3"
check "a package that is no longer built is refused" 1 "$(order_rc old dropped)"
check "and named" 1 "$(grep -c 'other.x86_64 is served and would be dropped' "$WORK/order.out")"
printf '# retired on purpose\nother\n' > "$WORK/retired.txt"
check "unless the retired file names it" 0 "$(order_rc old dropped "$WORK/retired.txt")"
printf 'oth\n' > "$WORK/retired2.txt"
check "a retired entry is a whole name, not a prefix" 1 "$(order_rc old dropped "$WORK/retired2.txt")"

mkdir -p "$WORK/in4/p"; fx_rpm "$WORK/in4/p" tiny 1.0.0 1.glyndor.any x86_64 vendor=Glyndor packager="Glyndor <noreply@glyndor.net>" provides=extra
fx_rpm "$WORK/in4/p" other 2.0.0 1.glyndor.any x86_64
build bytes "$FX_T2" "$WORK/in4"
check "the same version with other bytes is refused" 1 "$(order_rc old bytes)"
check "and says it would be published again" 1 "$(grep -c 'tiny-1.0.0-1.glyndor.any.x86_64 is served and would be published again with other bytes' "$WORK/order.out")"

# the same version written another way is the same version for rpm, so it must be the same bytes
mkdir -p "$WORK/in5/p"; fx_rpm "$WORK/in5/p" tiny 1.0.01 1.glyndor.any x86_64; cp "$WORK/in/p/other-2.0.0-1.glyndor.any.x86_64.rpm" "$WORK/in5/p/"
mkdir -p "$WORK/in6/p"; fx_rpm "$WORK/in6/p" tiny 1.0.1 1.glyndor.any x86_64; cp "$WORK/in/p/other-2.0.0-1.glyndor.any.x86_64.rpm" "$WORK/in6/p/"
build zero1 "$FX_T1" "$WORK/in5"; build zero2 "$FX_T2" "$WORK/in6"
check "1.0.01 served and 1.0.1 offered with other bytes is the same version republished, and is refused" 1 "$(order_rc zero1 zero2)"
check "and says it would be published again" 1 "$(grep -c 'would be published again with other bytes' "$WORK/order.out")"
mkdir -p "$WORK/in7/p"; fx_rpm "$WORK/in7/p" tiny 1.0.0 1.glyndor.any x86_64; cp "$WORK/in/p/other-2.0.0-1.glyndor.any.x86_64.rpm" "$WORK/in7/p/"
build zero3 "$FX_T2" "$WORK/in7"
check "1.0.01 served and 1.0.0 offered is a step back, and is refused" 1 "$(order_rc zero1 zero3)"
check "and says so" 1 "$(grep -c 'would go from' "$WORK/order.out")"
build epoch1 "$FX_T1" "$WORK/in"
mkdir -p "$WORK/in8/p"; fx_rpm "$WORK/in8/p" tiny 0.5.0 1.glyndor.any x86_64 epoch=1; cp "$WORK/in/p/other-2.0.0-1.glyndor.any.x86_64.rpm" "$WORK/in8/p/"
build epoch2 "$FX_T2" "$WORK/in8"
check "a higher epoch with a lower version is a step forward" 0 "$(order_rc epoch1 epoch2)"
check "and the reverse is a step back" 1 "$(build epoch3 1790000300 "$WORK/in8"; build epoch4 1790000400 "$WORK/in"; order_rc epoch3 epoch4)"

# a decompression bomb is never decompressed whole
python3 -I - "$WORK/bomb" <<'PY'
import gzip, hashlib, sys, os
d = sys.argv[1]
os.makedirs(d + "/repodata")
raw = gzip.compress(b"<metadata>" + b"A" * (600 * 1024 * 1024) + b"</metadata>", 1)
h = hashlib.sha256(raw).hexdigest()
open(f"{d}/repodata/{h}-primary.xml.gz", "wb").write(raw)
open(d + "/repodata/repomd.xml", "w").write(f"""<?xml version="1.0"?>
<repomd xmlns="http://linux.duke.edu/metadata/repo"><revision>1790000100</revision>
<data type="primary"><checksum type="sha256">{h}</checksum><location href="repodata/{h}-primary.xml.gz"/></data></repomd>""")
PY
check "the size of the bomb on the disk is small" 1 "$([ "$(stat -c%s "$WORK"/bomb/repodata/*-primary.xml.gz)" -lt 3000000 ] && echo 1 || echo 0)"
b="$(ls "$WORK"/bomb/repodata/*-primary.xml.gz)"
check "a primary file that is huge once decompressed is refused" 1 "$(rs packages "$WORK/bomb/repodata/repomd.xml" "$b" > "$WORK/bomb.out" 2>&1; echo $?)"
check "and says it is too large" 1 "$(grep -c 'too large once decompressed' "$WORK/bomb.out")"
# a revision that is not made of ASCII digits
for rev in 17900001 179000010000 '١٧٩٠٠٠٠١٠٠' '1790000100x' '-1790000100' ' 1790000100'; do
	sed "s|<revision>[^<]*</revision>|<revision>$rev</revision>|" "$O/repodata/repomd.xml" > "$WORK/rev.xml"
	check "the revision '$rev' is refused" 1 "$(rs revision "$WORK/rev.xml" > /dev/null 2>&1; echo $?)"
done

check "a missing retired file is an error" 1 "$(order_rc old same "$WORK/nowhere.txt")"
check "a state that is not there is an error" 1 "$(rs order "$WORK/none" "$WORK/none" "$WORK/none" "$WORK/none" > /dev/null 2>&1; echo $?)"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
