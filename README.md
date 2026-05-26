# create-love-steam-game

Scaffold a complete Love2D + Steam multiplayer game in seconds.

```bash
npx create-love-steam-game my-game
```

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
- [luasteam](https://github.com/uspgamedev/luasteam/releases) native libraries (for Steam features)
- [steamcmd](https://developer.valvesoftware.com/wiki/SteamCMD) (for deploying to Steam)

## Quick start

```bash
npx create-love-steam-game my-game
cd my-game
love .
```

Two terminals → two instances → click "Host" in one, "Join" in the other via LAN. No Steam libraries needed for local testing.

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
  │ ◄──────────── SYNC_CHECK ────┤  (every 3 sim-ticks)
  │ ◄──────────── DAY_TICK ──────┤  (every real second)
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
