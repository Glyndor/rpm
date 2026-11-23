#!/usr/bin/env bash
#
# Refuse to publish a plan that is no longer the current one.
#
# Usage: check-plan-age.sh <plan epoch> <max age in seconds> [now]
#
# The plan job fixes, once, the commit and the tag of each product at an instant. A run that is retried hours later
# (run_attempt above 1, or an approval that waited a day) would publish those choices as if they were today's, and
# could put back what a later release replaced. The age counts from the plan, and the limit leaves room for the three
# jobs and the approval of the environment.
set -euo pipefail
die() { echo "::error::check-plan-age: $*" >&2; exit 1; }
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then die "usage: check-plan-age.sh <plan epoch> <max age in seconds> [now]"; fi
[[ "$1" =~ ^[0-9]{9,11}$ && "$2" =~ ^[0-9]{1,7}$ ]] || die "the plan epoch and the limit must be numbers"
now="${3:-$(date +%s)}"
[[ "$now" =~ ^[0-9]{9,11}$ ]] || die "the clock is not a number"
[ "$now" -ge "$1" ] || die "the plan is from the future ($1 against $now)"
age=$((now - $1))
[ "$age" -le "$2" ] || die "the plan is $age seconds old and the limit is $2: run the workflow again instead of retrying this one"
echo "the plan is $age seconds old"
