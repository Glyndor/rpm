#!/usr/bin/env bash
#
# The one step that holds the archive key: import it, build the tree and sign it.
#
# Usage: sign-tree.sh <admitted-root> <out-tree>
#
# GLYNDOR_RPM_GPG_PRIVATE_KEY is the armored secret key. Before it is imported, every file of
# <admitted-root> is compared with the manifest readmit-products.sh wrote when no key was around
# (<root>.sha256): the bytes that are about to be opened with the key present are the bytes that were
# admitted. The key must be the one whose public half is committed (sign-packages.sh checks that, and
# that it is the only one). PRODUCTS and EPOCH come from the plan. The home of the key is a private
# folder removed at the end, whatever happens.
# Requires: what assemble-tree.sh requires.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/scripts/publish/parse-plan.sh"
die() { echo "::error::sign-tree: $*" >&2; exit 1; }
[ "$#" -eq 2 ] || die "usage: sign-tree.sh <admitted-root> <out-tree>"
ROOT="${1%/}"; OUT="$2"
[ -n "${GLYNDOR_RPM_GPG_PRIVATE_KEY:-}" ] || die "GLYNDOR_RPM_GPG_PRIVATE_KEY is not set; refusing to sign"
[ -f "$ROOT.sha256" ] || die "$ROOT.sha256 is missing; the files were not admitted in this job"
(cd "$ROOT" && sha256sum --strict --check --quiet "$ROOT.sha256") 2> /dev/null || die "a file of $ROOT is not what was admitted"
[ "$(cd "$ROOT" && find . -type f | wc -l)" -eq "$(wc -l < "$ROOT.sha256")" ] || die "$ROOT holds a file that was not admitted"

WORK="$(mktemp -d)"
GNUPGHOME="$WORK/gnupg"; export GNUPGHOME
trap 'GNUPGHOME="$WORK/gnupg" timeout 10 gpgconf --kill gpg-agent > /dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
mkdir -m 700 "$GNUPGHOME"
printf '%s\n' "$GLYNDOR_RPM_GPG_PRIVATE_KEY" | gpg --batch --import > /dev/null 2>&1 || die "the archive key cannot be imported"
unset GLYNDOR_RPM_GPG_PRIVATE_KEY
PLAN_CONFIG="$HERE/config/products.txt" parse_plan "${PRODUCTS:-}" "$WORK/plan" || exit 1
"$HERE/scripts/build/assemble-tree.sh" "$ROOT" "$WORK/plan" "$OUT" "${EPOCH:?EPOCH is not set}"
echo "signed tree at $OUT"
