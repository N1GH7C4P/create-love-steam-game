-- Multiplayer networking: ISteamNetworkingSockets (P2P relay) when Steam is available,
-- enet (direct UDP) as fallback for LAN / non-Steam play.
-- API surface is identical regardless of transport.

local Net = {}

local Steam = require("src.steam")

local ok, enet = pcall(require, "enet")
if not ok then enet = nil end

-- Message type tokens (short strings to keep packets small).
-- Add your own game-phase messages here alongside the framework ones.
Net.MSG = {
	-- Lobby phase (framework — do not remove)
	LOBBY_JOIN    = "lj",
	LOBBY_STATE   = "ls",
	LOBBY_READY   = "lr",
	LOBBY_KICK    = "lk",
	LOBBY_START   = "lst",
	LOBBY_CHAT    = "lch",
	-- Game phase (framework)
	GAME_READY    = "gr",    -- client→host: "I'm in the game loop, send me FULL_STATE"
	FULL_STATE    = "fs",    -- host→client: authoritative full game state
	SYNC_CHECK    = "syn",   -- host→clients: compact periodic snapshot
	SYNC_REQUEST  = "syr",   -- client→host: requesting full resync
	GAME_TICK     = "dt",    -- host→all: simulation tick
	PLAYER_JOIN   = "pj",
	PLAYER_LEAVE  = "pl",
	-- Placeholder game message — replace with your own
	SCORE_UPDATE  = "su",    -- client→host: player scored a point
}

-- ── Serialization ─────────────────────────────────────────────────────────────

local function ser(val, depth)
	depth = depth or 0
	if depth > 12 then return "nil" end
	local t = type(val)
	if t == "string"  then return string.format("%q", val)
	elseif t == "number"  then return tostring(val)
	elseif t == "boolean" then return tostring(val)
	elseif t == "nil"     then return "nil"
	elseif t == "table" then
		local parts = {}
		for i = 1, #val do parts[#parts+1] = ser(val[i], depth+1) end
		for k, v in pairs(val) do
			if type(k) ~= "number" or k < 1 or k > #val then
				local ks = type(k) == "string"
					and string.format("[%q]", k)
					or ("["..tostring(k).."]")
				parts[#parts+1] = ks .. "=" .. ser(v, depth+1)
			end
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "nil"
end

local function deser(s)
	local fn = load("return " .. s)
	if not fn then return nil end
	local ok2, val = pcall(fn)
	return ok2 and val or nil
end

-- ── State ─────────────────────────────────────────────────────────────────────

-- Optional callback set by lobby.lua: Net._status_cb = function(msg) ... end
-- Receives human-readable status strings for display in the lobby chat box.
Net._status_cb = nil

local function net_status(msg)
	print("[Net] " .. msg)
	if Net._status_cb then pcall(Net._status_cb, msg) end
end

local _is_host          = false
local _local_company_id = nil
local _peers            = {}   -- {company_id → peer}

-- P2P (ISteamNetworkingSockets)
local _ns               = Steam.netsockets
local _p2p_mode         = false
local _listen_socket    = nil
local _server_conn      = nil
local _p2p_conns        = {}
local _p2p_events       = {}

local ST_CONNECTING = 1
local ST_CONNECTED  = 3
local ST_CLOSED     = 4
local ST_PROBLEM    = 5
local SEND_RELIABLE = 8

-- enet
local _enet_host        = nil
local _enet_server_peer = nil
local _enet_available   = (enet ~= nil)

-- ── P2P connection-status callback ────────────────────────────────────────────

local STATE_NAMES = {[0]="None",[1]="Connecting",[2]="FindingRoute",[3]="Connected",[4]="ClosedByPeer",[5]="Problem"}

local function setup_p2p_callback()
	if not _ns then return end
	local function on_status_changed(data)
		local hConn    = data.m_hConn
		local newState = data.m_info and data.m_info.m_eState or 0
		local oldState = data.m_eOldState or 0
		net_status(string.format("P2P conn %d: %s → %s",
			hConn,
			STATE_NAMES[oldState] or oldState,
			STATE_NAMES[newState] or newState))

		if _is_host then
			if oldState == 0 and newState == ST_CONNECTING then
				local ok2, err = pcall(_ns.AcceptConnection, hConn)
				if ok2 then
					_p2p_conns[hConn] = true
					net_status("P2P: accepted connection " .. hConn)
				else
					net_status("P2P: AcceptConnection failed: " .. tostring(err))
				end
			elseif newState == ST_CONNECTED and _p2p_conns[hConn] then
				net_status("P2P: client " .. hConn .. " fully connected")
				_p2p_events[#_p2p_events+1] = {kind="connect", hConn=hConn}
			elseif (newState == ST_CLOSED or newState == ST_PROBLEM) and _p2p_conns[hConn] then
				_p2p_conns[hConn] = nil
				_p2p_events[#_p2p_events+1] = {kind="disconnect", hConn=hConn}
				pcall(_ns.CloseConnection, hConn, 0, "closed", false)
			end
		else
			if newState == ST_CONNECTED then
				net_status("P2P: connected to host (conn " .. hConn .. ")")
				_p2p_events[#_p2p_events+1] = {kind="connect", hConn=hConn}
			elseif newState == ST_CLOSED or newState == ST_PROBLEM then
				net_status("P2P: connection to host lost/closed")
				_p2p_events[#_p2p_events+1] = {kind="disconnect", hConn=hConn}
			end
		end
	end
	local ok_lib, luasteam_lib = pcall(require, "luasteam")
	if ok_lib and luasteam_lib then
		local nu = luasteam_lib.NetworkingUtils
		if nu and nu.SetGlobalCallback_SteamNetConnectionStatusChanged then
			pcall(nu.SetGlobalCallback_SteamNetConnectionStatusChanged, on_status_changed)
			net_status("P2P callback registered via SetGlobalCallback")
		end
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function Net.is_available()
	return _enet_available or (_ns ~= nil)
end

function Net.is_host()              return _is_host            end
function Net.get_local_company_id() return _local_company_id   end

function Net.init_host(port, company_id)
	-- Lobby→game transition: P2P socket already open
	if _p2p_mode and _listen_socket and _is_host then
		_local_company_id = company_id
		_peers            = {}
		net_status("init_host: reusing P2P listen socket, cid=" .. tostring(company_id))
		return true
	end
	net_status("init_host: Steam.netsockets=" .. tostring(_ns ~= nil))
	if _ns then
		local ok_lib, luasteam_lib = pcall(require, "luasteam")
		if ok_lib and luasteam_lib and luasteam_lib.NetworkingUtils then
			pcall(luasteam_lib.NetworkingUtils.InitRelayNetworkAccess)
		end
		setup_p2p_callback()
		local ls, err
		ok, ls = pcall(_ns.CreateListenSocketP2P, 0, 0, {})
		if not ok then err = ls; ls = nil end
		if ls then
			_listen_socket    = ls
			_p2p_mode         = true
			_is_host          = true
			_local_company_id = company_id
			_peers            = {}
			_p2p_conns        = {}
			net_status("P2P listen socket created (handle=" .. tostring(ls) .. ")")
			return true
		end
		net_status("CreateListenSocketP2P failed (" .. tostring(err) .. "), falling back to enet")
	end
	if not _enet_available then
		net_status("No transport available (no Steam P2P, no enet)")
		return false
	end
	port = port or {{DEFAULT_PORT}}
	_enet_host = enet.host_create("*:" .. port, 8, 2)
	if not _enet_host then return false end
	_p2p_mode         = false
	_is_host          = true
	_local_company_id = company_id
	_peers            = {}
	net_status("enet host created on port " .. port)
	return true
end

function Net.init_client(target, port, company_id)
	net_status("init_client: target type=" .. type(target) .. " Steam.netsockets=" .. tostring(_ns ~= nil))
	if type(target) ~= "string" and _ns then
		local ok_lib0, luasteam_lib0 = pcall(require, "luasteam")
		if ok_lib0 and luasteam_lib0 and luasteam_lib0.NetworkingUtils then
			pcall(luasteam_lib0.NetworkingUtils.InitRelayNetworkAccess)
		end
		setup_p2p_callback()
		local steam_id_str = Steam.id_to_string(target)
		net_status("host SteamID=" .. steam_id_str)
		local identity = nil
		local ok_lib, luasteam_lib = pcall(require, "luasteam")
		if ok_lib and luasteam_lib then
			local nu = luasteam_lib.NetworkingUtils
			if nu and nu.SteamNetworkingIdentity_ParseString then
				local ok_id, success, id = pcall(nu.SteamNetworkingIdentity_ParseString, "steamid:" .. steam_id_str)
				if ok_id and success and id then
					identity = id
					net_status("identity via SteamNetworkingIdentity_ParseString")
				end
			end
		end
		if not identity then
			net_status("ConnectP2P aborted: no identity constructor found")
			return false
		end
		local hConn, err
		ok, hConn = pcall(_ns.ConnectP2P, identity, 0, 0, {})
		if not ok then err = hConn; hConn = nil end
		if hConn then
			_server_conn      = hConn
			_p2p_mode         = true
			_is_host          = false
			_local_company_id = company_id
			net_status("P2P ConnectP2P initiated (hConn=" .. tostring(hConn) .. ")")
			return true
		end
		net_status("ConnectP2P failed: " .. tostring(err))
		return false
	end
	if not _enet_available then return false end
	port = port or {{DEFAULT_PORT}}
	_enet_host = enet.host_create()
	if not _enet_host then return false end
	_enet_server_peer = _enet_host:connect(target .. ":" .. port, 2)
	_p2p_mode         = false
	_is_host          = false
	_local_company_id = company_id
	net_status("enet connect → " .. target .. ":" .. port)
	return true
end

function Net.reuse_p2p_as_client(company_id)
	if _p2p_mode and not _is_host and _server_conn then
		_local_company_id = company_id
		_peers            = {}
		net_status("reuse_p2p_as_client: updated company_id=" .. tostring(company_id))
		return true
	end
	return false
end

function Net.get_p2p_conns()   return _p2p_conns end
function Net.register_peer(company_id, peer) _peers[company_id] = peer end
function Net.get_peer(company_id)            return _peers[company_id] end
function Net.remove_peer(company_id)         _peers[company_id] = nil  end

function Net.get_company_for_peer(peer)
	for cid, p in pairs(_peers) do
		if p == peer then return cid end
	end
	return nil
end

function Net.send(peer, msg_table)
	if not peer then return end
	if _p2p_mode then
		local data = ser(msg_table)
		pcall(_ns.SendMessageToConnection, peer, data, #data, SEND_RELIABLE)
	else
		if _enet_host then
			pcall(function() peer:send(ser(msg_table), 0, "reliable") end)
		end
	end
end

function Net.broadcast(msg_table)
	if not _is_host then return end
	if _p2p_mode then
		local data = ser(msg_table)
		for hConn in pairs(_p2p_conns) do
			pcall(_ns.SendMessageToConnection, hConn, data, #data, SEND_RELIABLE)
		end
	else
		if _enet_host then
			pcall(function() _enet_host:broadcast(ser(msg_table), 0, "reliable") end)
		end
	end
end

function Net.send_to_server(msg_table)
	if _is_host then return end
	if _p2p_mode then
		if _server_conn then
			local data = ser(msg_table)
			pcall(_ns.SendMessageToConnection, _server_conn, data, #data, SEND_RELIABLE)
		end
	else
		if _enet_server_peer then
			pcall(function() _enet_server_peer:send(ser(msg_table), 0, "reliable") end)
		end
	end
end

local function poll_p2p()
	pcall(_ns.RunCallbacks)
	local events = {}
	local pending = _p2p_events
	_p2p_events = {}
	for _, ev in ipairs(pending) do
		events[#events+1] = {msg_type=ev.kind, data=nil, peer=ev.hConn}
	end
	local conns = {}
	if _is_host then
		for hConn in pairs(_p2p_conns) do conns[#conns+1] = hConn end
	end
	-- Always poll server_conn — handles the case where a client temporarily enters
	-- host mode and still needs to receive FULL_STATE from the actual host.
	if _server_conn then
		conns[#conns+1] = _server_conn
	end
	for _, hConn in ipairs(conns) do
		local ok2, nmsg, msgs = pcall(_ns.ReceiveMessagesOnConnection, hConn, 64)
		if ok2 and nmsg and nmsg > 0 and type(msgs) == "table" then
			for _, item in ipairs(msgs) do
				local data_str
				if type(item) == "string" then
					data_str = item
				elseif type(item) == "userdata" then
					data_str = item.m_pData
					pcall(function() if item.Release then item:Release() end end)
				end
				if type(data_str) == "string" then
					local msg = deser(data_str)
					if msg and msg.t then
						events[#events+1] = {msg_type=msg.t, data=msg, peer=hConn}
					end
				end
			end
		end
	end
	return events
end

local function poll_enet()
	if not _enet_host then return {} end
	local events = {}
	local ok2, ev = pcall(function() return _enet_host:service(0) end)
	if not ok2 then return events end
	while ev do
		if ev.type == "receive" then
			local msg = deser(ev.data)
			if msg and msg.t then
				events[#events+1] = {msg_type=msg.t, data=msg, peer=ev.peer}
			end
		elseif ev.type == "connect" then
			events[#events+1] = {msg_type="connect", peer=ev.peer}
		elseif ev.type == "disconnect" then
			events[#events+1] = {msg_type="disconnect", peer=ev.peer}
		end
		local ok3
		ok3, ev = pcall(function() return _enet_host:service(0) end)
		if not ok3 then break end
	end
	return events
end

function Net.poll()
	if _p2p_mode then return poll_p2p() else return poll_enet() end
end

function Net.close()
	if _p2p_mode and _ns then
		for hConn in pairs(_p2p_conns) do
			pcall(_ns.CloseConnection, hConn, 0, "shutdown", false)
		end
		if _server_conn then
			pcall(_ns.CloseConnection, _server_conn, 0, "shutdown", false)
		end
		if _listen_socket then
			pcall(_ns.CloseListenSocket, _listen_socket)
		end
	else
		if _enet_host then pcall(function() _enet_host:flush() end) end
	end
	_enet_host        = nil
	_enet_server_peer = nil
	_listen_socket    = nil
	_server_conn      = nil
	_p2p_conns        = {}
	_p2p_events       = {}
	_p2p_mode         = false
	_is_host          = false
	_peers            = {}
	Net.flush_log()
end

-- ── Debug logging overlay ─────────────────────────────────────────────────────

local _log_lines    = {}
local _log_all      = {}
local _log_t0       = nil
local _log_filename = nil
local _net_debug_visible = false
local _last_flush   = 0

local MAX_OVERLAY_LINES = 18
local FLUSH_INTERVAL    = 10

local function net_log(direction, msg_type, peer_str, extra)
	local t   = love.timer and love.timer.getTime() or 0
	_log_t0   = _log_t0 or t
	local rel = string.format("%.2f", t - _log_t0)
	local role = _is_host and "HOST" or "CLIENT"
	local line = string.format("[T+%7ss] [%s] %s %-12s %s%s",
		rel, role, direction, msg_type or "?",
		peer_str or "",
		extra and ("  "..extra) or "")
	table.insert(_log_lines, line)
	if #_log_lines > MAX_OVERLAY_LINES then table.remove(_log_lines, 1) end
	table.insert(_log_all, line)
end

local function peer_str_fmt(peer)
	if not peer then return "" end
	if type(peer) == "number" then return "conn:"..peer end
	local ok2, s = pcall(function() return tostring(peer:connect_id()) end)
	return ok2 and s or "peer"
end

local _orig_send           = Net.send
local _orig_broadcast      = Net.broadcast
local _orig_send_to_server = Net.send_to_server
local _orig_poll           = Net.poll

function Net.send(peer, msg_table)
	if _log_filename then net_log("SEND→", msg_table and msg_table.t, peer_str_fmt(peer)) end
	_orig_send(peer, msg_table)
end

function Net.broadcast(msg_table)
	if _log_filename then net_log("BCAST", msg_table and msg_table.t, "all") end
	_orig_broadcast(msg_table)
end

function Net.send_to_server(msg_table)
	if _log_filename then net_log("SEND→", msg_table and msg_table.t, "server") end
	_orig_send_to_server(msg_table)
end

function Net.poll()
	local events = _orig_poll()
	if _log_filename then
		for _, ev in ipairs(events) do
			if ev.msg_type == "connect" then
				net_log("CONN ", "connect", peer_str_fmt(ev.peer))
			elseif ev.msg_type == "disconnect" then
				net_log("DISC ", "disconnect", peer_str_fmt(ev.peer))
			else
				net_log("←RECV", ev.msg_type, peer_str_fmt(ev.peer))
			end
		end
		local now = love.timer and love.timer.getTime() or 0
		if now - _last_flush >= FLUSH_INTERVAL then
			Net.flush_log()
			_last_flush = now
		end
	end
	return events
end

function Net.start_log()
	local role = _is_host and "host" or "client"
	local ts   = os.date("%Y%m%d_%H%M%S")
	_log_filename = string.format("net_%s_%s_%s.log", ts, role, tostring(os.time()):sub(-4))
	_log_t0    = nil
	_log_lines = {}
	_log_all   = {}
	_last_flush = love.timer and love.timer.getTime() or 0
	net_log("----", "session_start", "", string.format("role=%s transport=%s", role, _p2p_mode and "p2p" or "enet"))
end

function Net.flush_log()
	if not _log_filename or #_log_all == 0 then return end
	pcall(function()
		love.filesystem.write(_log_filename, table.concat(_log_all, "\n") .. "\n")
	end)
end

function Net.toggle_debug()  _net_debug_visible = not _net_debug_visible end
function Net.debug_visible() return _net_debug_visible end

function Net.draw_debug(W, H)
	if not _net_debug_visible then return end
	local x, y, w = 8, 8, math.min(660, W - 16)
	local lh      = 14
	local lines   = _log_lines
	local ph      = lh * (MAX_OVERLAY_LINES + 3) + 8
	love.graphics.setColor(0, 0, 0, 0.78)
	love.graphics.rectangle("fill", x, y, w, ph, 4, 4)
	love.graphics.setColor(0.3, 0.7, 1.0, 0.6)
	love.graphics.rectangle("line", x, y, w, ph, 4, 4)
	local role      = _is_host and "HOST" or "CLIENT"
	local transport = _p2p_mode and "P2P" or "enet"
	local conn      = _log_filename and "logging → " .. _log_filename or "not logging"
	love.graphics.setColor(0.4, 0.9, 1.0, 1.0)
	local fnt = love.graphics.newFont(11)
	love.graphics.setFont(fnt)
	love.graphics.print(string.format("NET DEBUG [%s/%s]  %s  (F2 to hide)", role, transport, conn), x+6, y+4)
	love.graphics.setColor(0.6, 0.6, 0.6, 0.5)
	love.graphics.line(x+4, y+lh+4, x+w-4, y+lh+4)
	for i, line in ipairs(lines) do
		local col = {0.85, 0.85, 0.85, 0.9}
		if line:find("SEND") or line:find("BCAST") then col = {0.5, 1.0, 0.6, 0.9}
		elseif line:find("←RECV")                  then col = {0.5, 0.8, 1.0, 0.9}
		elseif line:find("CONN")                   then col = {1.0, 1.0, 0.4, 1.0}
		elseif line:find("DISC")                   then col = {1.0, 0.4, 0.4, 1.0}
		end
		love.graphics.setColor(col)
		love.graphics.print(line, x+6, y + lh + 6 + (i-1)*lh)
	end
	love.graphics.setColor(1,1,1,1)
end

return Net
