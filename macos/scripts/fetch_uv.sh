#!/usr/bin/env bash
# Download the pinned uv release for Apple Silicon, verify its sha256, and cache
# it. Prints the path of the cached `uv` binary on stdout.
set -euo pipefail

UV_VERSION="0.12.5"
UV_ASSET="uv-aarch64-apple-darwin.tar.gz"
UV_SHA256="5bb0e5fe008a773c3dbcb97ff79cd89e1241464fe9d2f986d52ad8f1b037bd62"
UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${UV_ASSET}"

cache="${PIPECAT_TTS_BUILD_CACHE:-$HOME/Library/Caches/pipecat-tts-build}/uv/${UV_VERSION}"
if [[ -x "$cache/uv" && -f "$cache/.verified" ]]; then
    echo "$cache/uv"
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "fetch_uv: downloading uv ${UV_VERSION}" >&2
curl -fsSL --retry 3 -o "$tmp/$UV_ASSET" "$UV_URL"
echo "$UV_SHA256  $tmp/$UV_ASSET" | shasum -a 256 -c - >&2
tar -xzf "$tmp/$UV_ASSET" -C "$tmp"
mkdir -p "$cache"
install -m 0755 "$tmp/uv-aarch64-apple-darwin/uv" "$cache/uv"
xattr -d com.apple.quarantine "$cache/uv" 2>/dev/null || true
touch "$cache/.verified"
echo "$cache/uv"
