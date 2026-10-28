#!/usr/bin/env bash
# Succeed iff the keychain has a code-signing identity whose name contains <name>.
#
#   macos/scripts/has_sign_identity.sh "Code Signing"
#
# Used by `just app-open` (pick the stable identity or fall back to ad hoc) and
# `just app-install` (fail before the build when the identity is missing).
# `security find-identity` opens with a "Policy: Code Signing" header, so matching the
# whole output finds "Code Signing" on every machine; only the numbered identity lines
# ("  1) <sha1> "<name>" (<status>)") are searched. Untrusted self-signed identities are
# listed too (the non -v form), as codesign accepts them.
#
# Exit 0: found. Exit 1: not found. Exit 2: usage.
set -euo pipefail

name="${1:-}"
[[ -n "$name" ]] || { echo "usage: has_sign_identity.sh <identity-name>" >&2; exit 2; }

# Capture, then grep: grep -q closing the pipe early would trip pipefail.
lines="$(security find-identity -p codesigning | grep -E '^[[:space:]]*[0-9]+\) ' || true)"
grep -qF -- "$name" <<<"$lines"
