#!/usr/bin/env bash
#
# The second independent review of scripts/verify/admit-release.sh, one attack each: the comparison and the version of
# a relation, the size of what a package unpacks to, the floor read as rpm reads versions, the set of scriptlet tags, a
# hidden file, the way rpm is called, and the alphabet of a path.
# Requires: rpm (rpmbuild, rpm2cpio), python3 with cryptography.
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
# the Podman cases attack one package at a time, so they build and admit one id (the whole set is admitted in admit-release.test.sh)
export FX_ONLY_ID=el9
fx_trimmed_config "$WORK/cfgq" el9
REAL_ADMIT="$ADMIT"; ADMIT="$WORK/admit-q.sh"
printf '#!/bin/sh\nexec "%s" --config "%s" "$@"\n' "$REAL_ADMIT" "$WORK/cfgq" > "$ADMIT"; chmod +x "$ADMIT"
SRC="podup-1.2.3-1.glyndor.any.x86_64.rpm"
fx_static_release "$WORK/base" podup 1.2.3 x86_64,aarch64
P=(podup 1.2.3 1.glyndor.any x86_64)
variant() { # <release dir> <file the contract expects> <package fields...>
	local dir="$1" file="$2"; shift 2
	rm -rf "$WORK/v"; cp -r "$dir" "$WORK/v"; mkdir -p "$WORK/mk"; rm -f "${WORK:?}/mk"/*
	fx_rpm "$WORK/mk" "$@" || return 1
	rm -f "$WORK/v/$file" "$WORK/v/$file.sig"; mv "$WORK/mk"/*.rpm "$WORK/v/$file"; fx_sign "$WORK/v/$file"
}
run() { rc=0; out="$("$ADMIT" "$@" 2>&1)" || rc=$?; }
refused() { # <description> <fragment> <admit arguments...>
	local d="$1" f="$2"; shift 2
	run "$@"; check "$d: refused" 1 "$rc"; check "$d: says why" 1 "$(printf '%s' "$out" | grep -cF -- "$f")"
}
V=(--keyring "$WORK/keyring")

# --- 1 and 2: the comparison and the version of a relation ------------------------------------------------------
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup requires=ca-certificates
run "${V[@]}" podup v1.2.3 "$WORK/v"; check "a plain Requires on a product's list is admitted" 0 "$rc"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup "requires=ca-certificates <= 2020.2;"
refused "a Requires with an upper bound that would force an old version" "not a name, a comparison and a version" "${V[@]}" podup v1.2.3 "$WORK/v"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup "requires=ca-certificates >= 2020.2;"
refused "even a lower bound, for a kind that names no version" "not a name, a comparison and a version" "${V[@]}" podup v1.2.3 "$WORK/v"
variant "$WORK/base" "$SRC" "${P[@]}" "provides=podup;podup = 99.0"
refused "a Provides of its own name with another version" "own name" "${V[@]}" podup v1.2.3 "$WORK/v"
variant "$WORK/base" "$SRC" "${P[@]}" "provides=podup;podup(x86-64) = 99.0"
refused "a Provides of its own architecture name with another version" "own name" "${V[@]}" podup v1.2.3 "$WORK/v"
fx_podman_release "$WORK/podman" 6.2.0 12
PF="podman-6.2.0+r12-12.glyndor.el9.x86_64.rpm"
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman "requires=crun >= 1.21;"
run "${V[@]}" podman v6.2.0+r12 "$WORK/v"; check "podman may require crun with a lower bound" 0 "$rc"
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman "requires=crun <= 1.0;"
refused "podman requiring crun with an upper bound" "not a name, a comparison and a version" "${V[@]}" podman v6.2.0+r12 "$WORK/v"
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman "obsoletes=netavark = 1.0;"
refused "an Obsoletes with a version, which the contract writes without one" "not a name, a comparison and a version" "${V[@]}" podman v6.2.0+r12 "$WORK/v"

# --- 3: what a package unpacks to ---------------------------------------------------------------------------------
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup bigfile=/usr/lib/podup/zeros:4194304
ADMIT_MAX_PAYLOAD_BYTES=1048576 run "${V[@]}" podup v1.2.3 "$WORK/v"
check "a package that unpacks to 4 MiB under a ceiling of 1 MiB is refused" 1 "$rc"
check "and says it would install more than the ceiling" 1 "$(printf '%s' "$out" | grep -cE 'would install|unpacks to more')"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup bigfile=/usr/lib/podup/zeros:65536
ADMIT_MAX_PAYLOAD_BYTES=1048576 run "${V[@]}" podup v1.2.3 "$WORK/v"; check "and a package of 64 KiB under the same ceiling is admitted" 0 "$rc"
# the header says what the signer wrote: one that lies about its size does not escape the reading of the payload
cp "$WORK/v/$SRC" "$WORK/lie.rpm"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup bigfile=/usr/lib/podup/zeros:4194304
python3 -I -c 'import sys; p=sys.argv[1]; b=open(p,"rb").read(); print(b.count((4194304).to_bytes(4,"big")))' "$WORK/v/$SRC" > "$WORK/count"
check "the size is written in the header, where a signer can lie about it, so the payload is read too" 1 "$([ "$(cat "$WORK/count")" -ge 1 ] && echo 1 || echo 0)"
python3 -I -c 'import sys; p=sys.argv[1]; b=open(p,"rb").read(); open(p,"wb").write(b.replace((4194304).to_bytes(4,"big"), (4096).to_bytes(4,"big")))' "$WORK/v/$SRC"
rm -f "$WORK/v/$SRC.sig"; fx_sign "$WORK/v/$SRC"
ADMIT_MAX_PAYLOAD_BYTES=1048576 run "${V[@]}" podup v1.2.3 "$WORK/v"
check "a header that says 4 KiB over a payload of 4 MiB is refused all the same" 1 "$rc"

# --- 5: the floor, as rpm orders versions -------------------------------------------------------------------------
rm -rf "${WORK:?}/cfg"; mkdir "$WORK/cfg"; cp "$WORK/cfgq/"* "$WORK/cfg/"
fx_podman_release "$WORK/p10" 6.2.0 10; fx_podman_release "$WORK/p9" 6.2.0 9
printf 'podman\tv6.2.0+r9\n' >> "$WORK/cfg/floor.txt"
run --config "$WORK/cfg" "${V[@]}" podman v6.2.0+r10 "$WORK/p10"; check "r10 over a floor of r9 is admitted" 0 "$rc"
run --config "$WORK/cfg" "${V[@]}" podman v6.2.0+r9 "$WORK/p9"; check "r9 on a floor of r9 is admitted" 0 "$rc"
cp "$HERE/config/floor.txt" "$WORK/cfg/floor.txt"; printf 'podman\tv6.2.0+r10\n' >> "$WORK/cfg/floor.txt"
refused "r9 under a floor of r10, which a number written the other way would let through" "is lower than" --config "$WORK/cfg" "${V[@]}" podman v6.2.0+r9 "$WORK/p9"
cp "$HERE/config/floor.txt" "$WORK/cfg/floor.txt"; printf 'podman\tv6.2.0+r19\n' >> "$WORK/cfg/floor.txt"
fx_podman_release "$WORK/p20" 6.2.0 20
run --config "$WORK/cfg" "${V[@]}" podman v6.2.0+r20 "$WORK/p20"; check "r20 over a floor of r19 is admitted" 0 "$rc"
cp "$HERE/config/floor.txt" "$WORK/cfg/floor.txt"; printf 'podman\tv6.2.0\n' >> "$WORK/cfg/floor.txt"
run --config "$WORK/cfg" "${V[@]}" podman v6.2.0+r10 "$WORK/p10"; check "a revision over the same version without one is admitted" 0 "$rc"

# an rpm that cannot compare (its --eval fails) must not read as "not lower than the floor"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/rpm" <<'SH'
#!/bin/sh
case "$*" in *--eval*) exit 1 ;; *) exec /usr/bin/rpm "$@" ;; esac
SH
chmod +x "$WORK/bin/rpm"
cp "$HERE/config/floor.txt" "$WORK/cfg/floor.txt"; printf 'podman\tv6.2.0+r10\n' >> "$WORK/cfg/floor.txt"
PATH="$WORK/bin:$PATH" run --config "$WORK/cfg" "${V[@]}" podman v6.2.0+r9 "$WORK/p9"
check "a floor that rpm cannot compare against is a refusal, not a pass" 1 "$rc"
check "and says rpm cannot compare" 1 "$(printf '%s' "$out" | grep -c 'rpm cannot compare')"
run --config "$WORK/cfg" "${V[@]}" podman v6.2.0+r9 "$WORK/p9"
check "the same release with a working rpm is refused for being lower, which is what the stub hid" 1 "$rc"
check "and says so" 1 "$(printf '%s' "$out" | grep -c 'is lower than')"

# --- 7: the set of scriptlet tags ----------------------------------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/rpm" <<'SH'
#!/bin/sh
# an rpm that does not know one scriptlet tag, as an old one does not know %preuntrans
case "$*" in --querytags) /usr/bin/rpm --querytags | grep -vx "$FX_DROP_TAG" ;; *) exec /usr/bin/rpm "$@" ;; esac
SH
chmod +x "$WORK/bin/rpm"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup
FX_DROP_TAG=PREUNTRANS PATH="$WORK/bin:$PATH" run "${V[@]}" podup v1.2.3 "$WORK/v"
check "an rpm without the tag %preuntrans is refused, by name and not by count" 1 "$rc"
check "and says which tag it lacks" 1 "$(printf '%s' "$out" | grep -c 'does not know the scriptlet tag PREUNTRANS')"

# --- the scriptlets and the triggers of every kind are refused unless their text is listed, by rpm's own listing ---------
for f in pre post preun postun pretrans posttrans verifyscript preuntrans postuntrans; do
	variant "$WORK/base" "$SRC" "${P[@]}" provides=podup "$f=true"
	refused "an unlisted %$f" "does not list for 'static'" "${V[@]}" podup v1.2.3 "$WORK/v"
done
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup trigger=bash
refused "a trigger" "trigger" "${V[@]}" podup v1.2.3 "$WORK/v"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup filetrigger=/usr/lib
refused "a file trigger" "file trigger" "${V[@]}" podup v1.2.3 "$WORK/v"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup
: > "$WORK/rpmlog"
run "${V[@]}" podup v1.2.3 "$WORK/v"; check "a package with no scriptlet is admitted, and rpm's listing of them was asked for" 0 "$rc"
# a reading of this admission that misses a scriptlet (here, one that always answers "absent") is caught by rpm's own listing
cat > "$WORK/bin/rpm" <<'SH'
#!/bin/sh
case "$*" in *PROG:arraysize*) printf '(none)' ;; *'%|'*'?{P'*) printf A ;; *) exec /usr/bin/rpm "$@" ;; esac
SH
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup post=true
PATH="$WORK/bin:$PATH" run "${V[@]}" podup v1.2.3 "$WORK/v"
check "a reader that misses a %post is overruled by rpm's own listing" 1 "$rc"
check "and the refusal says rpm lists a scriptlet that was not read" 1 "$(printf '%s' "$out" | grep -c "rpm lists 1 scriptlet(s)")"

# --- 8: a hidden file ---------------------------------------------------------------------------------------------
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup
printf 'x' > "$WORK/v/.x.rpm.mldsa65.sig"
refused "a hidden signature that names no package" "closed alphabet" "${V[@]}" podup v1.2.3 "$WORK/v"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup
head -c 2000000 /dev/zero > "$WORK/v/.big"
refused "a hidden file of two megabytes" "closed alphabet" "${V[@]}" podup v1.2.3 "$WORK/v"

# --- 10: the way rpm is called -------------------------------------------------------------------------------------
cat > "$WORK/bin/rpm" <<'SH'
#!/bin/sh
case "$*" in *-qp*) printf '%s\n' "$*" >> "$FX_RPM_LOG" ;; esac
exec /usr/bin/rpm "$@"
SH
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup
: > "$WORK/rpmlog"
FX_RPM_LOG="$WORK/rpmlog" PATH="$WORK/bin:$PATH" run "${V[@]}" podup v1.2.3 "$WORK/v"
check "the package is admitted when rpm is called that way" 0 "$rc"
check "every question to rpm runs with no plugin" 0 "$(grep -vc -- '--noplugins' "$WORK/rpmlog")"
check "and with no macro file of the machine" 0 "$(grep -vc -- '--macros /dev/null' "$WORK/rpmlog")"
check "and with no rpmrc of the machine" 0 "$(grep -vc -- '--rcfile /dev/null' "$WORK/rpmlog")"

# --- 11: the alphabet of a path ------------------------------------------------------------------------------------
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup file=/usr/lib/podup/a+b
run "${V[@]}" podup v1.2.3 "$WORK/v"; check "a path with a plus is admitted" 0 "$rc"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup file=/usr/lib/podup/a,b
refused "a path with a comma" "is not a whole record" "${V[@]}" podup v1.2.3 "$WORK/v"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup file='/usr/lib/podup/a#b'
refused "a path with a hash" "is not a whole record" "${V[@]}" podup v1.2.3 "$WORK/v"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
