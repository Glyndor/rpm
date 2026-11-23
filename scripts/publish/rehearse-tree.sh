#!/usr/bin/env bash
#
# The rehearsal: build the whole tree from the downloaded releases and sign it with a key made here.
#
# Usage: rehearse-tree.sh <admitted-root> <out-tree>
#
# No secret is read and nothing is uploaded. The archive key is NOT used: a throwaway key signs the
# packages and the metadata, and the committed key still checks what the channel serves today, so
# the order check is the real one. PRODUCTS and EPOCH come from the plan.
# Requires: what assemble-tree.sh requires.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091 # the path is resolved at run time
. "$HERE/scripts/publish/parse-plan.sh"
die() { echo "::error::rehearse-tree: $*" >&2; exit 1; }
[ "$#" -eq 2 ] || die "usage: rehearse-tree.sh <admitted-root> <out-tree>"
if [ -n "${GLYNDOR_RPM_GPG_PRIVATE_KEY:-}" ]; then die "the rehearsal reads no secret, and the archive key is in its environment"; fi
WORK="$(mktemp -d)"
GNUPGHOME="$WORK/gnupg"; export GNUPGHOME
trap 'GNUPGHOME="$WORK/gnupg" timeout 10 gpgconf --kill gpg-agent > /dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
mkdir -m 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key 'Glyndor rehearsal <rehearsal@example.invalid>' ed25519 sign 1d > /dev/null 2>&1 \
	|| die "cannot make the throwaway key"
gpg --batch --armor --export > "$WORK/rehearsal.asc"
PLAN_CONFIG="$HERE/config/products.txt" parse_plan "${PRODUCTS:-}" "$WORK/plan" || exit 1
"$HERE/scripts/build/assemble-tree.sh" --key "$WORK/rehearsal.asc" --served-key "$HERE/keyring/glyndor-rpm-key.asc" \
	"$1" "$WORK/plan" "$2" "${EPOCH:?EPOCH is not set}"
echo "rehearsal tree at $2, signed with a throwaway key"
