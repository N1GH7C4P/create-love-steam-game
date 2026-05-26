-- Steam integration wrapper around luasteam.
-- All functions are no-ops when Steam is unavailable so the game runs without it.
-- Uses luasteam v5 API (PascalCase: Init, Shutdown, RunCallbacks, GetPersonaName, etc.)

local Steam = {}

local _lib = nil
local _ok, _err = pcall(function() _lib = require("luasteam") end)

-- Steam.available is true only when luasteam loaded AND Steam client is running + logged in.
Steam.available = false
-- Steam.status_detail carries a human-readable reason when unavailable (shown in lobby UI).
Steam.status_detail = ""

if _ok and _lib then
	local init_ok, init_err = pcall(function() Steam.available = (_lib.Init() == true) end)
	if not init_ok then
		Steam.available = false
		Steam.status_detail = "init error: " .. tostring(init_err)
	elseif not Steam.available then
		Steam.status_detail = "Steam.Init() returned false"
	end
end

if Steam.available then
	-- Expose sub-interfaces (luasteam v5 uses PascalCase table names)
	Steam.matchmaking       = _lib.Matchmaking
	Steam.friends           = _lib.Friends
	Steam.user              = _lib.User
	Steam.utils             = _lib.Utils
	Steam.netsockets        = _lib.NetworkingSockets  -- ISteamNetworkingSockets (P2P relay)
	print("[Steam] Initialized. luasteam loaded successfully.")
else
	Steam.matchmaking       = nil
	Steam.friends           = nil
	Steam.user              = nil
	Steam.utils             = nil
	Steam.netsockets        = nil
	if _ok then
		if Steam.status_detail == "" then Steam.status_detail = "Steam client not running or not logged in" end
		print("[Steam] luasteam loaded but Steam.Init() failed — " .. Steam.status_detail)
	else
		Steam.status_detail = tostring(_err)
		print("[Steam] luasteam not found — Steam features disabled. (" .. Steam.status_detail .. ")")
	end
end

-- Call once per frame in love.update BEFORE any other logic.
function Steam.run_callbacks()
	if Steam.available then
		pcall(_lib.RunCallbacks)
	end
end

-- Call in love.quit.
function Steam.shutdown()
	if Steam.available then
		pcall(_lib.Shutdown)
	end
end

-- Returns the current user's Steam display name, or a fallback.
function Steam.my_name()
	if not Steam.available then return "Player" end
	local ok, name = pcall(function() return _lib.Friends.GetPersonaName() end)
	return (ok and name and #name > 0) and name or "Player"
end

-- Unlocks a Steam achievement by API name.
-- No-op (and no error) when Steam is unavailable.
function Steam.unlock_achievement(api_name)
	if not Steam.available then return end
	pcall(function()
		_lib.UserStats.SetAchievement(api_name)
		_lib.UserStats.StoreStats()
	end)
end

-- Returns the current user's SteamID64 userdata, or nil.
function Steam.my_steam_id()
	if not Steam.available then return nil end
	local ok, sid = pcall(function() return _lib.User.GetSteamID() end)
	return ok and sid or nil
end

-- Converts a SteamID userdata to a printable string (for lobby metadata).
function Steam.id_to_string(steam_id)
	if not steam_id then return "" end
	local ok, s = pcall(tostring, steam_id)
	return ok and s or ""
end

return Steam
