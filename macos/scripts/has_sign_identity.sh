#!/usr/bin/env bash
# Succeed when the keychain lists a code-signing identity that <identity> names.
#
#   macos/scripts/has_sign_identity.sh "Code Signing"
#
# Private probe of macos/scripts/resolve_sign_identity.sh (its only caller, which `just
# app-open` and `just app-install` call); kept apart so the listing parse is testable alone.
#
# ADVISORY: an early "is something here that codesign might accept" check, run before the
# build because signing is its last step. codesign decides at signing; this only reads the
# listing the way codesign reads <identity> (`codesign --sign`):
#   - exactly 40 hex digits (any case) is a SHA-1 hash, decided on the hash list alone: a
#     listed hash is found, any other is not (never retried as a name);
#   - anything else is a case-insensitive substring of a name (codesign matches names
#     without regard to case: `codesign -s 'code signing'` signs with "Code Signing").
# Only the numbered identity lines ("  1) <sha1> "<name>" (<status>)") are read, and of each
# only the hash and the quoted name: the listing opens with a "Policy: Code Signing" header
# (so matching the whole output finds "Code Signing" on every machine), and a partial hash
# or the status (CSSMERR_TP_NOT_TRUSTED) names no identity. Untrusted self-signed identities
# are listed too (the non -v form), as codesign accepts them. Ambiguity is not detected: two
# identities with the same name both match it, and whether codesign takes such a name is
# its call at signing (the full hash picks exactly one).
#
# Exit 0: found. Exit 1: not found. Exit 2: usage, or `security` itself failed (so a
# broken keychain query is never mistaken for a missing identity).
set -euo pipefail

identity="${1:-}"
[[ -n "$identity" ]] || { echo "usage: has_sign_identity.sh <identity>" >&2; exit 2; }

listing="$(security find-identity -p codesigning)" || {
    echo "error: security find-identity -p codesigning failed (exit $?)" >&2
    exit 2
}
# "<HASH> <name>" per numbered line, hash upper-cased (greedy, so a name holding quotes stays whole).
entries="$(sed -n -E 's/^[[:space:]]*[0-9]+\) ([0-9A-Fa-f]+) "(.*)".*$/\1 \2/p' <<<"$listing")"
hashes="$(cut -d' ' -f1 <<<"$entries" | tr '[:lower:]' '[:upper:]')"
names="$(cut -d' ' -f2- <<<"$entries")"

if [[ "$identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    if grep -qxF -- "$(tr '[:lower:]' '[:upper:]' <<<"$identity")" <<<"$hashes"; then
        exit 0
    fi
    exit 1
fi
if grep -qiF -- "$identity" <<<"$names"; then
    exit 0
fi
exit 1
