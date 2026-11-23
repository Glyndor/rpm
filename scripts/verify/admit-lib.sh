#!/usr/bin/env bash
#
# The functions of scripts/verify/admit-release.sh that read a package, sourced by it and not run by themselves: the
# records of an array tag, the scriptlets, the size of the payload, the form of a path, a link resolved by its text and
# the rule of a relation. They use what the admission defines (die, rows, escape, rq, WORK, CONFIG_DIR, PRODUCT, SCRIPT_TAGS,
# MAX_PAYLOAD_BYTES) at the time they are called.
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # what the admission defines, and what it reads back

# list_of <rpm> <tag> <record format> <record regex>: the records of an array tag, one per line. A name that carries a
# newline would split a record in two and let a path nobody judged hide in the second half, so the run stops unless
# there are exactly as many lines as the header has entries and every line is a whole record of the shape given.
list_of() {
	local pkg="$1" tag="$2" qf="$3" re="$4" n out lines l
	n="$(rq --qf "%{$tag:arraysize}" "$pkg" 2> /dev/null)" \
		|| die "cannot count the entries of $tag in $file"
	[ "$n" != "(none)" ] || n=0
	[[ "$n" =~ ^[0-9]{1,7}$ ]] || die "$file reports '$n' entries of $tag, which is not a count"
	out="$(rq --qf "[$qf\\n]" "$pkg" 2> /dev/null)" \
		|| die "cannot read $tag of $file"
	if [ "$n" -eq 0 ]; then
		[ -z "$out" ] || [ "$out" = "(none)" ] || die "$file has no entries of $tag but rpm prints '$out'"
		return 0
	fi
	lines="$(printf '%s\n' "$out" | wc -l)"
	[ "$lines" -eq "$n" ] || die "$file lists $n entries of $tag but rpm prints $lines lines: a name carries a line break"
	while IFS= read -r l; do
		[[ "$l" =~ $re ]] || die "$file carries an entry of $tag that is not a whole record (a control character or a line break in a name)"
	done <<< "$out"
	printf '%s\n' "$out"
}

# scriptlets_of <rpm>: every scriptlet tag of the package, each read the way it is stored, and a sha256 of an encoding
# that cannot read one way for two packages: the tag, whether it is there, the length of its text and the text. The
# interpreters are arrays, and only /bin/sh alone is accepted (arguments after it are what rpmlib(ScriptletInterpreterArgs)
# is for); the flags must be absent or 0. SCRIPT_PRESENT lists the tags that are there, SCRIPT_HASH is the digest.
scriptlets_of() {
	local pkg="$1" t n v enc="" present
	SCRIPT_PRESENT=" "
	for t in "${SCRIPT_TAGS[@]}"; do
		present=0; v=""
		case "$t" in
			*PROG)
				n="$(rq --qf "%{$t:arraysize}" "$pkg" 2> /dev/null)" || die "cannot count $t of $file"
				if [ "$n" = "(none)" ] || [ "$n" = 0 ]; then :
				elif [ "$n" = 1 ]; then
					v="$(rq --qf "[%{$t}\\n]" "$pkg" 2> /dev/null)" || die "cannot read $t of $file"
					[ "$v" = /bin/sh ] || die "$file has the interpreter '$v' in $t; a scriptlet runs with /bin/sh alone, with no argument"
					present=1
				else die "$file has $n elements in $t; a scriptlet runs with /bin/sh alone, with no argument"
				fi ;;
			*FLAGS)
				v="$(rq --qf "%|$t?{%{$t}}:{}|" "$pkg" 2> /dev/null)" || die "cannot read $t of $file"
				case "$v" in "" | 0) v="" ;; *) die "$file has the flags '$v' in $t; a scriptlet carries none" ;; esac ;;
			*)
				v="$(rq --qf "%|$t?{P%{$t}E}:{A}|" "$pkg" 2> /dev/null; printf x)" || die "cannot read $t of $file"
				v="${v%x}"
				if [ "$v" != A ]; then
					[[ "$v" == P*E ]] || die "$file has a $t that rpm did not print whole"
					v="${v#P}"; v="${v%E}"; present=1
				else v=""
				fi ;;
		esac
		[ "$present" -eq 0 ] || SCRIPT_PRESENT="$SCRIPT_PRESENT$t "
		enc="$enc$t:$present:${#v}:$v"$'\n'
	done
	SCRIPT_HASH="$(printf '%s' "$enc" | sha256sum | cut -d' ' -f1)"
}

# payload_size <rpm>: PAYLOAD_SIZE, the bytes of the unpacked payload read up to one more than the ceiling; the reader
# stops there (a closed pipe ends the unpacking), and any other end of the unpacking is a refusal
payload_size() {
	local rc
	set +e
	rpm2cpio "$1" 2> /dev/null | head -c $((MAX_PAYLOAD_BYTES + 1)) | wc -c > "$WORK/payload.size"
	rc="${PIPESTATUS[0]}"
	set -e
	case "$rc" in 0 | 141) ;; *) die "$file cannot be unpacked (status $rc)" ;; esac
	PAYLOAD_SIZE="$(tr -d ' \n' < "$WORK/payload.size")"
	[[ "$PAYLOAD_SIZE" =~ ^[0-9]{1,13}$ ]] || die "the size of the payload of $file could not be read"
}

# canon_of <path>: the path as it is compared with config/paths.txt (/bin, /sbin, /lib and /lib64 are their targets under /usr)
canon_of() {
	case "$1" in
		/bin | /bin/* | /sbin | /sbin/* | /lib | /lib/* | /lib64 | /lib64/*) printf '/usr%s' "$1" ;;
		*) printf '%s' "$1" ;;
	esac
}
# resolve_lexical <folder of the link> <target>: where a link points, resolved by its text alone; nothing when it leaves the root
resolve_lexical() {
	local full part out=() IFS
	case "$2" in /*) full="$2" ;; *) full="$1/$2" ;; esac
	IFS=/ read -r -a parts <<< "$full"
	for part in "${parts[@]}"; do
		case "$part" in
			"" | .) ;;
			..) [ "${#out[@]}" -gt 0 ] || return 1; unset 'out[${#out[@]}-1]' ;;
			*) out+=("$part") ;;
		esac
	done
	[ "${#out[@]}" -gt 0 ] || return 1
	IFS=/; printf '/%s' "${out[*]}"
}

# A relation is allowed when its name is one the kind lists and its comparison and version are of the form the kind lists
# (config/relations.txt, fourth column): NONE has neither, PROVIDED is none or "= version", LOWERBOUND is none or
# ">=", "=" or ">" with a version, so a package cannot force a host to an old or impossible version of anything. The
# rpmlib(...) entries are rpm's own and carry their own comparison.
VERSION_RE='^([0-9]+:)?[0-9A-Za-z._+~^-]+$'
relation_ok() { # <kind> <relation> <name> <comparison> <version>
	local rule expr form re
	rule="$(rows "$CONFIG_DIR/relations.txt" | awk -F'\t' -v k="$1" -v r="$2" '$1 == k && $2 == r { print $3 "\t" $4 }')"
	expr="${rule%%$'\t'*}"; form="${rule#*$'\t'}"
	[ "$form" != "$rule" ] || form=""
	if [ -z "$expr" ] || [ -z "$form" ]; then die "config/relations.txt has no $2 rule, or no form of it, for the kind '$1'"; fi
	[ "$expr" != NONE ] || return 1
	expr="${expr//NAME/$(escape "$PRODUCT")}"
	re="^($expr)$"
	[[ "$3" =~ $re ]] || return 1
	case "$3" in rpmlib\(*) return 0 ;; esac
	case "$form" in
		NONE) [ -z "$4" ] && [ -z "$5" ] ;;
		PROVIDED) [ -z "$4$5" ] || { [ "$4" = "=" ] && [[ "$5" =~ $VERSION_RE ]]; } ;;
		LOWERBOUND) [ -z "$4$5" ] || { [[ "$4" =~ ^(\>=|=|\>)$ ]] && [[ "$5" =~ $VERSION_RE ]]; } ;;
		*) die "config/relations.txt gives the form '$form' to $2 of '$1', which is none of NONE, PROVIDED and LOWERBOUND" ;;
	esac
}

# rich_ok <kind> <relation> <expression>: a rich (boolean) dependency is allowed only as the exact expression that
# config/rich-dependencies.txt lists for the kind and the relation
rich_ok() {
	rows "$CONFIG_DIR/rich-dependencies.txt" | awk -F'\t' -v k="$1" -v r="$2" -v e="$3" '$1 == k && $2 == r && $3 == e { f = 1 } END { exit !f }'
}
# rich_kind <kind>: whether the kind lists any rich dependency at all (rpm then adds rpmlib(RichDependencies) by itself)
rich_kind() {
	rows "$CONFIG_DIR/rich-dependencies.txt" | awk -F'\t' -v k="$1" '$1 == k { f = 1 } END { exit !f }'
}
# owner_ok <kind> <canonical path> <user:group> <mode>: a file that root does not own is allowed only where
# config/owners.txt lists it for the kind, and never under /usr, in a unit or when anyone can execute it
owner_ok() {
	local k="$1" p="$2" o="$3" m="$4" row lk lpath lowner
	case "$p" in /usr/* | *.service | *.socket | *.timer | *.path | */systemd/*) return 1 ;; esac
	[[ "${m:3:1}${m:6:1}${m:9:1}" != *[xsS]* ]] || return 1
	while IFS=$'\t' read -r lk lpath lowner; do
		[ "$lk" = "$k" ] || continue
		lpath="${lpath//NAME/$(escape "${f[0]}")}"
		if [[ "$p" =~ ^($lpath)$ ]] && [ "$lowner" = "$o" ]; then return 0; fi
	done < <(rows "$CONFIG_DIR/owners.txt")
	return 1
}
