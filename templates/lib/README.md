# Native libraries

Place luasteam native libraries here before building.

## Directory structure

```
lib/
  macos/
    luasteam.so
    libsteam_api.dylib
  windows/
    luasteam.dll
    steam_api64.dll
  linux/
    luasteam.so
    libsteam_api.so
```

## Where to get them

**luasteam** — prebuilt binaries for each platform:
https://github.com/uspgamedev/luasteam/releases

Download the release matching your target platform, extract the `.so` / `.dll` files,
and place them in the correct subdirectory above.

**steam_api** — comes with the Steamworks SDK:
https://partner.steamgames.com/downloads/list

> The game will run without these files (Steam features are silently disabled),
> so you can develop and test locally without them. They are only required for
> Steam P2P networking and Steam lobby discovery.
