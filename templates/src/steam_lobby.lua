-- Steam lobby management: create, browse, join, and friend-game detection.
-- Uses ISteamMatchmaking via luasteam v5. All functions no-op when Steam unavailable.
--
-- luasteam v5 API notes:
--   Callbacks are set as fields on the interface table (not registerCallback).
--   Data fields use C++ struct names with m_ prefix.
--   Enum values are integers: k_ELobbyTypePublic=3, k_ELobbyComparisonEqual=0, k_EFriendFlagImmediate=4

local SteamLobby = {}

local Steam = require("src.steam")

local GAME_TAG         = "{{GAME_TAG}}"
local GAME_VERSION     = "1"
local REFRESH_INTERVAL = 10  -- seconds between auto-refreshes

local k_ELobbyTypePublic       = 3
local k_ELobbyComparisonEqual  = 0
local k_EFriendFlagImmediate   = 4

-- ── State ─────────────────────────────────────────────────────────────────────

local _lobby_id        = nil   -- current lobby SteamID (host or joined client)
local _lobby_list      = {}    -- [{name, players, max, lobby_id}]
local _friend_games    = {}    -- [{friend_name, lobby_id}]
local _refresh_timer   = 0
local _list_pending    = false -- waiting for LobbyMatchList callback
local _on_join         = nil   -- callback(host_steam_id) called after joining lobby
local _on_host_created = nil   -- callback() called after lobby created successfully

-- ── Global callbacks (luasteam v5: set as fields on interface tables) ─────────

if Steam.available then
	Steam.matchmaking.OnLobbyMatchList = function(data)
		_list_pending = false
		_lobby_list = {}
		local n = data.m_nLobbiesMatching or 0
		for i = 1, n do
			local lid = Steam.matchmaking.GetLobbyByIndex(i - 1)
			if lid then
				local name    = Steam.matchmaking.GetLobbyData(lid, "name")    or "Unnamed"
				local players = Steam.matchmaking.GetLobbyData(lid, "players") or "?"
				local max     = Steam.matchmaking.GetLobbyData(lid, "max")     or "?"
				_lobby_list[#_lobby_list + 1] = {
					name     = name,
					players  = tonumber(players) or 0,
					max      = tonumber(max)     or 0,
					lobby_id = lid,
				}
			end
		end
		print("[SteamLobby] Lobby list updated: " .. #_lobby_list .. " game(s) found.")
	end

	if Steam.friends then
		-- Fires when player clicks "Join" in Steam overlay
		Steam.friends.OnGameLobbyJoinRequested = function(data)
			print("[SteamLobby] GameLobbyJoinRequested from overlay")
			if data.m_steamIDLobby then
				SteamLobby.join(data.m_steamIDLobby)
			end
		end

		-- Fires via rich-presence connect string
		Steam.friends.OnGameRichPresenceJoinRequested = function(data)
			local connect = data and data.m_rgchConnect or ""
			print("[SteamLobby] GameRichPresenceJoinRequested: " .. connect)
			local lobby_id_str = connect:match("^%+connect_lobby%s+(.+)$")
			if lobby_id_str and SteamLobby._on_overlay_join then
				SteamLobby._on_overlay_join(lobby_id_str)
			end
		end
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function SteamLobby.create(game_name, max_players, on_created)
	if not Steam.available then
		if on_created then on_created() end
		return
	end
	_on_host_created = function()
		local lid = _lobby_id
		Steam.matchmaking.SetLobbyData(lid, "game",    GAME_TAG)
		Steam.matchmaking.SetLobbyData(lid, "version", GAME_VERSION)
		Steam.matchmaking.SetLobbyData(lid, "name",    game_name or "{{GAME_NAME}}")
		Steam.matchmaking.SetLobbyData(lid, "players", "1")
		Steam.matchmaking.SetLobbyData(lid, "max",     tostring(max_players or 4))
		if Steam.friends then
			pcall(Steam.friends.SetRichPresence, "status",        "Hosting — " .. (game_name or "{{GAME_NAME}}"))
			pcall(Steam.friends.SetRichPresence, "steam_display", "#Status_InGame")
			pcall(Steam.friends.SetRichPresence, "connect",       "+connect_lobby " .. Steam.id_to_string(lid))
		end
		if on_created then on_created() end
	end
	Steam.matchmaking.CreateLobby(k_ELobbyTypePublic, max_players or 4, function(data, io_fail)
		if io_fail or not data or data.m_eResult ~= 1 then
			print("[SteamLobby] CreateLobby failed, result=" .. tostring(data and data.m_eResult))
			return
		end
		_lobby_id = data.m_ulSteamIDLobby
		if _on_host_created then _on_host_created() end
	end)
end

function SteamLobby.refresh_list()
	if not Steam.available then return end
	if _list_pending then return end
	_list_pending = true
	_refresh_timer = 0
	Steam.matchmaking.AddRequestLobbyListStringFilter("game",    GAME_TAG,      k_ELobbyComparisonEqual)
	Steam.matchmaking.AddRequestLobbyListStringFilter("version", GAME_VERSION,  k_ELobbyComparisonEqual)
	Steam.matchmaking.RequestLobbyList()
end

function SteamLobby.get_list()
	return _lobby_list
end

function SteamLobby.get_friend_games()
	if not Steam.available then return {} end
	local result = {}
	local ok, count = pcall(function()
		return Steam.friends.GetFriendCount(k_EFriendFlagImmediate)
	end)
	if not ok or not count then return {} end
	for i = 0, count - 1 do
		local friend_id = Steam.friends.GetFriendByIndex(i, k_EFriendFlagImmediate)
		if friend_id then
			local ok2, is_playing, info = pcall(function()
				return Steam.friends.GetFriendGamePlayed(friend_id)
			end)
			if ok2 and is_playing and info then
				local game_id_str = tostring(info.m_gameID or "")
				if game_id_str == "{{STEAM_APP_ID}}" then
					local name = Steam.friends.GetFriendPersonaName(friend_id) or "Friend"
					local lid  = info.m_steamIDLobby
					if lid then
						result[#result + 1] = {friend_name = name, lobby_id = lid}
					end
				end
			end
		end
	end
	_friend_games = result
	return _friend_games
end

function SteamLobby.join(lobby_id, on_join)
	if not Steam.available then return end
	if on_join then _on_join = on_join end
	print("[SteamLobby] JoinLobby called, lobby_id=" .. tostring(lobby_id))
	Steam.matchmaking.JoinLobby(lobby_id, function(data, io_fail)
		if io_fail or not data or (data.m_EChatRoomEnterResponse or 0) ~= 1 then
			print("[SteamLobby] JoinLobby failed, response=" .. tostring(data and data.m_EChatRoomEnterResponse))
			return
		end
		_lobby_id = data.m_ulSteamIDLobby
		local host_steam_id = Steam.matchmaking.GetLobbyOwner(_lobby_id)
		print("[SteamLobby] JoinLobby OK, host SteamID=" .. Steam.id_to_string(host_steam_id))
		if host_steam_id and _on_join then
			_on_join(host_steam_id)
		else
			print("[SteamLobby] Warning: could not get lobby owner SteamID")
		end
	end)
end

function SteamLobby.set_player_count(n)
	if not Steam.available or not _lobby_id then return end
	Steam.matchmaking.SetLobbyData(_lobby_id, "players", tostring(n))
end

function SteamLobby.leave()
	if not Steam.available or not _lobby_id then return end
	Steam.matchmaking.LeaveLobby(_lobby_id)
	if Steam.friends then
		pcall(Steam.friends.SetRichPresence, "status", "")
		pcall(Steam.friends.SetRichPresence, "connect", "")
	end
	_lobby_id = nil
end

function SteamLobby.is_in_lobby()
	return _lobby_id ~= nil
end

function SteamLobby.set_overlay_join_handler(handler)
	SteamLobby._on_overlay_join = handler
end

function SteamLobby.update(dt)
	if not Steam.available then return end
	_refresh_timer = _refresh_timer + dt
	if _refresh_timer >= REFRESH_INTERVAL and not _list_pending then
		SteamLobby.refresh_list()
	end
end

return SteamLobby
