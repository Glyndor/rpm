#!/usr/bin/env bash
#
# What scripts/verify/admit-release.sh reads inside a package that the release key signed: a
# valid signature says who made the bytes, not that the header is the product's. Each case builds
# a package whose header differs from the contract in one field and gives it the file name the
# contract expects, so that only the header can stop it.
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
# the Podman cases attack one package at a time, so they build and admit one id (the whole set is admitted in admit-release.test.sh)
export FX_ONLY_ID=el9
fx_trimmed_config "$WORK/cfgq" el9
REAL_ADMIT="$ADMIT"; ADMIT="$WORK/admit-q.sh"
printf '#!/bin/sh\nexec "%s" --config "%s" "$@"\n' "$REAL_ADMIT" "$WORK/cfgq" > "$ADMIT"; chmod +x "$ADMIT"
SRC="podup-1.2.3-1.glyndor.any.x86_64.rpm"
fx_static_release "$WORK/base" podup 1.2.3 x86_64,aarch64
fx_podman_release "$WORK/podman" 6.2.0 12

# variant <release dir> <file name the contract expects> <name> <version> <release> <arch> [fields]
# replaces that file by a package whose header says something else, and signs it again.
variant() {
	local dir="$1" file="$2"; shift 2
	rm -rf "$WORK/v"; cp -r "$dir" "$WORK/v"; mkdir -p "$WORK/mk"; rm -f "${WORK:?}/mk"/*
	fx_rpm "$WORK/mk" "$@" || return 1
	rm -f "$WORK/v/$file" "$WORK/v/$file.sig"
	mv "$WORK/mk"/*.rpm "$WORK/v/$file"; fx_sign "$WORK/v/$file"
}
verdict() { # <description> <product> <tag> <fragment of the message> ; runs on $WORK/v
	local out rc=0
	out="$("$ADMIT" --keyring "$WORK/keyring" "$2" "$3" "$WORK/v" 2>&1)" || rc=$?
	check "$1: refused" 1 "$rc"
	check "$1: says why" 1 "$(printf '%s' "$out" | grep -cF -- "$4")"
}
accepted() { # <description> <product> <tag> ; runs on $WORK/v
	"$ADMIT" --keyring "$WORK/keyring" "$2" "$3" "$WORK/v" > "$WORK/out" 2>&1; check "$1: admitted" 0 "$?"
}
P=(podup 1.2.3 1.glyndor.any x86_64)

variant "$WORK/base" "$SRC" "${P[@]}" provides=podup; accepted "the exact package" podup v1.2.3
variant "$WORK/base" "$SRC" "${P[@]}" provides="podup podup(x86-64) config(podup)"; accepted "its own relations only" podup v1.2.3
variant "$WORK/base" "$SRC" "${P[@]}" vendor=Debian provides=podup; verdict "a false vendor" podup v1.2.3 "declares the vendor 'Debian'"
variant "$WORK/base" "$SRC" "${P[@]}" vendor= provides=podup; verdict "no vendor" podup v1.2.3 "declares the vendor '(none)'"
variant "$WORK/base" "$SRC" "${P[@]}" packager="Someone <a@b.c>" provides=podup; verdict "a false packager" podup v1.2.3 "declares the packager"
variant "$WORK/base" "$SRC" "${P[@]}" packager= provides=podup; verdict "no packager" podup v1.2.3 "declares the packager"
variant "$WORK/base" "$SRC" "${P[@]}" epoch=1 provides=podup; verdict "an epoch on a static product" podup v1.2.3 "declares the epoch '1'"
variant "$WORK/base" "$SRC" "${P[@]}" epoch=0 provides=podup; accepted "an explicit epoch 0" podup v1.2.3
variant "$WORK/base" "$SRC" "${P[@]}" format=6 provides=podup; verdict "package format 6" podup v1.2.3 "has the package format '6'"
variant "$WORK/base" "$SRC" epistle 1.2.3 1.glyndor.any x86_64 provides=epistle
verdict "another product's package under this name" podup v1.2.3 "declares the name 'epistle'"
variant "$WORK/base" "$SRC" podup 1.2.4 1.glyndor.any x86_64 provides=podup
verdict "a version the file name does not tell" podup v1.2.3 "declares the version '1.2.4'"
variant "$WORK/base" "$SRC" podup 1.2.3 2.glyndor.any x86_64 provides=podup
verdict "a release the file name does not tell" podup v1.2.3 "declares the release '2.glyndor.any'"
variant "$WORK/base" "$SRC" podup 1.2.3 1.glyndor.el9 x86_64 provides=podup
verdict "a header for one distribution in a package that says any" podup v1.2.3 "declares the release '1.glyndor.el9'"
variant "$WORK/base" "$SRC" podup 1.2.3 1.glyndor.any aarch64 provides=podup
verdict "an architecture the file name does not tell" podup v1.2.3 "declares the architecture 'aarch64'"
variant "$WORK/base" "$SRC" "${P[@]}" provides="podup bash"; verdict "a package that provides another name" podup v1.2.3 "provides 'bash||'"
variant "$WORK/base" "$SRC" "${P[@]}" provides="podup podup(foo)"; verdict "a provide that adds something to the product's own name" podup v1.2.3 "provides 'podup(foo)||'"
variant "$WORK/base" "$SRC" "${P[@]}" provides="podup podup(x86-64)" file=/usr/bin/podup; accepted "a package whose file is /usr/bin/podup" podup v1.2.3
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup trigger=bash; verdict "a trigger on another package" podup v1.2.3 "carries a trigger on 'bash'"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup filetrigger=/usr/lib; verdict "a file trigger" podup v1.2.3 "carries a file trigger"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup file=/usr/share/licenses/podup/LICENSE; accepted "a licence under /usr/share/licenses/podup" podup v1.2.3
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup file=/usr/share/zsh/site-functions/_podup; accepted "a zsh completion" podup v1.2.3
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup file=/usr/share/man/man1/podup.1.gz; accepted "a man page" podup v1.2.3
for forbidden in /etc/yum.repos.d/glyndor.repo /etc/zypp/repos.d/x.repo /etc/pki/rpm-gpg/RPM-GPG-KEY-x /usr/lib/rpm/macros.d/macros.x /etc/dnf/dnf.conf /usr/share/pacman/keyrings/x.gpg /etc/pacman.d/mirrorlist /usr/bin/other /etc/passwd /usr/bin/podupx /usr/lib/systemd/system-preset/x.preset /root/.ssh/authorized_keys; do
	variant "$WORK/base" "$SRC" "${P[@]}" provides=podup file="$forbidden"; verdict "a file at $forbidden" podup v1.2.3 "is not an install path the contract allows"
done
# --- scriptlets: every one of them, and the program that runs it ----------------------------------------------
for scr in post=true pretrans=true verifyscript=true preun=true preuntrans=true postuntrans=true; do
	variant "$WORK/base" "$SRC" "${P[@]}" provides=podup "$scr"; verdict "a scriptlet (${scr%%=*})" podup v1.2.3 "carries scriptlets (sha256"
done
# an rpm that gained a scriptlet tag this script does not know is refused, not trusted
mkdir -p "$WORK/binx"
cat > "$WORK/binx/rpm" <<'SH'
#!/bin/sh
case "$*" in --querytags) /usr/bin/rpm --querytags; echo PREFOOTRANS ;; *) exec /usr/bin/rpm "$@" ;; esac
SH
chmod +x "$WORK/binx/rpm"
out="$(PATH="$WORK/binx:$PATH" "$ADMIT" --keyring "$WORK/keyring" podup v1.2.3 "$WORK/base" 2>&1)"; rc=$?
check "an rpm with a scriptlet tag the script does not handle is refused" 1 "$rc"
check "and says which" 1 "$(printf '%s' "$out" | grep -c 'scriptlet tag PREFOOTRANS')"
cat > "$WORK/binx/rpm" <<'SH'
#!/bin/sh
case "$*" in --querytags) /usr/bin/rpm --querytags | grep -vE '^(PREUNTRANS|POSTUNTRANS)' ;; *) exec /usr/bin/rpm "$@" ;; esac
SH
out="$(PATH="$WORK/binx:$PATH" "$ADMIT" --keyring "$WORK/keyring" podup v1.2.3 "$WORK/base" 2>&1)"; rc=$?
check "an older rpm that lacks tags the script reads is refused, by name" 1 "$rc"
check "and says which tag it does not know" 1 "$(printf '%s' "$out" | grep -c 'does not know the scriptlet tag PREUNTRANS')"
cat > "$WORK/binx/rpm" <<'SH'
#!/bin/sh
case "$*" in --querytags) /usr/bin/rpm --querytags | grep -vE '^(PRE|POST|VERIFY)' ;; *) exec /usr/bin/rpm "$@" ;; esac
SH
out="$(PATH="$WORK/binx:$PATH" "$ADMIT" --keyring "$WORK/keyring" podup v1.2.3 "$WORK/base" 2>&1)"; check "an rpm that lists almost no scriptlet tags is refused" 1 "$?"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup post=true
hash="$("$ADMIT" --keyring "$WORK/keyring" podup v1.2.3 "$WORK/v" 2>&1 | grep -oE 'sha256 [0-9a-f]{64}' | head -1 | cut -d' ' -f2)"
rm -rf "$WORK/cfgs"; mkdir "$WORK/cfgs"; cp "$WORK/cfgq/"* "$WORK/cfgs/"; printf 'static\t%s\n' "$hash" >> "$WORK/cfgs/scriptlets.txt"
out="$("$ADMIT" --config "$WORK/cfgs" --keyring "$WORK/keyring" podup v1.2.3 "$WORK/v" 2>&1)"; check "a scriptlet whose exact text a person listed for the kind is admitted" 0 "$?"
printf 'podman\t%s\n' "$hash" > "$WORK/cfgs/scriptlets.txt"
out="$("$ADMIT" --config "$WORK/cfgs" --keyring "$WORK/keyring" podup v1.2.3 "$WORK/v" 2>&1)"; check "but not when the hash is listed for another kind" 1 "$?"
# --- every relation, per kind --------------------------------------------------------------------------------------
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup requires=bash; verdict "a requirement on a package the product does not name" podup v1.2.3 "requires 'bash||'"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup requires=podman; accepted "a requirement on podman" podup v1.2.3
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup recommends=vim; verdict "a recommendation" podup v1.2.3 "recommends 'vim||'"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup suggests=vim; verdict "a suggestion" podup v1.2.3 "suggests 'vim||'"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup supplements=bash; verdict "a package that supplements another" podup v1.2.3 "supplements 'bash||'"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup enhances=bash; verdict "a package that enhances another" podup v1.2.3 "enhances 'bash||'"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup obsoletes=openssh; verdict "a package that obsoletes another name" podup v1.2.3 "obsoletes 'openssh||'"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup obsoletes=podup; verdict "even its own name as obsoleted" podup v1.2.3 "obsoletes 'podup||'"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup conflicts=sudo; verdict "a package that conflicts with another name" podup v1.2.3 "conflicts 'sudo||'"

# The Podman set: epoch, release and relations of each kind of package.
PF="podman-6.2.0+r12-12.glyndor.el9.x86_64.rpm"
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides="podman netavark" obsoletes=netavark
accepted "a podman that replaces what the contract lists" podman v6.2.0+r12
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=5 provides=podman
verdict "the epoch of another distribution" podman v6.2.0+r12 "declares the epoch '5', expected '6'"
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 provides=podman
verdict "no epoch where the distribution has one" podman v6.2.0+r12 "declares the epoch '0', expected '6'"
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.fc45 x86_64 epoch=6 provides=podman
verdict "the release of another distribution" podman v6.2.0+r12 "declares the release '12.glyndor.fc45'"
variant "$WORK/podman" "$PF" podman 6.2.0+r11 12.glyndor.el9 x86_64 epoch=6 provides=podman
verdict "a podman of another revision" podman v6.2.0+r12 "declares the version '6.2.0+r11'"
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman obsoletes=glibc
verdict "a podman that obsoletes the C library" podman v6.2.0+r12 "obsoletes 'glibc||'"
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman conflicts=podman-docker
verdict "a podman that conflicts with its own companion" podman v6.2.0+r12 "conflicts 'podman-docker||'"
DF="podman-docker-6.2.0+r12-12.glyndor.el9.noarch.rpm"
variant "$WORK/podman" "$DF" podman-docker 6.2.0+r12 12.glyndor.el9 noarch epoch=6 provides="podman-docker docker"
accepted "podman-docker providing docker" podman v6.2.0+r12
variant "$WORK/podman" "$DF" podman-docker 6.2.0+r12 12.glyndor.el9 noarch epoch=6 provides="podman-docker podman"
verdict "podman-docker claiming to be podman" podman v6.2.0+r12 "provides 'podman||'"
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman requires="crun conmon" file=/usr/bin/podman
accepted "a podman that requires its runtime and has /usr/bin/podman" podman v6.2.0+r12
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman file=/etc/containers/containers.conf
verdict "a podman with a file under /etc/containers" podman v6.2.0+r12 "is not an install path the contract allows"
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman file=/usr/share/containers/containers.conf
accepted "a podman whose defaults are under /usr/share/containers" podman v6.2.0+r12
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman dir=/etc/containers
accepted "a podman that owns the folder /etc/containers and nothing in it" podman v6.2.0+r12
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides="podman libcontainers-image registries-conf" obsoletes="libcontainers-image registries-conf podman-machine podman-tests"
accepted "a podman that provides and obsoletes the suse names of the contract" podman v6.2.0+r12
# a name with a line break splits a record in two: rpmbuild refuses to write one, so the byte of a name is changed in the header
# and the package signed again, as an attacker who builds the header by hand would
nlpatch() { # <name of the file in $WORK/v>: the byte X of the file name becomes a line break
	python3 -I -c 'import sys; p=sys.argv[1]; b=open(p,"rb").read(); assert b.count(b"aaXbb")>=1; open(p,"wb").write(b.replace(b"aaXbb", b"aa\nbb"))' "$WORK/v/$1"
	rm -f "$WORK/v/$1.sig"; fx_sign "$WORK/v/$1"
}
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup file=/usr/lib/podup/aaXbb
accepted "a file name with no line break in it" podup v1.2.3
nlpatch "$SRC"; verdict "a file name with a line break in it" podup v1.2.3 "a name carries a line break"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup file=/usr/lib/podup/aaXbb
python3 -I -c 'import sys; p=sys.argv[1]; b=open(p,"rb").read(); open(p,"wb").write(b.replace(b"aaXbb", b"aa\x01bb"))' "$WORK/v/$SRC"; rm -f "$WORK/v/$SRC.sig"; fx_sign "$WORK/v/$SRC"
verdict "a file name with a control character in it" podup v1.2.3 "not a whole record"
variant "$WORK/base" "$SRC" "${P[@]}" provides="podup" obsoletes=aaXbb
python3 -I -c 'import sys; p=sys.argv[1]; b=open(p,"rb").read(); open(p,"wb").write(b.replace(b"aaXbb", b"aa\nbb"))' "$WORK/v/$SRC"; rm -f "$WORK/v/$SRC.sig"; fx_sign "$WORK/v/$SRC"
verdict "a relation name with a line break in it" podup v1.2.3 "a name carries a line break"

# the pretrans and posttrans of podman: only those two, only the text listed for the id
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman pretrans=true posttrans=true
out="$("$ADMIT" --keyring "$WORK/keyring" podman v6.2.0+r12 "$WORK/v" 2>&1)"; rc=$?
check "a podman with a pretrans and a posttrans that nothing lists is refused" 1 "$rc"
phash="$(printf '%s' "$out" | grep -oE 'sha256 [0-9a-f]{64}' | head -1 | cut -d' ' -f2)"
check "and the refusal names the key podman:el9" 1 "$(printf '%s' "$out" | grep -c "for 'podman:el9'")"
rm -rf "$WORK/cfgp"; mkdir "$WORK/cfgp"; cp "$WORK/cfgq/"* "$WORK/cfgp/"; printf 'podman:el9\t%s\n' "$phash" >> "$WORK/cfgp/scriptlets.txt"
out="$("$ADMIT" --config "$WORK/cfgp" --keyring "$WORK/keyring" podman v6.2.0+r12 "$WORK/v" 2>&1)"; check "the same text listed for el9 is admitted" 0 "$?"
printf 'podman:fc45\t%s\n' "$phash" > "$WORK/cfgp/scriptlets.txt"
out="$("$ADMIT" --config "$WORK/cfgp" --keyring "$WORK/keyring" podman v6.2.0+r12 "$WORK/v" 2>&1)"; check "the same text listed for another id is refused" 1 "$?"
printf 'podman\t%s\n' "$phash" > "$WORK/cfgp/scriptlets.txt"
out="$("$ADMIT" --config "$WORK/cfgp" --keyring "$WORK/keyring" podman v6.2.0+r12 "$WORK/v" 2>&1)"; check "and so is the text listed for the kind alone" 1 "$?"
printf 'podman:el9\t%s\n' "$phash" > "$WORK/cfgp/scriptlets.txt"
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman pretrans=true posttrans=true post=true
out="$("$ADMIT" --config "$WORK/cfgp" --keyring "$WORK/keyring" podman v6.2.0+r12 "$WORK/v" 2>&1)"; rc=$?
check "a podman that also carries a %post is refused whatever is listed" 1 "$rc"
check "and says only pretrans and posttrans are allowed" 1 "$(printf '%s' "$out" | grep -c 'may carry only PRETRANS PRETRANSPROG POSTTRANS POSTTRANSPROG')"
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman pretrans=false posttrans=true
out="$("$ADMIT" --config "$WORK/cfgp" --keyring "$WORK/keyring" podman v6.2.0+r12 "$WORK/v" 2>&1)"; check "a podman whose scriptlet text differs by a word is refused" 1 "$?"
variant "$WORK/base" "$SRC" "${P[@]}" provides=podup pretrans=true posttrans=true
out="$("$ADMIT" --config "$WORK/cfgp" --keyring "$WORK/keyring" podup v1.2.3 "$WORK/v" 2>&1)"; check "a product other than podman with the same scriptlets is refused" 1 "$?"
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman file=/etc/ssh/sshd_config
verdict "a podman with a file under /etc/ssh" podman v6.2.0+r12 "is not an install path the contract allows"
variant "$WORK/podman" "$PF" podman 6.2.0+r12 12.glyndor.el9 x86_64 epoch=6 provides=podman supplements=bash
verdict "a podman that supplements bash" podman v6.2.0+r12 "supplements 'bash||'"
CF="catatonit-1.31-12.glyndor.el9.x86_64.rpm"
variant "$WORK/podman" "$CF" catatonit 0.2.1 12.glyndor.el9 x86_64 epoch=0 provides=catatonit
verdict "an extra whose version is not the file name's" podman v6.2.0+r12 "does not carry the name its own header gives"
variant "$WORK/podman" "$CF" catatonit 1.31 12.glyndor.el9 x86_64 epoch=0 provides=catatonit obsoletes=podman
verdict "an extra that obsoletes podman" podman v6.2.0+r12 "obsoletes 'podman||'"
variant "$WORK/podman" "$CF" catatonit 1.31 12.glyndor.el9 x86_64 epoch=3 provides=catatonit
verdict "an extra with a wrong epoch" podman v6.2.0+r12 "declares the epoch '3', expected '0'"

echo "passed $pass, failed $fail"
printf 'DONE %s %d %d\n' "${BASH_SOURCE[0]##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ]
