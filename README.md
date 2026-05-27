# create-love-steam-game

[![npm version](https://img.shields.io/npm/v/create-love-steam-game)](https://www.npmjs.com/package/create-love-steam-game)

Scaffold a complete Love2D + Steam multiplayer game in seconds.

```bash
npx create-love-steam-game my-game
```

No installation needed — just run the command above. Node.js ≥ 18 required.

You get a fully wired project: Steam P2P networking, a working lobby (host/join/LAN/Steam), synchronized game state, a cross-platform build pipeline (love-build), and a Steam deploy script — all battle-tested and ready to run.

## What you get

```
my-game/
  conf.lua              Love2D config (identity, window, luasteam cpath)
  main.lua              State machine: menu → lobby → game
  src/
    steam.lua           Steam init wrapper (graceful no-op without Steam)
    steam_lobby.lua     Lobby creation, discovery, friend-game detection
    net.lua             P2P + LAN dual-transport networking layer
    lobby.lua           Full lobby UI: host/join, LAN discovery, Steam browse, chat
    menu.lua            Landing page with Host/Join/Quit buttons
    game_manager.lua    Placeholder game (score counter) showing full sync pipeline
    version.lua         Auto-stamped on every build (returns "dev" locally)
  scripts/
    build-native.sh     Cross-platform build via love-build (macOS/Windows/Linux)
    deploy-steam.sh     VDF generation + steamcmd upload
  lib/                  Drop luasteam .so/.dll/.dylib here (see lib/README.md)
  assets/fonts/
  VERSION               Semantic version (bump manually before release)
  .env.example          STEAM_USERNAME placeholder
  .gitignore
```

## Prerequisites

- [Love2D](https://love2d.org/) (≥ 11.5)
- Node.js ≥ 18 (for the CLI only)
- [steamcmd](https://developer.valvesoftware.com/wiki/SteamCMD) (for deploying to Steam)

## Quick start

```bash
npx create-love-steam-game my-game
cd my-game
love .
```

Two terminals → two instances → click "Host" in one, "Join" in the other via LAN. No Steam libraries needed for local testing.

## Steam setup (required for Steam features)

Steam P2P networking and lobby discovery require two native libraries in your `lib/` folder: **luasteam** (downloaded automatically by the scaffolder) and **steam_api** (must be obtained manually from Valve).

### 1. Download the Steamworks SDK

1. Go to [partner.steamgames.com/downloads/list](https://partner.steamgames.com/downloads/list) and sign in with your Steam account
2. Download the latest **Steamworks SDK** zip
3. Extract it anywhere on your machine

### 2. Copy steam_api into your project

From the extracted SDK, copy the platform-specific file into your project's `lib/` folder:

| Platform | SDK path | Destination |
|---|---|---|
| macOS | `redistributable_bin/osx/libsteam_api.dylib` | `lib/macos/libsteam_api.dylib` |
| Windows 64-bit | `redistributable_bin/win64/steam_api64.dll` | `lib/windows/steam_api64.dll` |
| Linux 64-bit | `redistributable_bin/linux64/libsteam_api.so` | `lib/linux/libsteam_api.so` |

```bash
# macOS example
cp ~/steamworks_sdk/redistributable_bin/osx/libsteam_api.dylib lib/macos/

# Windows example
cp ~/steamworks_sdk/redistributable_bin/win64/steam_api64.dll lib/windows/

# Linux example
cp ~/steamworks_sdk/redistributable_bin/linux64/libsteam_api.so lib/linux/
```

### 3. Set your App ID

If you used App ID `0` during scaffolding, your project defaults to **480 (Spacewar)** — Valve's public test app that any Steam account can use for development. This is fine for local testing.

When you have a real App ID, update `steam_appid.txt` in the project root with your ID.

## Building for Steam

```bash
# Build all platforms
scripts/build-native.sh

# Upload to Steam (alpha branch by default)
scripts/deploy-steam.sh --branch alpha

# Or do both in one step
scripts/deploy-steam.sh --build --branch beta
```

The build script auto-stamps `src/version.lua` with a timestamp on every build so version mismatches are detectable in logs.

## Networking architecture

```
Client                         Host
  │                              │
  ├─ LOBBY_JOIN ───────────────► │
  │ ◄──────────── LOBBY_STATE ───┤  (slot updates)
  │                              │
  ├─ LOBBY_READY ──────────────► │
  │ ◄──────────── LOBBY_START ───┤  (game begins)
  │                              │
  ├─ GAME_READY ───────────────► │
  │ ◄──────────── FULL_STATE ────┤  (authoritative state)
  │                              │
  ├─ SCORE_UPDATE ─────────────► │  (your game action)
  │ ◄──────────── FULL_STATE ────┤  (immediate response)
  │                              │
  │ ◄──────────── SYNC_CHECK ────┤  (every SYNC_CHECK_EVERY ticks)
  │ ◄──────────── GAME_TICK ─────┤  (every real second)
```

Transport is Steam P2P relay (ISteamNetworkingSockets) when available, enet UDP otherwise. The `src/net.lua` API is identical for both.

## Replacing the placeholder game

`src/game_manager.lua` ships a score-counter demo. To replace it:

1. Define your state in `get_full_state()` / `apply_full_state()`
2. Add your message types to `Net.MSG` in `src/net.lua`
3. Handle them in `handle_event(ev)`
4. Keep the `GAME_READY → FULL_STATE → SYNC_CHECK` handshake — it's what makes resync and late-join work

## License

MIT
