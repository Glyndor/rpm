#!/usr/bin/env bash
#
# scripts/verify/admit-release.sh against whole releases built in the test: the happy paths of a
# static product and of the Podman set, and the simulated attacks on the signature, the set of
# files, the names and the sizes. The header fields and the relations are in
# admit-release-fields.test.sh, the second signature in admit-release-pq.test.sh.
# Requires: rpm (rpmbuild), python3 with cryptography.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/tests/fixtures/rpm/lib.sh"
ADMIT="$HERE/scripts/verify/admit-release.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
check() { # <description> <expected> <actual>
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok    $1"
	else fail=$((fail + 1)); echo "FAIL  $1 (want '$2', got '$3')"; fi
}
fx_init "$WORK"
admit() { "$ADMIT" --keyring "$WORK/keyring" "$@" 2>&1; } # <product> <tag> <dir>
refused() { # <description> <product> <tag> <dir> <fragment of the message>
	local out rc=0
	out="$(admit "$2" "$3" "$4")" || rc=$?
	check "$1: refused" 1 "$rc"
	check "$1: says why" 1 "$(printf '%s' "$out" | grep -cF -- "$5")"
}
copy() { rm -rf "$WORK/r"; cp -r "$1" "$WORK/r"; } # a fresh copy of a release to damage

fx_static_release "$WORK/base" podup 1.2.3 x86_64,aarch64
base_x="podup-1.2.3-1.glyndor.any.x86_64.rpm"
base_a="podup-1.2.3-1.glyndor.any.aarch64.rpm"

# --- the happy paths -------------------------------------------------------------------------
out="$(admit podup v1.2.3 "$WORK/base")"; check "a static release is admitted" 0 "$?"
check "both packages are named" 2 "$(printf '%s' "$out" | grep -c '^admitted podup-')"
fx_static_release "$WORK/noarch" epistle-panel 0.9.1 noarch
out="$(admit epistle-panel v0.9.1 "$WORK/noarch")"; check "a noarch product is admitted" 0 "$?"
fx_podman_release "$WORK/podman" 6.2.0 12
out="$(admit podman v6.2.0+r12 "$WORK/podman")"; rc=$?
check "the whole Podman set is admitted" 0 "$rc"
want=0
while IFS=$'\t' read -r _ _ akind _; do [ "$akind" = noarch ] && want=$((want + 1)) || want=$((want + 2)); done \
	< <(grep -vE '^[[:space:]]*(#|$)' "$HERE/config/podman-packages.txt")
check "every file of the set is named" "$want" "$(printf '%s' "$out" | grep -c '^admitted .*\.rpm$')"
fx_podman_release "$WORK/podman1" 6.2.1 1
out="$(admit podman v6.2.1 "$WORK/podman1")"; check "a tag without +rN is revision 1" 0 "$?"
check "the revision of the tag is the one of the files" 1 "$(admit podman v6.2.1+r2 "$WORK/podman1" >/dev/null; echo $?)"

# --- the signature -----------------------------------------------------------------------------
copy "$WORK/base"; printf 'x' >> "$WORK/r/$base_x"
refused "a package changed after it was signed" podup v1.2.3 "$WORK/r" "invalid signature for $base_x"
copy "$WORK/base"; mkdir "$WORK/other"; $FX_PY "$HERE/tests/fixtures/rpm/release-key.py" gen-ed "$WORK/other"
$FX_PY "$HERE/tests/fixtures/rpm/release-key.py" sign-ed "$WORK/other/ed.seed" "$WORK/r/$base_x"
refused "a signature made by another key" podup v1.2.3 "$WORK/r" "invalid signature for $base_x"
copy "$WORK/base"; rm "$WORK/r/$base_x.sig"
refused "a package with no signature" podup v1.2.3 "$WORK/r" "no signature $base_x.sig"
copy "$WORK/base"; head -c 63 "$WORK/r/$base_x.sig" > "$WORK/r/s"; mv "$WORK/r/s" "$WORK/r/$base_x.sig"
refused "a signature of 63 bytes" podup v1.2.3 "$WORK/r" "invalid signature"
copy "$WORK/base"; head -c 5000 /dev/zero > "$WORK/r/$base_x.sig"
refused "a signature over the 4096 byte cap" podup v1.2.3 "$WORK/r" "over the 4096-byte signature cap"
copy "$WORK/base"; cp "$WORK/r/$base_x.sig" "$WORK/r/$base_a.sig"
refused "the signature of the other architecture" podup v1.2.3 "$WORK/r" "invalid signature for $base_a"
copy "$WORK/base"; head -c 64 /dev/zero > "$WORK/r/$base_x.sig"
refused "an all zero signature" podup v1.2.3 "$WORK/r" "invalid signature"
copy "$WORK/base"; printf 'broken\n' > "$WORK/ed.bad"; printf '%s\r\n' "$(cat "$WORK/keyring/glyndor-release-ed25519.b64")" > "$WORK/kr.crlf"
mkdir "$WORK/kr2"; cp "$WORK/keyring/"* "$WORK/kr2/"; cp "$WORK/kr.crlf" "$WORK/kr2/glyndor-release-ed25519.b64"
out="$("$ADMIT" --keyring "$WORK/kr2" podup v1.2.3 "$WORK/r" 2>&1)"; check "a trust anchor with a carriage return is refused" 1 "$?"
check "and named as the cause" 1 "$(printf '%s' "$out" | grep -c 'the Ed25519 release key file')"
: > "$WORK/kr2/glyndor-release-ed25519.b64"
out="$("$ADMIT" --keyring "$WORK/kr2" podup v1.2.3 "$WORK/r" 2>&1)"; check "an empty Ed25519 key file is refused" 1 "$?"
check "and said to be a broken trust file" 1 "$(printf '%s' "$out" | grep -c 'local release trust file is malformed')"

# --- the set of files ----------------------------------------------------------------------
copy "$WORK/base"; rm "$WORK/r/$base_a" "$WORK/r/$base_a.sig"
refused "an architecture missing" podup v1.2.3 "$WORK/r" "carries 1 .rpm file(s) and the contract names 2"
copy "$WORK/base"; echo notes > "$WORK/r/components.txt"
refused "a file the contract does not name" podup v1.2.3 "$WORK/r" "components.txt is not an .rpm"
copy "$WORK/base"; fx_rpm "$WORK/r" podup 1.2.3 1.glyndor.any ppc64le provides=podup; fx_sign "$WORK/r/podup-1.2.3-1.glyndor.any.ppc64le.rpm"
refused "a package of another architecture" podup v1.2.3 "$WORK/r" "contract names 2"
copy "$WORK/base"; rm "$WORK/r/$base_a" "$WORK/r/$base_a.sig"; cp "$WORK/base/$base_x" "$WORK/r/podup-1.2.3-1.glyndor.any.s390x.rpm"
fx_sign "$WORK/r/podup-1.2.3-1.glyndor.any.s390x.rpm"
refused "an architecture the product does not declare" podup v1.2.3 "$WORK/r" "is not a file the contract names"
copy "$WORK/base"; rm "$WORK/r/$base_a" "$WORK/r/$base_a.sig"; cp "$WORK/base/$base_x" "$WORK/r/$base_a"; fx_sign "$WORK/r/$base_a"
refused "one signed package attached under both architecture names" podup v1.2.3 "$WORK/r" "declares the architecture"
fx_static_release "$WORK/old" podup 1.2.2 x86_64,aarch64
refused "the packages of an older release under a newer tag" podup v1.2.3 "$WORK/old" "is not a file the contract names"
refused "the same files under an older tag" podup v1.2.1 "$WORK/base" "is not a file the contract names"
refused "a package of another product" podup v1.2.3 "$WORK/podman" "contract names 2"
copy "$WORK/base"; mv "$WORK/r/$base_x" "$WORK/r/podup-1.2.3-1.glyndor.el9.x86_64.rpm"; mv "$WORK/r/$base_x.sig" "$WORK/r/podup-1.2.3-1.glyndor.el9.x86_64.rpm.sig"
refused "a package renamed for another distribution" podup v1.2.3 "$WORK/r" "is not a file the contract names"
copy "$WORK/base"; cp "$WORK/r/$base_x" "$WORK/r/podup-1.2.3-1.glyndor.any.x86_64.rpm.bak"
refused "a copy of a package under another extension" podup v1.2.3 "$WORK/r" "podup-1.2.3-1.glyndor.any.x86_64.rpm.bak is not an .rpm"
copy "$WORK/base"; rm "$WORK/r/$base_x"
refused "a signature with no package" podup v1.2.3 "$WORK/r" "carries 1 .rpm"
copy "$WORK/base"; head -c 64 /dev/zero > "$WORK/r/stray.rpm.sig"
refused "a signature with no package, with the count of packages right" podup v1.2.3 "$WORK/r" "a signature names no package here"
copy "$WORK/base"; touch "$WORK/r/stray.rpm.mldsa65.sig"
refused "a second signature with no package" podup v1.2.3 "$WORK/r" "names no package of this release"

# --- names and file types ---------------------------------------------------------------------
copy "$WORK/base"; rm "$WORK/r/$base_x"; ln -s "$WORK/base/$base_x" "$WORK/r/$base_x"
refused "a symbolic link in place of a package" podup v1.2.3 "$WORK/r" "is not a regular file"
copy "$WORK/base"; rm "$WORK/r/$base_x.sig"; ln -s "$WORK/base/$base_x.sig" "$WORK/r/$base_x.sig"
refused "a symbolic link in place of a signature" podup v1.2.3 "$WORK/r" "is not a regular file"
copy "$WORK/base"; mkdir "$WORK/r/sub"
refused "a folder inside the release" podup v1.2.3 "$WORK/r" "is not a regular file"
copy "$WORK/base"; cp "$WORK/r/$base_x" "$WORK/r/pod up.rpm"
refused "a name with a space" podup v1.2.3 "$WORK/r" "outside the closed alphabet"
copy "$WORK/base"; cp "$WORK/r/$base_x" "$WORK/r/a;b.rpm"
refused "a name with a semicolon" podup v1.2.3 "$WORK/r" "outside the closed alphabet"
copy "$WORK/base"; cp "$WORK/r/$base_x" "$WORK/r/a..b.rpm"
refused "a name with two dots in a row" podup v1.2.3 "$WORK/r" "outside the closed alphabet"
ln -s "$WORK/base" "$WORK/linkdir"
refused "a release directory that is a link" podup v1.2.3 "$WORK/linkdir" "is not a directory"
refused "a release directory that is missing" podup v1.2.3 "$WORK/nowhere" "is not a directory"

# --- sizes -------------------------------------------------------------------------------------
out="$(ADMIT_MAX_RPM_BYTES=1000 admit podup v1.2.3 "$WORK/base")"; rc=$?
check "a package over the size cap is refused" 1 "$rc"
check "and the cap is named" 1 "$(printf '%s' "$out" | grep -c 'byte package cap')"

# --- tags and products ---------------------------------------------------------------------
for tag in v1.2 1.2.3 v1.2.3-rc1 v1.2.3+r2 main 'v1.2.3;x' ''; do
	refused "the tag '$tag' of a static product" podup "$tag" "$WORK/base" "is not vX.Y.Z"
done
refused "the tag of a podman release with a bad revision" podman v6.2.0+rX "$WORK/podman" "is not vX.Y.Z or vX.Y.Z+rN"
refused "a product that is not in the channel" nginx v1.2.3 "$WORK/base" "is not a product of this channel"
refused "a missing argument" podup v1.2.3 "" "is not a directory"
out="$("$ADMIT" podup v1.2.3 2>&1)"; check "too few arguments are refused" 1 "$?"
out="$("$ADMIT" --keyring "$WORK/keyring" podup v1.2.3 "$WORK/base" extra 2>&1)"; check "too many arguments are refused" 1 "$?"
check "and the usage is said" 1 "$(printf '%s' "$out" | grep -c 'usage: admit-release.sh')"
out="$("$ADMIT" --nonsense podup v1.2.3 "$WORK/base" 2>&1)"; check "an unknown option is refused" 1 "$?"

# --- the list of products that need the second signature fails closed ----------------------------------
for kind in missing directory link entry; do
	rm -rf "$WORK/kp"; cp -r "$WORK/keyring" "$WORK/kp"
	case "$kind" in
		missing) rm "$WORK/kp/pq-required-products" ;;
		directory) rm "$WORK/kp/pq-required-products"; mkdir "$WORK/kp/pq-required-products" ;;
		link) mv "$WORK/kp/pq-required-products" "$WORK/kp/real"; ln -s real "$WORK/kp/pq-required-products" ;;
		entry) printf 'nginx\n' > "$WORK/kp/pq-required-products" ;;
	esac
	out="$("$ADMIT" --keyring "$WORK/kp" podup v1.2.3 "$WORK/base" 2>&1)"; rc=$?
	check "a required list that is a $kind is refused" 1 "$rc"
	check "and says why ($kind)" 1 "$(printf '%s' "$out" | grep -c -E 'not a readable regular file|not a product of config/products.txt')"
done

# --- a config that is not all there ---------------------------------------------------------------
mkdir "$WORK/cfg"; cp "$HERE/config/"* "$WORK/cfg/"; rm "$WORK/cfg/products.txt"
out="$("$ADMIT" --config "$WORK/cfg" --keyring "$WORK/keyring" podup v1.2.3 "$WORK/base" 2>&1)"; rc=$?
check "a missing products file is refused" 1 "$rc"
check "and said to be missing" 1 "$(printf '%s' "$out" | grep -c 'products.txt is missing')"
rm "$WORK/cfg/relations.txt"; cp "$HERE/config/products.txt" "$WORK/cfg/"
out="$("$ADMIT" --config "$WORK/cfg" --keyring "$WORK/keyring" podup v1.2.3 "$WORK/base" 2>&1)"; rc=$?
check "a missing relations file is refused" 1 "$rc"
check "and said to be missing" 1 "$(printf '%s' "$out" | grep -c 'relations.txt is missing')"
out="$("$ADMIT" --config "$WORK/cfg" --keyring "$WORK/keyring" podman v6.2.0+r12 "$WORK/podman" 2>&1)"; rc=$?
check "a missing Podman set is refused" 1 "$rc"

mkdir "$WORK/cfg2"; cp "$HERE/config/"* "$WORK/cfg2/"; sed -i 's/^podup\tstatic/podup\tweird/' "$WORK/cfg2/products.txt"
out="$("$ADMIT" --config "$WORK/cfg2" --keyring "$WORK/keyring" podup v1.2.3 "$WORK/base" 2>&1)"; rc=$?
check "a product of an unknown kind is refused" 1 "$rc"
check "and the kind is named" 1 "$(printf '%s' "$out" | grep -c "the kind 'weird'")"

for bad in 's/^fc45\tpodman\tarch\t5/fc45\tpodman\tarch\tx/' 's/^fc45\tpodman\t/fc45\tPodman\t/' 's/^fc45\tpodman\tarch\t5\tcore/fc45\tpodman\tarch\t5\tweird/'; do
	rm -rf "$WORK/cfg3"; mkdir "$WORK/cfg3"; cp "$HERE/config/"* "$WORK/cfg3/"; sed -i "$bad" "$WORK/cfg3/podman-packages.txt"
	out="$("$ADMIT" --config "$WORK/cfg3" --keyring "$WORK/keyring" podman v6.2.0+r12 "$WORK/podman" 2>&1)"; rc=$?
	check "a damaged Podman set row ($bad) is refused" 1 "$rc"
	check "and said to be damaged" 1 "$(printf '%s' "$out" | grep -c -E 'malformed row|unknown version rule')"
done

rm -rf "$WORK/cfg4"; mkdir "$WORK/cfg4"; cp "$HERE/config/"* "$WORK/cfg4/"; sed -i '/^static\tprovides\t/d' "$WORK/cfg4/relations.txt"
out="$("$ADMIT" --config "$WORK/cfg4" --keyring "$WORK/keyring" podup v1.2.3 "$WORK/base" 2>&1)"; rc=$?
check "a relations file with no rule for a kind is refused" 1 "$rc"
check "and says which rule" 1 "$(printf '%s' "$out" | grep -c "has no provides rule, or no form of it, for the kind 'static'")"

# --- the floor of a product -----------------------------------------------------------------------
fl() { # <floor dir> <product> <tag> <dir>
	"$ADMIT" --config "$1" --keyring "$WORK/keyring" "$2" "$3" "$4" 2>&1
}
rm -rf "$WORK/f1"; mkdir "$WORK/f1"; cp "$HERE/config/"* "$WORK/f1/"; printf 'podup v1.2.4\nepistle v9.0.0\n' >> "$WORK/f1/floor.txt"
out="$(fl "$WORK/f1" podup v1.2.3 "$WORK/base")"; rc=$?
check "a release lower than the floor of its product is refused" 1 "$rc"
check "and says which floor" 1 "$(printf '%s' "$out" | grep -c 'v1.2.3 is lower than v1.2.4')"
fx_static_release "$WORK/high" podup 1.2.4 x86_64,aarch64
out="$(fl "$WORK/f1" podup v1.2.4 "$WORK/high")"; check "a release equal to the floor is admitted" 0 "$?"
fx_static_release "$WORK/higher" podup 1.10.0 x86_64,aarch64
out="$(fl "$WORK/f1" podup v1.10.0 "$WORK/higher")"; check "one higher is admitted, 1.10 being above 1.4 as a number" 0 "$?"
rm -rf "$WORK/f2"; mkdir "$WORK/f2"; cp "$HERE/config/"* "$WORK/f2/"; printf 'podman v6.2.0+r12\n' >> "$WORK/f2/floor.txt"
out="$(fl "$WORK/f2" podman v6.2.0+r11 "$WORK/podman")"; check "a revision below the floor is refused" 1 "$?"
out="$(fl "$WORK/f2" podman v6.2.0+r12 "$WORK/podman")"; check "the revision of the floor is admitted" 0 "$?"
rm -rf "$WORK/f3"; mkdir "$WORK/f3"; cp "$HERE/config/"* "$WORK/f3/"; printf 'podman v6.2.0\n' >> "$WORK/f3/floor.txt"
out="$(fl "$WORK/f3" podman v6.2.0+r12 "$WORK/podman")"; check "a tag without a revision is revision 1: +r12 is above it" 0 "$?"
for bad in 'podup' 'podup main' 'podup v1.2' 'podup v1.2.3 extra'; do
	rm -rf "$WORK/f4"; mkdir "$WORK/f4"; cp "$HERE/config/"* "$WORK/f4/"; printf '%s\n' "$bad" >> "$WORK/f4/floor.txt"
	out="$(fl "$WORK/f4" podup v1.2.3 "$WORK/base")"; rc=$?
	check "a floor line '$bad' is refused" 1 "$rc"
	check "as malformed" 1 "$(printf '%s' "$out" | grep -c 'floor.txt has a malformed line')"
done
for kind in missing link directory unknown; do
	rm -rf "$WORK/f5"; mkdir "$WORK/f5"; cp "$HERE/config/"* "$WORK/f5/"
	case "$kind" in
		missing) rm "$WORK/f5/floor.txt" ;;
		link) mv "$WORK/f5/floor.txt" "$WORK/f5/real"; ln -s real "$WORK/f5/floor.txt" ;;
		directory) rm "$WORK/f5/floor.txt"; mkdir "$WORK/f5/floor.txt" ;;
		unknown) printf 'nginx v9.9.9\n' >> "$WORK/f5/floor.txt" ;;
	esac
	out="$(fl "$WORK/f5" podup v1.2.3 "$WORK/base")"; rc=$?
	check "a floor file that is $kind is refused" 1 "$rc"
	check "and says why ($kind)" 1 "$(printf '%s' "$out" | grep -c -E 'not a readable regular file|which is not a product of config/products.txt')"
done
rm -rf "$WORK/f6"; mkdir "$WORK/f6"; cp "$HERE/config/"* "$WORK/f6/"; printf 'podup v1.2.4' >> "$WORK/f6/floor.txt"
out="$(fl "$WORK/f6" podup v1.2.3 "$WORK/base")"; rc=$?
check "the last line of the floor is read when it has no line feed" 1 "$rc"
check "and holds the release back" 1 "$(printf '%s' "$out" | grep -c 'is lower than v1.2.4')"
check "the committed floor is empty today" 0 "$(grep -vcE '^[[:space:]]*(#|$)' "$HERE/config/floor.txt")"

# --- the Podman set ---------------------------------------------------------------------------
copy "$WORK/podman"; rm "$WORK/r/podmansh-6.2.0+r12-12.glyndor.fc45.noarch.rpm"*
refused "a Podman release missing one package" podman v6.2.0+r12 "$WORK/r" "carries"
copy "$WORK/podman"; cp "$WORK/r/crun-1.31-12.glyndor.leap161.x86_64.rpm" "$WORK/r/crun-1.31-12.glyndor.fc45.x86_64.rpm"
fx_sign "$WORK/r/crun-1.31-12.glyndor.fc45.x86_64.rpm"
refused "an extra of another distribution" podman v6.2.0+r12 "$WORK/r" "carries"
copy "$WORK/podman"; mv "$WORK/r/podman-6.2.0+r12-12.glyndor.el9.x86_64.rpm" "$WORK/r/podman-6.2.0+r12-12.glyndor.el8.x86_64.rpm"
mv "$WORK/r/podman-6.2.0+r12-12.glyndor.el9.x86_64.rpm.sig" "$WORK/r/podman-6.2.0+r12-12.glyndor.el8.x86_64.rpm.sig"
refused "a package for a distribution that is not served" podman v6.2.0+r12 "$WORK/r" "is not a file the contract names"
copy "$WORK/podman"; rm "$WORK/r/podmansh-6.2.0+r12-12.glyndor.fc45.noarch.rpm"*; cp "$WORK/r/crun-1.31-12.glyndor.leap161.x86_64.rpm" "$WORK/r/crun-1.32-12.glyndor.leap161.x86_64.rpm"
fx_sign "$WORK/r/crun-1.32-12.glyndor.leap161.x86_64.rpm"; cp "$WORK/r/crun-1.31-12.glyndor.leap161.x86_64.rpm.sig" "$WORK/r/crun-1.32-12.glyndor.leap161.x86_64.rpm.sig"
refused "two files for one package of the set, with the count unchanged" podman v6.2.0+r12 "$WORK/r" "two files stand for crun leap161 x86_64"
refused "a Podman set under the tag of another revision" podman v6.2.0+r11 "$WORK/podman" "is not a file the contract names"

# --- the file is the one that was verified --------------------------------------------------------
mkdir "$WORK/bin"
cat > "$WORK/bin/rpm" <<'SH'
#!/bin/sh
# Changes the package after the signature was checked and before it is trusted.
case "$*" in *-qp*) for f in "$FX_TOUCH_DIR"/*.rpm; do printf 'x' >> "$f"; done ;; esac
exec /usr/bin/rpm "$@"
SH
chmod +x "$WORK/bin/rpm"
copy "$WORK/base"
out="$(FX_TOUCH_DIR="$WORK/r" PATH="$WORK/bin:$PATH" admit podup v1.2.3 "$WORK/r")"; rc=$?
check "a package changed after its signature was checked is refused" 1 "$rc"
check "and said to have changed" 1 "$(printf '%s' "$out" | grep -c 'changed while it was being verified')"
mkdir -p "$WORK/bin3"
cat > "$WORK/bin3/rpm" <<'SH'
#!/bin/sh
# an rpm that does not know the format tag, like rpm 4.16
case "$*" in --querytags) /usr/bin/rpm --querytags | grep -vx RPMFORMAT ;; *) exec /usr/bin/rpm "$@" ;; esac
SH
chmod +x "$WORK/bin3/rpm"
out="$(PATH="$WORK/bin3:$PATH" admit podup v1.2.3 "$WORK/base")"; rc=$?
check "an rpm that does not know the format tag is refused" 1 "$rc"
check "and says what to run it with" 1 "$(printf '%s' "$out" | grep -c 'does not know the RPMFORMAT tag; run the admission with rpm 6 or later')"
# --- paths are compared in canonical form -----------------------------------------------------------------
mkdir -p "$WORK/bin4"
cat > "$WORK/bin4/rpm" <<'SH'
#!/bin/sh
# answers like rpm, except for the list of files, which is the one in $FX_PATHS
# (each line is given the permissions rpm prints before it, and the count of entries is the count of lines)
case "$*" in
	*arraysize*FILENAMES* | *FILENAMES:arraysize*) printf '%b\n' "$FX_PATHS" | wc -l ;;
	*FILEUSERNAME:arraysize*) printf '%b\n' "$FX_PATHS" | wc -l ;;
	*FILEUSERNAME*) printf '%b\n' "$FX_PATHS" | sed 's/.*/root|root/' ;;
	*FILELINKTOS:arraysize*) printf '%b\n' "$FX_PATHS" | wc -l ;;
	*FILELINKTOS*) printf '%b\n' "$FX_PATHS" | sed 's/.*/E/' ;;
	*FILENAMES*) printf '%b\n' "$FX_PATHS" | sed 's/^/-rw-r--r-- /' ;;
	*) exec /usr/bin/rpm "$@" ;;
esac
SH
chmod +x "$WORK/bin4/rpm"
paths_case() { # <paths as printf %b text> -> the exit status of the admission
	copy "$WORK/base"; FX_PATHS="$1" PATH="$WORK/bin4:$PATH" admit podup v1.2.3 "$WORK/r" > "$WORK/pout"; echo $?
}
for bad in '//usr/bin/podup' '/usr/bin//podup' '/usr/bin/../../etc/shadow' '/usr/bin/./podup' 'usr/bin/podup' '/usr/bin/podup/..' '/usr/bin/podup\001' '/usr/bin/podup\n/usr/bin/../x' '/sbin/podup' '/usr/bin/podupx'; do
	check "the path '$bad' is refused" 1 "$(paths_case "$bad")"
done
check "and a non canonical path is said to be" 1 "$(paths_case '/usr/bin/../../etc/shadow' > /dev/null; grep -c 'not in canonical form' "$WORK/pout")"
for good in '/usr/bin/podup' '/bin/podup' '/lib/podup/x' '/lib64/podup/x' '/usr/share/licenses/podup/LICENSE' '/usr/lib/systemd/system/podup.service' '/etc/podup/podup.conf'; do
	check "the path '$good' is admitted" 0 "$(paths_case "$good")"
done

mkdir "$WORK/bin2"
cat > "$WORK/bin2/rpm" <<'SH'
#!/bin/sh
# answers like rpm, with one more line in the header than was asked for
out="$(/usr/bin/rpm "$@")"
case "$*" in *RPMFORMAT*) printf '%s\nanother line\n' "$out" ;; *) printf '%s\n' "$out" ;; esac
SH
chmod +x "$WORK/bin2/rpm"
copy "$WORK/base"
out="$(PATH="$WORK/bin2:$PATH" admit podup v1.2.3 "$WORK/r")"; rc=$?
check "a header with a field that spans lines is refused" 1 "$rc"
check "and says so" 1 "$(printf '%s' "$out" | grep -c 'has a field that spans lines')"
copy "$WORK/base"; printf 'not an rpm at all' > "$WORK/r/$base_x"; fx_sign "$WORK/r/$base_x"
refused "a signed file that is not a package" podup v1.2.3 "$WORK/r" "does not start with the lead of an rpm package"
copy "$WORK/base"; printf '/etc/passwd\n/etc/shadow\n' > "$WORK/r/$base_x"; fx_sign "$WORK/r/$base_x"
refused "a signed list of paths, which rpm -qp would read as a manifest" podup v1.2.3 "$WORK/r" "does not start with the lead of an rpm package"
cat > "$WORK/bin2/rpm" <<'SH'
#!/bin/sh
# records every package query, then answers like rpm
case "$*" in *-qp*) printf '%s\n' "$*" >> "$FX_RPM_LOG" ;; esac
exec /usr/bin/rpm "$@"
SH
copy "$WORK/base"; : > "$WORK/rpmlog"
FX_RPM_LOG="$WORK/rpmlog" PATH="$WORK/bin2:$PATH" admit podup v1.2.3 "$WORK/r" > /dev/null
check "rpm -qp is called for each package and each of its questions" 110 "$(grep -c . "$WORK/rpmlog")"
check "and never without --nomanifest" 0 "$(grep -vc -- '--nomanifest' "$WORK/rpmlog")"
cat > "$WORK/bin2/rpm" <<'SH'
#!/bin/sh
# fails the question about what the package provides, or answers it with nothing
case "$*" in
	*PROVIDENAME:arraysize*) [ "$FX_PROV" = fail ] && exit 1; [ "$FX_PROV" = empty ] && { echo '(none)'; exit 0; } ;;
	*PROVIDENAME*) [ "$FX_PROV" = fail ] && exit 1; [ "$FX_PROV" = empty ] && exit 0 ;;
esac
exec /usr/bin/rpm "$@"
SH
copy "$WORK/base"
out="$(FX_PROV=fail PATH="$WORK/bin2:$PATH" admit podup v1.2.3 "$WORK/r")"; rc=$?
check "an rpm that fails to list what a package provides is refused" 1 "$rc"
check "and says it cannot read it" 1 "$(printf '%s' "$out" | grep -c 'cannot count the entries of PROVIDENAME')"
out="$(FX_PROV=empty PATH="$WORK/bin2:$PATH" admit podup v1.2.3 "$WORK/r")"; rc=$?
check "a package that provides nothing, not even itself, is refused" 1 "$rc"
check "and says so" 1 "$(printf '%s' "$out" | grep -c 'does not provide its own name')"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
