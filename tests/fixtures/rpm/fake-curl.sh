#!/usr/bin/env bash
# A stand-in for `curl` for the purge test: records the request body ($FAKE_CURL_BODIES, one line per
# call), the arguments ($FAKE_CURL_ARGS) and what arrived on stdin ($FAKE_CURL_STDIN), then answers
# $FAKE_CURL_REPLY (default {"success":true}) or exits $FAKE_CURL_RC.
printf '%s\n' "$*" >> "$FAKE_CURL_ARGS"
cat >> "$FAKE_CURL_STDIN"
while [ "$#" -gt 0 ]; do
	if [ "$1" = --data ]; then printf '%s\n' "$2" >> "$FAKE_CURL_BODIES"; fi
	shift
done
[ "${FAKE_CURL_RC:-0}" -eq 0 ] || exit "$FAKE_CURL_RC"
printf '%s' "${FAKE_CURL_REPLY:-{\"success\":true\}}"
