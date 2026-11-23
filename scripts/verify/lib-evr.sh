#!/usr/bin/env bash
#
# How versions are read and ordered, as rpm orders them: shared by the admission (the floor of a release) and by the check
# that a change never lowers a floor, so that both read a tag the same way. Sourced, not run. Each function answers with
# its status (and a value on its output) and never ends the shell that calls it: the caller checks the status in its own
# shell, because a failure inside `$(...)` that sits in a condition is swallowed.
# shellcheck shell=bash

# evr_of <tag> <kind>: the version a package carries for a tag. A Podman tag always carries its revision (`+rN`, and `+r1`
# when the tag has none); the other products have no revision.
evr_of() {
	[[ "$1" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(\+r([0-9]+))?$ ]] || return 1
	if [ "$2" = podman ]; then
		printf '%s+r%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]:-1}"
	else
		[ -z "${BASH_REMATCH[2]}" ] || return 1
		printf '%s' "${BASH_REMATCH[1]}"
	fi
}

# vercmp <version> <version>: -1, 0 or 1 as rpm orders them; status 1 when rpm cannot say
vercmp() {
	local r
	[[ "$1" =~ ^[0-9A-Za-z._+~^-]+$ && "$2" =~ ^[0-9A-Za-z._+~^-]+$ ]] || return 1
	r="$(rpm --noplugins --rcfile /dev/null --macros /dev/null --eval "%{lua: print(rpm.vercmp('$1', '$2'))}" 2> /dev/null)" || return 1
	case "$r" in -1 | 0 | 1) printf '%s' "$r" ;; *) return 1 ;; esac
}
