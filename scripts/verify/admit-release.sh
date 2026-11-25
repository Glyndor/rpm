#!/usr/bin/env bash
#
# Admit the .rpm assets of one product release, or refuse the whole release.
#
# Usage: admit-release.sh [--config <dir>] [--keyring <dir>] <product> <tag> <dir>
#
# <dir> holds what fetch-release.sh downloaded for <tag>. Nothing here touches the network.
# Every file of the release is read as hostile input, in this order, and the first thing that
# is wrong stops the run with a non-zero status and no package admitted:
#
#   1. the directory: regular files only (no link, no folder), names of a closed alphabet;
#   2. the exact set: the file names the tag, the product and config/ derive, and no other;
#   3. sizes, before any byte is read;
#   4. the Ed25519 release signature of each .rpm, and the ML-DSA-65 one when it is there
#      or required, BEFORE anything opens the package. rpm parses the header, and every
#      byte of it comes from whoever can attach a release asset;
#   5. the header of the copy of the bytes that were verified, never of the file again:
#      name, version, release (which says which distribution it is for), epoch, architecture,
#      vendor, packager, package format, and what it provides and obsoletes;
#   6. the file is still the one that was verified.
#
# The fields read in step 5 are the contract of the release (config/podman-packages.txt,
# config/products.txt, config/relations.txt, contrato-productos.md of the channel).
# Requires: python3 with `cryptography`, rpm.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_DIR="$HERE/config"
KEYRING_DIR="$HERE/keyring"
MAX_RPM_BYTES="${ADMIT_MAX_RPM_BYTES:-$((300 * 1024 * 1024))}"
MAX_SIG_BYTES=4096
MAX_PAYLOAD_BYTES="${ADMIT_MAX_PAYLOAD_BYTES:-$((2 * 1024 * 1024 * 1024))}"
PACKAGER="Glyndor <noreply@glyndor.net>"

die() { echo "::error::admit-release: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
	case "$1" in
		--config) CONFIG_DIR="${2:?--config needs a directory}"; shift 2 ;;
		--keyring) KEYRING_DIR="${2:?--keyring needs a directory}"; shift 2 ;;
		--) shift; break ;;
		-*) die "unknown option $1" ;;
		*) break ;;
	esac
done
[ "$#" -eq 3 ] || die "usage: admit-release.sh [--config <dir>] [--keyring <dir>] <product> <tag> <dir>"
PRODUCT="$1"; TAG="$2"; DIR="$3"
if [ ! -d "$DIR" ] || [ -L "$DIR" ]; then die "$DIR is not a directory"; fi

verify_py() { python3 -I "$HERE/scripts/verify/verify-release-sig.py" "$@"; }
rows() { # <file>: the data lines of a tab separated config file
	[ -f "$1" ] || die "$1 is missing"
	grep -vE '^[[:space:]]*(#|$)' "$1" || true
}
escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }

# The package format is read with %{RPMFORMAT}, a tag rpm 6 and later know (rpm 4.16 of EL 9 answers `unknown
# tag`): without it a package of format 6 could not be told from one of format 4, so the run stops.
QUERYTAGS="$(rpm --querytags 2> /dev/null)" || die "cannot list the tags of this rpm"
grep -qx RPMFORMAT <<< "$QUERYTAGS" \
	|| die "this rpm ($(rpm --version 2> /dev/null | head -1)) does not know the RPMFORMAT tag; run the admission with rpm 6 or later"

# The scriptlet tags are the ones THIS rpm knows, not a list written once: a scriptlet tag that rpm gains
# (it gained %preuntrans and %postuntrans) and this script does not handle stops the run, rather than let
# a package carry a scriptlet nobody looks at.
SCRIPT_TAGS=()
HANDLED_TAGS=" PREIN PREINPROG POSTIN POSTINPROG PREUN PREUNPROG POSTUN POSTUNPROG PRETRANS PRETRANSPROG POSTTRANS POSTTRANSPROG PREUNTRANS PREUNTRANSPROG POSTUNTRANS POSTUNTRANSPROG PREINFLAGS POSTINFLAGS PREUNFLAGS POSTUNFLAGS PRETRANSFLAGS POSTTRANSFLAGS PREUNTRANSFLAGS POSTUNTRANSFLAGS VERIFYSCRIPT VERIFYSCRIPTPROG VERIFYSCRIPTFLAGS TRIGGERSCRIPTFLAGS TRANSFILETRIGGERSCRIPTFLAGS FILETRIGGERSCRIPTFLAGS TRIGGERSCRIPTS TRIGGERSCRIPTPROG TRANSFILETRIGGERSCRIPTS TRANSFILETRIGGERSCRIPTPROG FILETRIGGERSCRIPTS FILETRIGGERSCRIPTPROG "
while IFS= read -r t; do
	case "$HANDLED_TAGS" in *" $t "*) ;; *) die "this rpm has the scriptlet tag $t, which scripts/verify/admit-release.sh does not handle; refusing rather than letting a package carry a scriptlet nobody reads" ;; esac
	case "$t" in TRIGGER* | TRANSFILETRIGGER* | FILETRIGGER*) ;; *) SCRIPT_TAGS+=("$t") ;; esac
done < <(grep -E '^(PRE|POST|VERIFY|TRIGGER|TRANSFILETRIGGER|FILETRIGGER)[A-Z]*(IN|UN|TRANS|SCRIPT|SCRIPTS)(PROG|FLAGS)?$' <<< "$QUERYTAGS")
# the other direction: every tag the script reads is one this rpm has, by name and not by count, so an rpm that lacks one
# (an older one has no %preuntrans) cannot leave a scriptlet unread
for t in $HANDLED_TAGS; do
	case "$t" in TRIGGER* | TRANSFILETRIGGER* | FILETRIGGER*) continue ;; esac
	grep -qx "$t" <<< "$QUERYTAGS" || die "this rpm does not know the scriptlet tag $t; run the admission with the rpm of the runner image"
done

# --- the product and the tag -------------------------------------------------------------------
kind="" ; archs=""
while IFS=$'\t' read -r name k a _wf _ref; do
	[ "$name" = "$PRODUCT" ] && { kind="$k"; archs="$a"; }
done < <(rows "$CONFIG_DIR/products.txt")
[ -n "$kind" ] || die "$PRODUCT is not a product of this channel (config/products.txt)"
case "$kind" in podman | static | service) ;; *) die "config/products.txt gives $PRODUCT the kind '$kind'" ;; esac

if [ "$kind" = podman ]; then
	[[ "$TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(\+r([0-9]+))?$ ]] || die "tag '$TAG' is not vX.Y.Z or vX.Y.Z+rN"
	V="${BASH_REMATCH[1]}"; R="${BASH_REMATCH[3]:-1}"
	VR="$V+r$R"
else
	[[ "$TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "tag '$TAG' is not vX.Y.Z"
	V="${BASH_REMATCH[1]}"; R=1; VR="$V"
fi

# --- a release lower than the floor of its product is refused --------------------------------------
# The verdict on "older" is rpm's own, on the version the package will carry (the tag without its v; a Podman tag
# always carries its revision, `+rN`, and rpm reads `+r9` before `+r10`), not a comparison of this script.
. "$HERE/scripts/verify/lib-evr.sh"
# The floor fails closed like every list of this channel: a file that is missing, a link or unreadable
# would be read as "no floor", which is the state it exists to prevent.
FLOOR="$CONFIG_DIR/floor.txt"
if [ ! -f "$FLOOR" ] || [ -L "$FLOOR" ] || [ ! -r "$FLOOR" ]; then die "$FLOOR is not a readable regular file; refusing, since a missing floor would be no floor"; fi
known_products="$(rows "$CONFIG_DIR/products.txt" | cut -f1)"
while read -r fname ftag fextra || [ -n "$fname" ]; do
	if [ -z "$fname" ] || [ "${fname:0:1}" = "#" ]; then continue; fi
	if [ -n "$fextra" ] || [ -z "$ftag" ]; then die "config/floor.txt has a malformed line for '$fname'"; fi
	printf '%s\n' "$known_products" | grep -qxF -- "$fname" || die "config/floor.txt names '$fname', which is not a product of config/products.txt"
	fkind="$(rows "$CONFIG_DIR/products.txt" | awk -F'\t' -v n="$fname" '$1 == n { print $2 }')"
	floor_v="$(evr_of "$ftag" "$fkind")" || die "config/floor.txt has a malformed line for '$fname'"
	[ "$fname" = "$PRODUCT" ] || continue
	this_v="$(evr_of "$TAG" "$kind")" || die "tag '$TAG' is not a version of $PRODUCT"
	# the answer is taken in this shell and its status checked: inside a condition a failing rpm would be read as "not lower"
	cmp="$(vercmp "$this_v" "$floor_v")" || die "rpm cannot compare $this_v with the floor $floor_v of $PRODUCT; refusing, since a floor that cannot be read is no floor"
	case "$cmp" in
		0 | 1) ;;
		-1) die "$TAG is lower than $ftag, the highest release of $PRODUCT the channel has admitted (config/floor.txt)" ;;
		*) die "rpm answered '$cmp' to the comparison with the floor of $PRODUCT" ;;
	esac
done < "$FLOOR"

# --- the exact set this tag has to carry ---------------------------------------------------------
declare -a X_NAME=() X_ID=() X_ARCH=() X_EPOCH=() X_REL=() X_RE=()
add_row() { # <id> <name> <arch> <epoch> <relation kind> <version regex>
	X_ID+=("$1"); X_NAME+=("$2"); X_ARCH+=("$3"); X_EPOCH+=("$4"); X_REL+=("$5")
	X_RE+=("^$(escape "$2")-$6-$(escape "$R")\\.glyndor\\.$(escape "$1")\\.$(escape "$3")\\.rpm$")
}
if [ "$kind" = podman ]; then
	while IFS=$'\t' read -r id name akind epoch vrule; do
		[[ "$id" =~ ^[a-z0-9]+$ && "$name" =~ ^[a-z0-9-]+$ && "$epoch" =~ ^[0-9]+$ ]] \
			|| die "podman-packages.txt has a malformed row for '$name'"
		if [ "$akind" = noarch ]; then arch_list="noarch"; else arch_list="${archs//,/ }"; fi
		for arch in $arch_list; do
			case "$vrule" in
				core) rel=companion; [ "$name" = podman ] && rel=podman; ver="$(escape "$VR")" ;;
				extra) rel=extra; ver='[0-9][0-9A-Za-z.]*' ;;
				*) die "podman-packages.txt: unknown version rule '$vrule' for '$name'" ;;
			esac
			add_row "$id" "$name" "$arch" "$epoch" "$rel" "$ver"
		done
	done < <(rows "$CONFIG_DIR/podman-packages.txt")
else
	if [ "$archs" = noarch ]; then arch_list=noarch; else arch_list="${archs//,/ }"; fi
	for arch in $arch_list; do add_row any "$PRODUCT" "$arch" 0 "$kind" "$(escape "$V")"; done
fi
[ "${#X_NAME[@]}" -ge 1 ] || die "no package is expected for $PRODUCT $TAG"

# --- 1 and 2: the directory --------------------------------------------------------------------
declare -A CLAIMED=()
shopt -s nullglob dotglob
rpms=()
while IFS=$'\t' read -r type file; do
	[ "$type" = f ] || die "$file is not a regular file (type '$type'); a link or a folder is never admitted"
	[[ "$file" =~ ^[A-Za-z0-9_+~][A-Za-z0-9._+~-]*$ && "$file" != *..* ]] || die "the file name '$file' is outside the closed alphabet"
	case "$file" in
		*.rpm) rpms+=("$file") ;;
		*.rpm.sig | *.rpm.mldsa65.sig) ;;
		*) die "$file is not an .rpm or a signature of one; this release carries a file the contract does not name" ;;
	esac
done < <(find "$DIR" -mindepth 1 -maxdepth 1 -printf '%y\t%f\n' | sort)
[ "${#rpms[@]}" -eq "${#X_NAME[@]}" ] \
	|| die "$PRODUCT $TAG carries ${#rpms[@]} .rpm file(s) and the contract names ${#X_NAME[@]}"
declare -A ROW_OF=()
for file in "${rpms[@]}"; do
	hit=""
	for i in "${!X_RE[@]}"; do
		if [[ "$file" =~ ${X_RE[$i]} ]]; then
			[ -z "$hit" ] || die "$file matches two rows of the contract"
			hit="$i"
		fi
	done
	[ -n "$hit" ] || die "$file is not a file the contract names for $PRODUCT $TAG (name, version, revision, distribution or architecture)"
	[ -z "${CLAIMED[$hit]:-}" ] || die "two files stand for ${X_NAME[$hit]} ${X_ID[$hit]} ${X_ARCH[$hit]}: ${CLAIMED[$hit]} and $file"
	CLAIMED[$hit]="$file"; ROW_OF[$file]="$hit"
	[ -f "$DIR/$file.sig" ] || die "no signature $file.sig; refusing an unverified package"
done
nsig="$(find "$DIR" -mindepth 1 -maxdepth 1 -name '*.rpm.sig' | wc -l)"
[ "$nsig" -eq "${#rpms[@]}" ] || die "$nsig .sig file(s) for ${#rpms[@]} package(s); a signature names no package here"
for sc in "$DIR"/*.rpm.mldsa65.sig; do
	[ -f "${sc%.mldsa65.sig}" ] || die "$(basename "$sc") names no package of this release"
done

# --- 3: sizes -----------------------------------------------------------------------------------
for file in "$DIR"/*; do
	size="$(stat -c%s -- "$file")"
	case "$file" in
		*.sig) [ "$size" -le "$MAX_SIG_BYTES" ] || die "$(basename "$file") is $size bytes, over the $MAX_SIG_BYTES-byte signature cap" ;;
		*) [ "$size" -le "$MAX_RPM_BYTES" ] || die "$(basename "$file") is $size bytes, over the $MAX_RPM_BYTES-byte package cap" ;;
	esac
done

# --- the keys and the required list ------------------------------------------------------------
ED_KEYS="$KEYRING_DIR/glyndor-release-ed25519.b64"
PQ_KEYS="$KEYRING_DIR/glyndor-release-mldsa65.b64"
PQ_LIST="$KEYRING_DIR/pq-required-products"
verify_py check-keys ed25519 "$ED_KEYS" || die "the Ed25519 release key file $ED_KEYS is malformed"
[ ! -e "$PQ_KEYS" ] || verify_py check-keys mldsa65 "$PQ_KEYS" || die "the ML-DSA-65 key file $PQ_KEYS is malformed"
pq_required=0
# The list that says which products must carry the second signature fails closed: a list that is not
# there, or cannot be read, would be read as "nobody is required".
if [ ! -f "$PQ_LIST" ] || [ -L "$PQ_LIST" ] || [ ! -r "$PQ_LIST" ]; then
	die "$PQ_LIST is not a readable regular file; refusing, since a missing list would require nobody"
fi
[ -z "$(LC_ALL=C tr -d ' -~\n' < "$PQ_LIST")" ] || die "$PQ_LIST holds a byte that is not printable ASCII or a line feed"
known_products="$(rows "$CONFIG_DIR/products.txt" | cut -f1)"
while IFS= read -r line || [ -n "$line" ]; do
	line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
	case "$line" in '' | '#'*) continue ;; esac
	[[ "$line" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
		|| die "$PQ_LIST is malformed: '$line' is not a product name; a comment takes a line of its own"
	printf '%s\n' "$known_products" | grep -qxF -- "$line" \
		|| die "$PQ_LIST names '$line', which is not a product of config/products.txt; a typo must not drop a requirement"
	[ "$line" != "$PRODUCT" ] || pq_required=1
done < "$PQ_LIST"
# The second signature protects nothing unless a product requires it: with a key configured, an empty list would
# mean that the key is there and nobody is held to it. (Today there is no key and no list; a `.mldsa65.sig` attached
# to a release is then refused, because there is no key to check it against.)
if [ -n "$(rows "$PQ_KEYS" 2> /dev/null)" ] && [ -z "$(grep -vE '^[[:space:]]*(#|$)' "$PQ_LIST" || true)" ]; then
	die "an ML-DSA-65 key is configured and $PQ_LIST names no product: the second signature would protect nothing"
fi
echo "ML-DSA-65 second signature required for $PRODUCT: $([ "$pq_required" -eq 1 ] && echo yes || echo no)"

# --- 4 and 5: each package -------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
verified="$WORK/package.rpm"
# Every question to rpm about a package runs the same way, whatever the runner has: no plugin, no macro file of the
# machine or of the user, no rpmrc of the machine, and a database that is not the host's.
mkdir -p "$WORK/db"
rq() { rpm --noplugins --rcfile /dev/null --macros /dev/null --dbpath "$WORK/db" -qp --nomanifest --nosignature --nodigest "$@"; }
. "$HERE/scripts/verify/admit-lib.sh"
count=0
for file in "${rpms[@]}"; do
	i="${ROW_OF[$file]}"
	rm -f "$verified"
	rc=0
	verify_py ed25519 "$DIR/$file.sig" "$DIR/$file" "$ED_KEYS" "$verified" || rc=$?
	case "$rc" in
		0) ;;
		2) die "the local release trust file is malformed; no key to verify $file against" ;;
		4) die "could not keep a private copy of the verified bytes of $file" ;;
		*) die "invalid signature for $file; the release may be tampered" ;;
	esac
	if [ -e "$DIR/$file.mldsa65.sig" ]; then
		prc=0
		verify_py mldsa65 "$DIR/$file.mldsa65.sig" "$verified" "$PQ_KEYS" || prc=$?
		[ "$prc" -eq 0 ] || die "the ML-DSA-65 signature of $file is not valid (status $prc); refusing rather than skipping it"
	elif [ "$pq_required" -eq 1 ]; then
		die "no ML-DSA-65 signature for $file; $PRODUCT requires the hybrid release signature"
	fi

	# Only now is the package opened, and it is the copy of the verified bytes. rpm -qp reads a file that is
	# not a package as a manifest (a list of paths), so the lead of an rpm is checked first and the
	# manifest reading is switched off in every call.
	[ "$(head -c 4 "$verified" | od -An -tx1 | tr -d ' \n')" = "edabeedb" ] || die "$file does not start with the lead of an rpm package"
	header="$(rq \
		--qf '%{NAME}\n%{VERSION}\n%{RELEASE}\n%{EPOCH}\n%{ARCH}\n%{VENDOR}\n%{PACKAGER}\n%{RPMFORMAT}\n' "$verified" 2>/dev/null)" \
		|| die "cannot read the header of $file"
	mapfile -t f <<< "$header"
	[ "${#f[@]}" -eq 8 ] || die "the header of $file has a field that spans lines"
	[ "${f[0]}" = "${X_NAME[$i]}" ] || die "$file declares the name '${f[0]}', expected '${X_NAME[$i]}'"
	[ "${f[4]}" = "${X_ARCH[$i]}" ] || die "$file declares the architecture '${f[4]}', expected '${X_ARCH[$i]}'"
	[ "${f[2]}" = "$R.glyndor.${X_ID[$i]}" ] \
		|| die "$file declares the release '${f[2]}', expected '$R.glyndor.${X_ID[$i]}'"
	if [ "${X_REL[$i]}" = extra ]; then
		[[ "${f[1]}" =~ ^[0-9][0-9A-Za-z.]*$ ]] || die "$file declares the version '${f[1]}'"
	else
		want="$V"; [ "$kind" = podman ] && want="$VR"
		[ "${f[1]}" = "$want" ] || die "$file declares the version '${f[1]}' but was downloaded from release '$TAG'"
	fi
	e="${f[3]}"; [ "$e" != "(none)" ] || e=0
	[ "$e" = "${X_EPOCH[$i]}" ] || die "$file declares the epoch '$e', expected '${X_EPOCH[$i]}'"
	[ "${f[5]}" = Glyndor ] || die "$file declares the vendor '${f[5]}', expected 'Glyndor'"
	[ "${f[6]}" = "$PACKAGER" ] || die "$file declares the packager '${f[6]}', expected '$PACKAGER'"
	[ "${f[7]}" = 4 ] || die "$file has the package format '${f[7]}'; format 4 is the one every supported rpm reads"
	[ "$file" = "${f[0]}-${f[1]}-${f[2]}.${f[4]}.rpm" ] || die "$file does not carry the name its own header gives"
	# A package acts on the host through its scriptlets, its triggers and its files. Triggers run on other
	# packages' transactions as root and are never allowed; scriptlets are allowed only as the exact text a
	# person has read and listed for the kind (config/scriptlets.txt); files only under the paths of
	# config/paths.txt, in canonical form.
	trig="$(rq --qf '[%{TRIGGERNAME}\n]' "$verified" 2> /dev/null)" \
		|| die "cannot read the triggers of $file"
	if [ -n "$(printf '%s' "$trig" | tr -d '[:space:]')" ] && [ "$trig" != "(none)" ]; then die "$file carries a trigger on '$(printf '%s' "$trig" | head -1)'; triggers are not allowed"; fi
	ftrig="$(rq --filetriggers "$verified" 2> /dev/null)" \
		|| die "cannot read the file triggers of $file"
	if [ -n "$(printf '%s' "$ftrig" | tr -d '[:space:]')" ]; then die "$file carries a file trigger; file triggers are not allowed"; fi
	scriptlets_of "$verified"
	# The verdict does not rest on the reading above alone: rpm's own listing of scriptlets and triggers is empty exactly
	# when no scriptlet was read, so a scriptlet that rpm shows and this admission did not see stops the run.
	tool="$(rq --scripts --triggers --filetriggers "$verified" 2> /dev/null)" || die "cannot list the scriptlets of $file with rpm"
	theirs=0; [ -z "$(printf '%s' "$tool" | tr -d '[:space:]')" ] || theirs=1
	mine=0; [ "$SCRIPT_PRESENT" = " " ] || mine=1
	[ "$mine" -eq "$theirs" ] || die "rpm lists $theirs scriptlet(s) of $file where this admission read $mine: refusing a package whose scriptlets are not the ones read"
	if [ "$SCRIPT_PRESENT" != " " ]; then
		skey="${X_REL[$i]}"; only=""
		# Two kinds may carry scriptlets, each only the ones its job needs and only as the exact text the channel lists.
		# podman keeps what the administrator edited in the packages it replaces (%pretrans and %posttrans, key
		# podman:<id>). A service of ours, which installs a systemd unit, carries the expansion of the three systemd
		# macros (%post, %preun and %postun, key service:<product>, or service:<product>:<id> for a package built per id).
		case "$skey" in
			podman) only=" PRETRANS PRETRANSPROG POSTTRANS POSTTRANSPROG "; skey="podman:${X_ID[$i]}" ;;
			service) only=" POSTIN POSTINPROG PREUN PREUNPROG POSTUN POSTUNPROG "; skey="service:$PRODUCT"; [ "${X_ID[$i]}" = any ] || skey="$skey:${X_ID[$i]}" ;;
		esac
		if [ -n "$only" ]; then
			for t in $SCRIPT_PRESENT; do
				case "$only" in *" $t "*) continue ;; esac
				die "$file carries a $t scriptlet; its kind may carry only$only"
			done
		fi
		sum="$SCRIPT_HASH"
		rows "$CONFIG_DIR/scriptlets.txt" | awk -F'\t' -v k="$skey" -v h="$sum" '$1 == k && $2 == h { f = 1 } END { exit !f }' \
			|| die "$file carries scriptlets (sha256 $sum) that config/scriptlets.txt does not list for '$skey'"
	elif [ "${X_REL[$i]}" = service ]; then
		# without them removing the package leaves the service running with no binary
		die "$file is a service and carries no scriptlet; it must carry the expansion of the systemd macros"
	fi
	paths="$(list_of "$verified" FILENAMES '%{FILEMODES:perms} %{FILENAMES}' '^[-dlcbps][-rwxsStT]{9} /[-A-Za-z0-9._/+@~]*$')" || exit 1
	# a rule starting with `dir:` allows folders only (no package of ours puts a file under /etc/containers, only the folder)
	path_re="$(rows "$CONFIG_DIR/paths.txt" | awk -F'\t' -v k="${X_REL[$i]}" '$1 == k && $2 !~ /^dir:/ { print $2 }' | sed "s|NAME|$(escape "${f[0]}")|g" | paste -sd'|')"
	dir_re="$(rows "$CONFIG_DIR/paths.txt" | awk -F'\t' -v k="${X_REL[$i]}" '$1 == k && $2 ~ /^dir:/ { print substr($2, 5) }' | sed "s|NAME|$(escape "${f[0]}")|g" | paste -sd'|')"
	[ -n "$path_re" ] || die "config/paths.txt has no path for the kind '${X_REL[$i]}'"
	[ -n "$dir_re" ] || dir_re='$^'
	# what each entry is: only regular files, folders and symbolic links; no set-id bit, no capability, and a link only
	# to a place its own kind may install (resolved by its text), never at a place whose rule admits children
	links="$(list_of "$verified" FILELINKTOS '%{FILELINKTOS}E' '^[^[:cntrl:]]*E$')" || exit 1
	caps="$(rq --qf '[%{FILECAPS}]' "$verified" 2> /dev/null)" || die "cannot read the capabilities of $file"
	[ -z "$caps" ] || die "$file carries a file capability ('$caps'); none is listed for any package"
	P_REC=(); L_REC=()
	[ -z "$paths" ] || mapfile -t P_REC <<< "$paths"
	[ -z "$links" ] || mapfile -t L_REC <<< "$links"
	[ "${#P_REC[@]}" -eq "${#L_REC[@]}" ] || die "$file lists ${#P_REC[@]} files and ${#L_REC[@]} link targets"
	# who owns each entry: root, unless config/owners.txt says otherwise for that path
	owners="$(list_of "$verified" FILEUSERNAME '%{FILEUSERNAME}|%{FILEGROUPNAME}' '^[^|[:cntrl:]]+\|[^|[:cntrl:]]+$')" || exit 1
	O_REC=(); [ -z "$owners" ] || mapfile -t O_REC <<< "$owners"
	[ "${#P_REC[@]}" -eq "${#O_REC[@]}" ] || die "$file lists ${#P_REC[@]} files and ${#O_REC[@]} owners"
	for j in "${!P_REC[@]}"; do
		rec="${P_REC[$j]}"; perm="${rec%% *}"; path="${rec#* }"
		if [[ ! "$path" =~ ^/[^/] ]] || [[ "$path" =~ [[:cntrl:]] ]] || [[ "$path" == *//* ]] || [[ "$path" =~ (^|/)\.\.?(/|$) ]]; then
			die "$file carries the path '$path', which is not in canonical form"
		fi
		case "${perm:0:1}" in - | d | l) ;; *) die "$file carries '$path', which is a device, a pipe or a socket (mode $perm)" ;; esac
		if [[ "${perm:3:1}" =~ [sS] ]] || [[ "${perm:6:1}" =~ [sS] ]]; then die "$file carries '$path' with a set-id bit (mode $perm)"; fi
		# a file or a folder that its group or others can write is a file a local user can replace and run as root; a
		# link has no mode of its own (rpm lists it as 777). No package of ours needs a sticky folder, so none is allowed.
		if [ "${O_REC[$j]}" != "root|root" ] && ! owner_ok "${X_REL[$i]}" "$(canon_of "$path")" "${O_REC[$j]/|/:}" "$perm"; then
			die "$file carries '$path' owned by '${O_REC[$j]/|/:}', and config/owners.txt lists no such owner for it; everything is root:root"
		fi
		if [ "${perm:0:1}" != l ] && { [ "${perm:5:1}" = w ] || [ "${perm:8:1}" = w ]; }; then
			die "$file carries '$path' that its group or others can write (mode $perm)"
		fi
		canon="$(canon_of "$path")"
		if [[ "$canon" =~ ^($path_re)$ ]] || { [ "${perm:0:1}" = d ] && [[ "$canon" =~ ^($dir_re)$ ]]; }; then :; else
			die "$file carries '$path', which is not an install path the contract allows its package kind (config/paths.txt)"
		fi
		[ "${perm:0:1}" = l ] || { [ -z "${L_REC[$j]%E}" ] || die "$file gives '$path' a link target but it is not a link"; continue; }
		target="${L_REC[$j]%E}"
		[ -n "$target" ] || die "$file carries the link '$path' with no target"
		dest="$(resolve_lexical "$(dirname "$path")" "$target")" || die "$file carries the link '$path' to '$target', which leaves the root"
		dest="$(canon_of "$dest")"
		# a link the kind lists, by place and by target, is the one exception: podmansh and docker point at podman
		listed=0
		while IFS=$'\t' read -r lk lpath ltarget; do
			[ "$lk" = "${X_REL[$i]}" ] || continue
			lpath="${lpath//NAME/$(escape "${f[0]}")}"; ltarget="${ltarget//NAME/$(escape "${f[0]}")}"
			if [[ "$canon" =~ ^($lpath)$ ]] && [[ "$dest" =~ ^($ltarget)$ ]]; then listed=1; break; fi
		done < <(rows "$CONFIG_DIR/links.txt")
		[ "$listed" -eq 1 ] && continue
		if [[ "$canon/x" =~ ^($path_re)$ ]]; then die "$file carries the link '$path', where its kind may install files under it (config/links.txt lists the ones allowed)"; fi
		[[ "$dest" =~ ^($path_re)$ ]] || die "$file carries the link '$path' to '$dest', which its kind may not install"
	done
	# Every relation a package can carry, each as the record name|comparison|version against the rule of its kind in
# config/relations.txt.
	for rel in provides obsoletes conflicts requires recommends suggests supplements enhances; do
		stem="$(printf '%s' "${rel%s}" | tr '[:lower:]' '[:upper:]')"
		rels="$(list_of "$verified" "${stem}NAME" "%{${stem}NAME}|%{${stem}FLAGS:depflags}|%{${stem}VERSION}" '^[^|[:cntrl:]]+\|[<>=]*\|[^|[:cntrl:]]*$')" || exit 1
		if [ "$rel" = provides ] && ! printf '%s\n' "$rels" | cut -d'|' -f1 | grep -qxF -- "${f[0]}"; then
			die "$file does not provide its own name '${f[0]}'; the list of what it provides cannot be trusted"
		fi
		while IFS= read -r relname; do
			if [ -z "$relname" ] || [ "$relname" = "(none)" ]; then continue; fi
			IFS='|' read -r rname rflags rversion <<< "$relname"
			# a rich dependency is a condition the host evaluates: only the exact expression a kind lists is accepted
			if [[ "$rname" == "("* ]] || [[ "$rname" =~ [[:space:]\<\>=] ]]; then
				if [ -n "$rflags$rversion" ] || ! rich_ok "${X_REL[$i]}" "$rel" "$rname"; then
					die "$file $rel '$relname' is a rich dependency that config/rich-dependencies.txt does not list for the kind"
				fi
				continue
			fi
			if [ "$rname" = "rpmlib(RichDependencies)" ] && ! rich_kind "${X_REL[$i]}"; then die "$file needs rpmlib(RichDependencies) and its kind lists no rich dependency"; fi
			[ "$rname" != "rpmlib(ScriptletInterpreterArgs)" ] || die "$file needs rpmlib(ScriptletInterpreterArgs): a scriptlet with arguments to its interpreter"
			# what a package provides under its own name is its own version, nothing else it might satisfy
			if [ "$rel" = provides ] && { [ "$rname" = "${f[0]}" ] || [ "$rname" = "${f[0]}(x86-64)" ] || [ "$rname" = "${f[0]}(aarch-64)" ]; }; then
				own="${f[1]}-${f[2]}"
				# rpm writes the epoch in front of the version, a zero one included when the package says it
				if [ -n "$rflags$rversion" ] && { [ "$rflags" != "=" ] || { [ "$rversion" != "$e:$own" ] && { [ "$e" != 0 ] || [ "$rversion" != "$own" ]; }; }; }; then
					die "$file provides its own name '$rname' with the version '$rversion', not its own $own"
				fi
			fi
			if relation_ok "${X_REL[$i]}" "$rel" "$rname" "$rflags" "$rversion"; then continue; fi
			# a service lists the rest of what it may require, product by product, with the comparison and the version
			if [ "${X_REL[$i]}" = service ] && [ "$rel" = requires ] \
				&& rows "$CONFIG_DIR/service-requires.txt" | awk -F'\t' -v p="$PRODUCT" -v r="$relname" '$1 == p && $2 == r { f = 1 } END { exit !f }'; then continue; fi
			die "$file $rel '$relname', which is not a name, a comparison and a version the contract allows its package kind to $rel"
		done <<< "$rels"
	done
	# the size of what the package unpacks to: the header says it, and the payload is read through a hard ceiling because
	# the header is what the signer wrote and a bomb says nothing about itself
	total="$(rq --qf '%{LONGSIZE}' "$verified" 2> /dev/null)" || die "cannot read the installed size of $file"
	[[ "$total" =~ ^[0-9]{1,13}$ ]] || die "$file reports the installed size '$total', which is not a number"
	[ "$total" -le "$MAX_PAYLOAD_BYTES" ] || die "$file would install $total bytes, over the $MAX_PAYLOAD_BYTES-byte ceiling"
	payload_size "$verified"
	[ "$PAYLOAD_SIZE" -le "$MAX_PAYLOAD_BYTES" ] || die "$file unpacks to more than $MAX_PAYLOAD_BYTES bytes"
	cmp -s "$DIR/$file" "$verified" || die "$file changed while it was being verified"
	echo "admitted $file"
	count=$((count + 1))
done
echo "admitted $count package(s) of $PRODUCT $TAG against the release key"
