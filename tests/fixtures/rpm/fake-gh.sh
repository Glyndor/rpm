#!/usr/bin/env bash
# A stand-in for `gh` that the rpm tests put first on PATH. It answers the three calls the channel
# makes from files and variables, and writes each call to $FAKE_GH_LOG.
#   FAKE_GH_VIEW        JSON that `gh release view --json tagName,assets` prints
#   FAKE_GH_SRC         directory `gh release download` copies from (the pattern is a real glob)
#   FAKE_GH_FAIL        a file name whose download fails
#   FAKE_GH_BAD_ATTEST  a file name whose attestation does not verify
#   FAKE_GH_SHA         the commit `gh api repos/<repo>/commits/<tag>` answers
#   FAKE_GH_ATTEST_REF  the ref the attestations were made for: one asked for with another --source-ref fails
#   FAKE_GH_ATTEST_SHA  the same for --source-digest
printf '%s\n' "$*" >> "${FAKE_GH_LOG:-/dev/null}"
case "$1 $2" in
	"release view") cat "$FAKE_GH_VIEW" ;;
	"release download")
		pattern="" dir=""
		while [ "$#" -gt 0 ]; do
			case "$1" in --pattern) pattern="$2"; shift ;; --dir) dir="$2"; shift ;; esac
			shift
		done
		[ "$pattern" != "${FAKE_GH_FAIL:-}" ] || exit 1
		shopt -s nullglob
		for f in "$FAKE_GH_SRC"/$pattern; do cp "$f" "$dir/"; done ;;
	"attestation verify")
		[ "$(basename "$3")" != "${FAKE_GH_BAD_ATTEST:-}" ] || exit 1
		while [ "$#" -gt 0 ]; do
			case "$1" in
				--source-ref) [ -z "${FAKE_GH_ATTEST_REF:-}" ] || [ "$2" = "$FAKE_GH_ATTEST_REF" ] || exit 1 ;;
				--source-digest) [ -z "${FAKE_GH_ATTEST_SHA:-}" ] || [ "$2" = "$FAKE_GH_ATTEST_SHA" ] || exit 1 ;;
			esac
			shift
		done ;;
	"api repos"*|"api "*) printf '%s\n' "${FAKE_GH_SHA:-}" ;;
	*) echo "fake gh: unexpected call: $*" >&2; exit 2 ;;
esac
