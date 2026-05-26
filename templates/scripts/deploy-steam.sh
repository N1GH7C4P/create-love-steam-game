#!/usr/bin/env bash
set -euo pipefail

# {{GAME_NAME}} — Steam Deploy Script
# Stages dist/ artifacts and uploads to Steam via steamcmd.
#
# Prerequisites:
#   1. Install steamcmd:  brew install steamcmd  (macOS)
#                         # or follow: https://developer.valvesoftware.com/wiki/SteamCMD
#   2. Add to .env:
#        STEAM_USERNAME=<steam publisher account username>
#   3. Build artifacts:   scripts/build-native.sh
#      (or pass --build to do it automatically)
#
# First-time steamcmd login requires a Steam Guard code.
# Run once to cache credentials:
#   steamcmd +login YOUR_USERNAME +quit
#
# Usage:
#   scripts/deploy-steam.sh [options]
#
# Options:
#   --build           Run build-native.sh before deploying
#   --branch NAME     Set build live on branch NAME after upload (default: alpha)
#   --no-live         Upload only, do not set live on any branch
#   --preview         Generate VDF files but skip the actual upload (dry run)
#   --version VER     Override version (default: reads VERSION file)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Parse arguments ───────────────────────────────────────────────────────────
BRANCH="alpha"
SET_LIVE=true
DO_BUILD=false
PREVIEW=false
VERSION_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build)    DO_BUILD=true ;;
        --branch)   BRANCH="$2"; shift ;;
        --no-live)  SET_LIVE=false ;;
        --preview)  PREVIEW=true ;;
        --version)  VERSION_OVERRIDE="$2"; shift ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
    shift
done

# ── Steam App / Depot IDs ─────────────────────────────────────────────────────
GAME_NAME="{{GAME_NAME}}"
BUILD_NAME=$(echo "$GAME_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
STEAM_APP_ID="{{STEAM_APP_ID}}"
STEAM_DEPOT_MACOS="{{STEAM_DEPOT_MACOS}}"
STEAM_DEPOT_WINDOWS="{{STEAM_DEPOT_WINDOWS}}"
STEAM_DEPOT_LINUX="{{STEAM_DEPOT_LINUX}}"

# ── Load .env ─────────────────────────────────────────────────────────────────
ENV_FILE="$REPO_ROOT/.env"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

if [ -z "${STEAM_USERNAME:-}" ]; then
    echo "Error: STEAM_USERNAME not set."
    echo "Add it to $ENV_FILE:"
    echo "  STEAM_USERNAME=your_publisher_account"
    exit 1
fi

VERSION="${VERSION_OVERRIDE:-$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")}"
LIVE_BRANCH="$( [ "$SET_LIVE" = true ] && echo "$BRANCH" || echo "" )"

echo "=== $GAME_NAME — Steam Deploy ==="
echo "  Version : $VERSION"
echo "  App ID  : $STEAM_APP_ID"
echo "  Branch  : ${LIVE_BRANCH:-"(none — upload only)"}"
echo "  Preview : $PREVIEW"
echo ""

if [ "$DO_BUILD" = true ]; then
    echo "=== Building ==="
    "$SCRIPT_DIR/build-native.sh"
    echo ""
fi

# ── Verify dist artifacts ─────────────────────────────────────────────────────
DIST_DIR="$REPO_ROOT/dist/$VERSION"
for PLATFORM in windows macos linux; do
    ARTIFACT="$DIST_DIR/${BUILD_NAME}-${PLATFORM}.zip"
    if [ ! -f "$ARTIFACT" ]; then
        echo "Error: Missing artifact: $ARTIFACT"
        echo "Run scripts/build-native.sh first, or pass --build."
        exit 1
    fi
done

# ── Stage artifacts ───────────────────────────────────────────────────────────
STAGING_ROOT="$REPO_ROOT/.build-staging/steam/$VERSION"
echo "=== Staging artifacts ==="

[ -d "$STAGING_ROOT" ] && chmod -R u+rwX "$STAGING_ROOT"
rm -rf "$STAGING_ROOT"

for PLATFORM in windows macos linux; do
    STAGE_DIR="$STAGING_ROOT/$PLATFORM"
    mkdir -p "$STAGE_DIR"
    echo "  $PLATFORM..."
    unzip -qo "$DIST_DIR/${BUILD_NAME}-${PLATFORM}.zip" -d "$STAGE_DIR"
    chmod -R u+rwX "$STAGE_DIR"
done

# ── Generate VDF files ────────────────────────────────────────────────────────
VDF_DIR="$STAGING_ROOT/vdf"
mkdir -p "$VDF_DIR" "$VDF_DIR/output"
echo ""
echo "=== Generating VDF files ==="

cat > "$VDF_DIR/depot_windows.vdf" << EOF
"DepotBuildConfig"
{
    "DepotID"  "$STEAM_DEPOT_WINDOWS"
    "ContentRoot"  "$STAGING_ROOT/windows/"
    "FileMapping"
    {
        "LocalPath"  "*"
        "DepotPath"  "."
        "Recursive"  "1"
    }
}
EOF

cat > "$VDF_DIR/depot_macos.vdf" << EOF
"DepotBuildConfig"
{
    "DepotID"  "$STEAM_DEPOT_MACOS"
    "ContentRoot"  "$STAGING_ROOT/macos/"
    "FileMapping"
    {
        "LocalPath"  "*"
        "DepotPath"  "."
        "Recursive"  "1"
    }
    "FileExclusion"  "*.DS_Store"
}
EOF

cat > "$VDF_DIR/depot_linux.vdf" << EOF
"DepotBuildConfig"
{
    "DepotID"  "$STEAM_DEPOT_LINUX"
    "ContentRoot"  "$STAGING_ROOT/linux/"
    "FileMapping"
    {
        "LocalPath"  "*"
        "DepotPath"  "."
        "Recursive"  "1"
    }
}
EOF

cat > "$VDF_DIR/app_build.vdf" << EOF
"AppBuild"
{
    "AppID"       "$STEAM_APP_ID"
    "Desc"        "$GAME_NAME v$VERSION"
    "Preview"     "0"
    "Local"       ""
    "SetLive"     "$LIVE_BRANCH"
    "BuildOutput" "$VDF_DIR/output/"
    "Depots"
    {
        "$STEAM_DEPOT_WINDOWS"  "$VDF_DIR/depot_windows.vdf"
        "$STEAM_DEPOT_MACOS"    "$VDF_DIR/depot_macos.vdf"
        "$STEAM_DEPOT_LINUX"    "$VDF_DIR/depot_linux.vdf"
    }
}
EOF

echo "  app_build.vdf written"

# ── Dry run exit ──────────────────────────────────────────────────────────────
if [ "$PREVIEW" = true ]; then
    echo ""
    echo "=== Preview — skipping upload ==="
    echo "  Staged content : $STAGING_ROOT/"
    echo "  VDF files      : $VDF_DIR/"
    echo ""
    echo "  To upload manually:"
    echo "    steamcmd +login \"$STEAM_USERNAME\" \\"
    echo "             +run_app_build \"$VDF_DIR/app_build.vdf\" \\"
    echo "             +quit"
    exit 0
fi

# ── Upload via steamcmd ───────────────────────────────────────────────────────
echo ""
echo "=== Uploading to Steam ==="

if ! command -v steamcmd &>/dev/null; then
    echo "Error: steamcmd not found."
    echo "Install with: brew install steamcmd  (macOS)"
    echo "See: https://developer.valvesoftware.com/wiki/SteamCMD"
    echo ""
    echo "After installing, run once to cache credentials:"
    echo "  steamcmd +login \"$STEAM_USERNAME\" +quit"
    exit 1
fi

steamcmd \
    +login "$STEAM_USERNAME" \
    +run_app_build "$VDF_DIR/app_build.vdf" \
    +quit

echo ""
echo "=== Deploy complete ==="
if [ -n "$LIVE_BRANCH" ]; then
    echo "  Build v$VERSION set live on branch: $LIVE_BRANCH"
fi
echo "  Builds page : https://partner.steamgames.com/apps/builds/$STEAM_APP_ID"
echo "  Build log   : $VDF_DIR/output/"
