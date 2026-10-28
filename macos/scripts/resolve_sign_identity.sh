#!/usr/bin/env bash
# Print the code-signing identity the app recipes sign with.
#
#   SIGN_IDENTITY="$(macos/scripts/resolve_sign_identity.sh)"            # just app-open
#   SIGN_IDENTITY="$(macos/scripts/resolve_sign_identity.sh --require)"  # just app-install
#
# Where `just app-open` and `just app-install` choose their default identity (build_app.sh,
# run alone by `just app-build`, keeps its own ad-hoc "-" default). An explicit SIGN_IDENTITY
# (non-empty; a name, a substring of one, or the full SHA-1 hash, as codesign takes it)
# always wins. Unset, the default is the self-signed "Code Signing" identity: its designated
# requirement (bundle id + cert) is stable across rebuilds, so Microphone / Speech
# Recognition grants survive them, where ad hoc ("-") is cdhash-bound and resets them.
#
#   (no flag)  unset: "Code Signing" when the keychain has it, else "-" (ad hoc).
#              explicit: printed as is, the keychain is not asked.
#   --require  no ad-hoc fallback: the identity (explicit, or the default when unset) must be
#              in the keychain (macos/scripts/has_sign_identity.sh), checked before the build
#              because signing is its last step.
#              An explicit "-" is printed as is.
#
# The keychain check is advisory (has_sign_identity.sh): a full 40-hex SHA-1 (any case) must
# be a listed hash, anything else a case-insensitive substring of a listed name, as codesign
# reads it. An ambiguous name (two identities share it) still counts as present: codesign
# decides that at signing, after the build.
#
# Assign and export in two steps (`export X="$(…)"` would hide a failure from set -e).
# Exit 0: identity printed. Exit 1: --require and it is not in the keychain. Exit 2: usage,
# or the keychain query failed (never read as "absent", which would sign ad hoc silently).
set -euo pipefail

default_identity="Code Signing"
require=""
case "${1:-}" in
    "") ;;
    --require) require=1 ;;
    *) echo "usage: resolve_sign_identity.sh [--require]" >&2; exit 2 ;;
esac
(($# <= 1)) || { echo "usage: resolve_sign_identity.sh [--require]" >&2; exit 2; }

explicit="${SIGN_IDENTITY:-}"
if [[ -n "$explicit" && ( -z "$require" || "$explicit" == "-" ) ]]; then
    printf '%s\n' "$explicit"
    exit 0
fi
identity="${explicit:-$default_identity}"

rc=0
"$(dirname "$0")/has_sign_identity.sh" "$identity" || rc=$?
case "$rc" in
    0) printf '%s\n' "$identity" ;;
    1)
        if [[ -n "$require" ]]; then
            echo "error: no code-signing identity matching '$identity' (security find-identity -p codesigning)" >&2
            exit 1
        fi
        printf '%s\n' "-"
        ;;
    *) exit 2 ;;
esac
