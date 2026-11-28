#!/usr/bin/env bash
#
# Fail when a job of this run carries a warning that something it uses is deprecated
# or is going away. GitHub reports those as annotations on the job (a Node runtime an
# action still runs on, a command it retired), and a run that is green with one is a
# run that stops working on a date nobody wrote down.
#
# Inputs (env): GH_TOKEN (read access to actions and checks), REPO, RUN_ID, and
# WAIT_FOR, the name of the job of the run that ends after the ones to read. The job
# that runs this carries no `needs:` and no `if:`, which the switch rule refuses, so it
# starts with the run and waits here: until that job is completed, for WAIT_SECONDS at
# most, asking every POLL_SECONDS. A job that does not end in time is a failure.
#
# It reads every job of the run and, for each, the annotations of level `warning` or
# `failure`, and fails when one of them matches PATTERN. A notice is not read: only a
# warning says that something has to change. A listing or a read that fails is a
# failure too, because a check that could not look has not found nothing.
set -uo pipefail

repo="${REPO:?REPO}"
run="${RUN_ID:?RUN_ID}"
case "$run" in *[!0-9]* | "") echo "::error::RUN_ID is not a number" >&2; exit 1 ;; esac
PATTERN='deprecat|no longer supported|will be (removed|disabled|retired)|forced to run on node'

last="${WAIT_FOR:?WAIT_FOR}"
wait_seconds="${WAIT_SECONDS:?WAIT_SECONDS}"
poll_seconds="${POLL_SECONDS:-30}"
case "$wait_seconds$poll_seconds" in *[!0-9]* | "") echo "::error::WAIT_SECONDS and POLL_SECONDS are numbers" >&2; exit 1 ;; esac

# The filters run in jq on what gh printed, so a test can plant the answers.
deadline=$((SECONDS + wait_seconds))
while :; do
	if ! listed="$(timeout 120 gh api --paginate "repos/${repo}/actions/runs/${run}/jobs?per_page=100" | jq -r '.jobs[]? | [(.id | tostring), .name, .status] | @tsv')"; then
		echo "::error::the jobs of run $run could not be listed, so their warnings were not read"
		exit 1
	fi
	if awk -F'\t' -v name="$last" '$2 == name && $3 == "completed" { found = 1 } END { exit !found }' <<<"$listed"; then
		break
	fi
	if [ "$SECONDS" -ge "$deadline" ]; then
		echo "::error::the job '$last' of run $run did not end in ${wait_seconds}s, so the warnings of the run were not read"
		exit 1
	fi
	sleep "$poll_seconds"
done
jobs="$(cut -f1,2 <<<"$listed")"

found=0
while IFS=$'\t' read -r id name; do
	[ -n "$id" ] || continue
	if ! notes="$(timeout 120 gh api --paginate "repos/${repo}/check-runs/${id}/annotations?per_page=100" | jq -r '.[]? | select(.annotation_level == "warning" or .annotation_level == "failure") | .message')"; then
		echo "::error::the annotations of '$name' could not be read, so they were not checked"
		found=1
		continue
	fi
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		if printf '%s\n' "$line" | grep -qiE "$PATTERN"; then
			echo "::error::'$name' carries a deprecation warning: $line"
			found=1
		fi
	done <<<"$notes"
done <<<"$jobs"

[ "$found" -eq 0 ] && echo "no job of run $run carries a deprecation warning"
exit "$found"
