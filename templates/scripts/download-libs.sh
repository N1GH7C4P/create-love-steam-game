#!/usr/bin/env bash
set -euo pipefail

# Downloads luasteam native libraries from the latest GitHub release.
# Run this once after cloning, or again to update luasteam.
#
# steam_api (libsteam_api.dylib / steam_api64.dll / libsteam_api.so) must be
# obtained separately from the Steamworks SDK:
#   https://partner.steamgames.com/downloads/list
# Place those files alongside luasteam in the appropriate lib/ subdirectory.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB_DIR="$REPO_ROOT/lib"
API_URL="https://api.github.com/repos/uspgamedev/luasteam/releases/latest"

echo "=== Downloading luasteam ==="

# Fetch latest release tag and asset URLs
RELEASE_JSON=$(curl -sf "$API_URL")
TAG=$(echo "$RELEASE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
echo "  Latest release: $TAG"

get_url() {
    echo "$RELEASE_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
name = sys.argv[1]
for a in data['assets']:
    if a['name'] == name:
        print(a['browser_download_url'])
        break
" "$1"
}

mkdir -p "$LIB_DIR/macos" "$LIB_DIR/linux" "$LIB_DIR/windows"

# macOS
URL=$(get_url "osx_luasteam.so")
if [ -n "$URL" ]; then
    curl -sfL "$URL" -o "$LIB_DIR/macos/luasteam.so"
    echo "  ✔ lib/macos/luasteam.so"
fi

# Linux 64-bit
URL=$(get_url "linux64_luasteam.so")
if [ -n "$URL" ]; then
    curl -sfL "$URL" -o "$LIB_DIR/linux/luasteam.so"
    echo "  ✔ lib/linux/luasteam.so"
fi

# Windows 64-bit
URL=$(get_url "win64_luasteam.dll")
if [ -n "$URL" ]; then
    curl -sfL "$URL" -o "$LIB_DIR/windows/luasteam.dll"
    echo "  ✔ lib/windows/luasteam.dll"
fi

echo ""
echo "  ⚠ steam_api files are not included — download the Steamworks SDK:"
echo "    https://partner.steamgames.com/downloads/list"
echo "    lib/macos/libsteam_api.dylib"
echo "    lib/windows/steam_api64.dll"
echo "    lib/linux/libsteam_api.so"
echo ""
echo "=== Done ==="
