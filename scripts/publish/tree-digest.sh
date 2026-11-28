#!/usr/bin/env bash
#
# Print one sha256 that stands for every file of a tree, by path and by content.
#
# Usage: tree-digest.sh <tree>
#
# The job that signs prints it as an output of the job; the job that publishes computes it again over the
# artifact it downloaded and refuses anything else. An artifact is data that travelled through a store this
# repository does not control, so its identity is checked against what the signing job said it produced. A link
# or any file that is neither a regular file nor a folder stops the run: the digest of a link would be the
# digest of whatever it points at on the machine that reads it.
# Requires: sha256sum.
set -euo pipefail
export LC_ALL=C
die() { echo "::error::tree-digest: $*" >&2; exit 1; }
if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then die "usage: tree-digest.sh <tree>"; fi
if find "$1" -mindepth 1 ! -type f ! -type d -print -quit | grep -q .; then die "$1 holds something that is neither a file nor a folder"; fi
(cd "$1" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum) | sha256sum | cut -d' ' -f1
