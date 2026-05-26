-- Lobby screen: pre-game waiting room.
-- Supports solo (host only), LAN multiplayer, and Steam P2P.
--
-- Lobby flow:
--   Host: create game → players join → everyone readies up → host starts
--   Client (LAN): enter host IP/port → connect → wait for host to start
--   Client (Steam): browse list or join via friend → wait for host to start
--
-- Network messages (all via src/net.lua):
--   LOBBY_JOIN   client→host  {player_name}
--   LOBBY_STATE  host→all     {slots}          periodic slot table broadcast
--   LOBBY_READY  client→host  {ready}          toggle ready state
--   LOBBY_CHAT   both         {player, text}   in-lobby chat
--   LOBBY_KICK   host→client  {}               kicked from lobby
--   LOBBY_START  host→all     {config}         game is starting

local Lobby = {}

local Net        = require("src.net")
local Steam      = require("src.steam")
local SteamLobby = require("src.steam_lobby")

-- ── Constants ─────────────────────────────────────────────────────────────────

local MAX_SLOTS    = 8
local DEFAULT_PORT = {{DEFAULT_PORT}}
local BEACON_PORT  = {{DEFAULT_PORT}} - 1
local BEACON_INTERVAL = 2.0

-- ── State ─────────────────────────────────────────────────────────────────────

local _mode         = "idle"   -- "host" | "join_screen" | "join_connecting" | "join_waiting"
local _is_started   = false
local _start_config = nil

local _game_name    = "{{GAME_NAME}}"
local _slot_count   = 2

-- Slots: {index, kind, player_name, is_host, is_ready, peer}
-- kind: "human" | "open" | "closed"
local _slots = {}

local _join_ip      = ""
local _join_port    = tostring(DEFAULT_PORT)
local _join_focused = "ip"
local _discovered   = {}
local _connect_error = nil
local _connect_timer = 0
local _local_player_name  = nil   -- set to Steam.my_name() on init
local _local_is_ready     = false

local _chat_messages = {}
local CHAT_MAX = 50
local _chat_input  = ""
local _chat_scroll = 0

local _beacon_timer = 0
local _udp_host     = nil
local _udp_recv     = nil
local _host_ip      = nil

local _join_tab  = "lan"   -- "lan" | "steam"
local _btn       = {}

local FONT_TITLE, FONT_BODY, FONT_SMALL

-- Callbacks injected by main.lua
local _on_start  = nil   -- function(config)  called when game begins
local _on_cancel = nil   -- function()        called when player leaves lobby

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function chat(player, text)
	_chat_messages[#_chat_messages + 1] = {player = player, text = text}
	if #_chat_messages > CHAT_MAX then table.remove(_chat_messages, 1) end
end

local function make_default_slots(n)
	local slots = {}
	for i = 1, n do
		slots[i] = {index = i, kind = "open", player_name = "", is_host = false, is_ready = false, peer = nil}
	end
	return slots
end

local function get_local_ip()
	local ok, socket = pcall(require, "socket")
	if not ok then return nil end
	local udp = socket.udp()
	if not udp then return nil end
	pcall(function()
		udp:setpeername("8.8.8.8", 53)
		_host_ip = udp:getsockname()
		udp:close()
	end)
	return _host_ip
end

local function broadcast_state()
	Net.broadcast({t = Net.MSG.LOBBY_STATE, slots = _slots})
end

local function send_start()
	local _ok_bv, _bv = pcall(require, "src.version")
	local host_build = (_ok_bv and type(_bv) == "string") and _bv or "dev"

	local cfg = {
		is_host    = false,
		slots      = _slots,
		game_name  = _game_name,
		host_build = host_build,
	}
	Net.broadcast({t = Net.MSG.LOBBY_START, config = cfg})

	cfg.is_host = true
	_start_config = cfg
	_is_started   = true
	if _on_start then _on_start(_start_config) end
end

-- ── Host init ─────────────────────────────────────────────────────────────────

local function init_host_lan()
	_local_player_name = Steam.my_name()
	_slots = make_default_slots(_slot_count)
	_slots[1].kind        = "human"
	_slots[1].player_name = _local_player_name
	_slots[1].is_host     = true
	_slots[1].is_ready    = true

	Net.init_host(DEFAULT_PORT, "host")
	Net.start_log()
	Net._status_cb = function(msg) chat("System", msg) end

	_host_ip = get_local_ip()

	-- UDP beacon for LAN discovery
	local ok_sock, socket = pcall(require, "socket")
	if ok_sock then
		_udp_host = socket.udp()
		if _udp_host then
			_udp_host:setsockname("*", BEACON_PORT)
			_udp_host:settimeout(0)
		end
	end

	chat("System", "Hosting on port " .. DEFAULT_PORT)
	if _host_ip then chat("System", "LAN IP: " .. _host_ip) end

	-- Steam lobby
	SteamLobby.create(_game_name, _slot_count, function()
		chat("System", "Steam lobby created.")
	end)
	SteamLobby.set_overlay_join_handler(function(lobby_id_str)
		-- handled on client side
	end)
end

-- ── Client join ───────────────────────────────────────────────────────────────

local function do_connect_lan(ip, port)
	_local_player_name = Steam.my_name()
	_mode = "join_connecting"
	_connect_error = nil
	_connect_timer = 0
	local ok = Net.init_client(ip, tonumber(port) or DEFAULT_PORT, "client")
	Net.start_log()
	Net._status_cb = function(msg) chat("System", msg) end
	if not ok then
		_connect_error = "Failed to connect to " .. ip .. ":" .. port
		_mode = "join_screen"
	else
		_mode = "join_waiting"
		chat("System", "Connecting to " .. ip .. ":" .. port .. "…")
	end
end

local function do_connect_steam(host_steam_id)
	_local_player_name = Steam.my_name()
	_mode = "join_connecting"
	_connect_error = nil
	Net.init_client(host_steam_id, DEFAULT_PORT, "client")
	Net.start_log()
	Net._status_cb = function(msg) chat("System", msg) end
	_mode = "join_waiting"
	chat("System", "Connecting via Steam P2P…")
end

-- ── LAN discovery ─────────────────────────────────────────────────────────────

local function update_beacon_recv(dt)
	local ok_sock, socket = pcall(require, "socket")
	if not ok_sock then return end
	if not _udp_recv then
		_udp_recv = socket.udp()
		if _udp_recv then
			_udp_recv:setsockname("*", BEACON_PORT)
			_udp_recv:settimeout(0)
		end
	end
	if not _udp_recv then return end
	local data, ip = _udp_recv:receivefrom()
	while data do
		local name, players, max_p, port_str = data:match("^LOVE_LOBBY:(.+):(%d+)/(%d+):(%d+)$")
		if name then
			local found = false
			for _, d in ipairs(_discovered) do
				if d.ip == ip and d.port == tonumber(port_str) then
					d.name = name; d.players = tonumber(players); d.max = tonumber(max_p); d.age = 0
					found = true; break
				end
			end
			if not found then
				_discovered[#_discovered + 1] = {name = name, ip = ip, port = tonumber(port_str), players = tonumber(players), max = tonumber(max_p), age = 0}
			end
		end
		data, ip = _udp_recv:receivefrom()
	end
	for _, d in ipairs(_discovered) do d.age = (d.age or 0) + dt end
	-- Remove stale entries (no beacon for > 8s)
	for i = #_discovered, 1, -1 do
		if _discovered[i].age > 8 then table.remove(_discovered, i) end
	end
end

local function send_beacon()
	if not _udp_host then return end
	local human_count = 0
	for _, s in ipairs(_slots) do
		if s.kind == "human" then human_count = human_count + 1 end
	end
	local msg = string.format("LOVE_LOBBY:%s:%d/%d:%d", _game_name, human_count, _slot_count, DEFAULT_PORT)
	pcall(function()
		_udp_host:sendto(msg, "255.255.255.255", BEACON_PORT)
	end)
end

-- ── Net event handling ────────────────────────────────────────────────────────

local function handle_event(ev)
	local t = ev.msg_type

	if t == "connect" then
		if Net.is_host() then
			chat("System", "Player connecting…")
		else
			chat("System", "Connected to host.")
			Net.send_to_server({t = Net.MSG.LOBBY_JOIN, player_name = _local_player_name})
		end

	elseif t == "disconnect" then
		if Net.is_host() then
			for _, s in ipairs(_slots) do
				if s.peer == ev.peer then
					chat("System", (s.player_name ~= "" and s.player_name or "Player") .. " disconnected.")
					s.kind = "open"; s.player_name = ""; s.peer = nil; s.is_ready = false
					break
				end
			end
			broadcast_state()
		else
			_connect_error = "Disconnected from host."
			_mode = "join_screen"
		end

	elseif t == Net.MSG.LOBBY_JOIN then
		if Net.is_host() then
			local name = (ev.data.player_name or "Player"):sub(1, 24)
			for _, s in ipairs(_slots) do
				if s.kind == "open" then
					s.kind = "human"; s.player_name = name; s.peer = ev.peer; s.is_ready = false
					chat("System", name .. " joined.")
					Net.register_peer(tostring(s.index), ev.peer)
					broadcast_state()
					return
				end
			end
			-- No open slot — kick
			Net.send(ev.peer, {t = Net.MSG.LOBBY_KICK})
		end

	elseif t == Net.MSG.LOBBY_STATE then
		_slots = ev.data.slots or _slots

	elseif t == Net.MSG.LOBBY_READY then
		if Net.is_host() then
			for _, s in ipairs(_slots) do
				if s.peer == ev.peer then
					s.is_ready = ev.data.ready
					chat("System", (s.player_name or "Player") .. (s.is_ready and " is ready." or " is not ready."))
					broadcast_state()
					return
				end
			end
		end

	elseif t == Net.MSG.LOBBY_CHAT then
		chat(ev.data.player or "?", ev.data.text or "")
		if Net.is_host() then
			-- Relay to all other clients
			Net.broadcast({t = Net.MSG.LOBBY_CHAT, player = ev.data.player, text = ev.data.text})
		end

	elseif t == Net.MSG.LOBBY_KICK then
		_connect_error = "Kicked from lobby."
		Lobby.leave()

	elseif t == Net.MSG.LOBBY_START then
		local cfg = ev.data.config or {}
		-- Version check
		local _ok_bv, _bv = pcall(require, "src.version")
		local my_build   = (_ok_bv and type(_bv) == "string") and _bv or "dev"
		local host_build = cfg.host_build or "unknown"
		if my_build ~= host_build then
			chat("System", "⚠ Version mismatch: you=" .. my_build .. " host=" .. host_build)
		end
		cfg.is_host    = false
		_start_config  = cfg
		_is_started    = true
		if _on_start then _on_start(_start_config) end
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function Lobby.init(opts)
	opts = opts or {}
	_on_start  = opts.on_start
	_on_cancel = opts.on_cancel

	_mode        = "idle"
	_is_started  = false
	_start_config = nil
	_slots       = {}
	_chat_messages = {}
	_chat_input  = ""
	_chat_scroll = 0
	_discovered  = {}
	_connect_error = nil
	_join_tab    = "lan"
	_btn         = {}

	if not FONT_TITLE then
		FONT_TITLE = love.graphics.newFont(22)
		FONT_BODY  = love.graphics.newFont(15)
		FONT_SMALL = love.graphics.newFont(12)
	end

	-- Wire Steam overlay join
	SteamLobby.set_overlay_join_handler(function(lobby_id_str)
		if _mode == "idle" or _mode == "join_screen" then
			SteamLobby.join(lobby_id_str, function(host_sid)
				do_connect_steam(host_sid)
			end)
		end
	end)
end

function Lobby.start_host()
	_mode = "host"
	init_host_lan()
end

function Lobby.start_join()
	_mode = "join_screen"
	_connect_error = nil
	SteamLobby.refresh_list()
end

function Lobby.leave()
	Net.close()
	SteamLobby.leave()
	if _udp_host then pcall(function() _udp_host:close() end); _udp_host = nil end
	if _udp_recv then pcall(function() _udp_recv:close() end); _udp_recv = nil end
	_mode = "idle"
	if _on_cancel then _on_cancel() end
end

function Lobby.is_active()   return _mode ~= "idle" end
function Lobby.is_started()  return _is_started end
function Lobby.get_config()  return _start_config end

function Lobby.update(dt)
	if _mode == "idle" or _is_started then return end

	Steam.run_callbacks()
	SteamLobby.update(dt)

	-- Net events
	local events = Net.poll()
	for _, ev in ipairs(events) do
		handle_event(ev)
		if _is_started then return end
	end

	-- Host: send beacon and periodic slot broadcast
	if _mode == "host" then
		_beacon_timer = _beacon_timer + dt
		if _beacon_timer >= BEACON_INTERVAL then
			_beacon_timer = 0
			send_beacon()
			broadcast_state()
		end
	end

	-- Client: LAN discovery
	if _mode == "join_screen" then
		update_beacon_recv(dt)
	end

	-- Connect timeout
	if _mode == "join_connecting" then
		_connect_timer = _connect_timer + dt
		if _connect_timer > 10 then
			_connect_error = "Connection timed out."
			_mode = "join_screen"
		end
	end
end

-- ── Draw ──────────────────────────────────────────────────────────────────────

local function draw_chat(x, y, w, h)
	love.graphics.setColor(0.05, 0.07, 0.14, 0.9)
	love.graphics.rectangle("fill", x, y, w, h, 6, 6)
	love.graphics.setColor(0.25, 0.35, 0.55, 0.7)
	love.graphics.rectangle("line", x, y, w, h, 6, 6)

	love.graphics.setFont(FONT_SMALL)
	local lh = FONT_SMALL:getHeight() + 2
	local msg_h = h - 30
	local max_lines = math.floor(msg_h / lh)
	local start = math.max(1, #_chat_messages - max_lines - _chat_scroll + 1)
	local cy = y + 6
	for i = start, math.min(#_chat_messages, start + max_lines - 1) do
		local m = _chat_messages[i]
		love.graphics.setColor(0.7, 0.8, 1.0, 0.9)
		love.graphics.print((m.player or "") .. ":", x + 8, cy)
		love.graphics.setColor(0.9, 0.92, 1.0, 0.9)
		love.graphics.printf(m.text or "", x + 80, cy, w - 90, "left")
		cy = cy + lh
	end

	-- Input bar
	love.graphics.setColor(0.08, 0.1, 0.2, 1.0)
	love.graphics.rectangle("fill", x + 4, y + h - 26, w - 8, 22, 4, 4)
	love.graphics.setColor(0.4, 0.5, 0.8, 0.6)
	love.graphics.rectangle("line", x + 4, y + h - 26, w - 8, 22, 4, 4)
	love.graphics.setColor(0.9, 0.92, 1.0, 0.9)
	love.graphics.print(_chat_input .. "|", x + 10, y + h - 23)
end

local function draw_slot(s, x, y, w, h)
	local bg = s.kind == "human" and {0.08, 0.14, 0.26} or {0.05, 0.07, 0.14}
	love.graphics.setColor(bg[1], bg[2], bg[3], 0.9)
	love.graphics.rectangle("fill", x, y, w, h, 5, 5)
	love.graphics.setColor(0.25, 0.35, 0.55, 0.6)
	love.graphics.rectangle("line", x, y, w, h, 5, 5)

	love.graphics.setFont(FONT_BODY)
	if s.kind == "human" then
		love.graphics.setColor(0.9, 0.95, 1.0, 1.0)
		local label = s.player_name ~= "" and s.player_name or "…"
		if s.is_host then label = label .. "  [HOST]" end
		love.graphics.print(label, x + 10, y + h/2 - 8)
		if s.is_ready then
			love.graphics.setColor(0.3, 0.9, 0.5, 1.0)
			love.graphics.print("READY", x + w - 70, y + h/2 - 8)
		end
	elseif s.kind == "open" then
		love.graphics.setColor(0.5, 0.6, 0.8, 0.6)
		love.graphics.print("Open slot", x + 10, y + h/2 - 8)
	else
		love.graphics.setColor(0.3, 0.3, 0.4, 0.6)
		love.graphics.print("Closed", x + 10, y + h/2 - 8)
	end
end

function Lobby.draw()
	if _mode == "idle" or _is_started then return end
	local W, H = love.graphics.getDimensions()

	love.graphics.setColor(0.03, 0.05, 0.1, 1.0)
	love.graphics.rectangle("fill", 0, 0, W, H)

	_btn = {}

	if _mode == "host" then
		-- ── Host view ────────────────────────────────────────────────────────
		love.graphics.setFont(FONT_TITLE)
		love.graphics.setColor(0.8, 0.9, 1.0, 1.0)
		love.graphics.print("Lobby — " .. _game_name, 30, 20)

		love.graphics.setFont(FONT_SMALL)
		love.graphics.setColor(0.5, 0.65, 0.85, 0.8)
		if _host_ip then
			love.graphics.print("LAN: " .. _host_ip .. ":" .. DEFAULT_PORT, 30, 56)
		end

		-- Slots
		local sx, sy, sw, sh = 30, 90, W/2 - 50, 44
		for i, s in ipairs(_slots) do
			draw_slot(s, sx, sy + (i-1)*(sh+6), sw, sh)
		end

		-- Chat
		local cx = W/2 + 10
		draw_chat(cx, 90, W - cx - 30, H - 160)

		-- Start button
		local all_ready = true
		for _, s in ipairs(_slots) do
			if s.kind == "human" and not s.is_ready then all_ready = false; break end
		end
		local human_count = 0
		for _, s in ipairs(_slots) do if s.kind == "human" then human_count = human_count + 1 end end

		local bx, by, bw, bh = W - 200, H - 60, 170, 40
		local can_start = all_ready and human_count >= 1
		love.graphics.setColor(can_start and 0.2 or 0.1, can_start and 0.7 or 0.3, can_start and 0.3 or 0.15, 1.0)
		love.graphics.rectangle("fill", bx, by, bw, bh, 6, 6)
		love.graphics.setFont(FONT_BODY)
		love.graphics.setColor(1, 1, 1, can_start and 1.0 or 0.4)
		love.graphics.printf("Start Game", bx, by + 10, bw, "center")
		if can_start then _btn.start = {x=bx, y=by, w=bw, h=bh} end

		-- Cancel
		love.graphics.setColor(0.6, 0.3, 0.3, 0.8)
		love.graphics.rectangle("fill", 30, H - 60, 100, 40, 6, 6)
		love.graphics.setColor(1, 1, 1, 1)
		love.graphics.printf("Cancel", 30, H - 50, 100, "center")
		_btn.cancel = {x=30, y=H-60, w=100, h=40}

	elseif _mode == "join_screen" then
		-- ── Join view ────────────────────────────────────────────────────────
		love.graphics.setFont(FONT_TITLE)
		love.graphics.setColor(0.8, 0.9, 1.0, 1.0)
		love.graphics.print("Join a Game", 30, 20)

		-- Tabs
		local tabs = {"lan", "steam"}
		for i, tab in ipairs(tabs) do
			local tx = 30 + (i-1)*120
			local active = _join_tab == tab
			love.graphics.setColor(active and 0.15 or 0.08, active and 0.25 or 0.12, active and 0.45 or 0.22, 1.0)
			love.graphics.rectangle("fill", tx, 60, 110, 32, 5, 5)
			love.graphics.setFont(FONT_BODY)
			love.graphics.setColor(1, 1, 1, active and 1.0 or 0.5)
			love.graphics.printf(tab == "lan" and "LAN" or "Steam", tx, 68, 110, "center")
			_btn["tab_" .. tab] = {x=tx, y=60, w=110, h=32}
		end

		if _join_tab == "lan" then
			-- IP / port inputs
			love.graphics.setFont(FONT_SMALL)
			love.graphics.setColor(0.6, 0.7, 0.9, 0.8)
			love.graphics.print("Host IP:", 30, 108)
			love.graphics.setColor(_join_focused == "ip" and 0.3 or 0.1, 0.15, 0.35, 1.0)
			love.graphics.rectangle("fill", 30, 126, 260, 30, 4, 4)
			love.graphics.setColor(0.4, 0.5, 0.8, 0.7)
			love.graphics.rectangle("line", 30, 126, 260, 30, 4, 4)
			love.graphics.setColor(0.9, 0.95, 1.0, 1.0)
			love.graphics.print((_join_focused == "ip" and _join_ip .. "|" or _join_ip), 38, 133)
			_btn.ip_field = {x=30, y=126, w=260, h=30}

			love.graphics.setColor(0.6, 0.7, 0.9, 0.8)
			love.graphics.print("Port:", 30, 166)
			love.graphics.setColor(_join_focused == "port" and 0.3 or 0.1, 0.15, 0.35, 1.0)
			love.graphics.rectangle("fill", 30, 184, 100, 30, 4, 4)
			love.graphics.setColor(0.4, 0.5, 0.8, 0.7)
			love.graphics.rectangle("line", 30, 184, 100, 30, 4, 4)
			love.graphics.setColor(0.9, 0.95, 1.0, 1.0)
			love.graphics.print((_join_focused == "port" and _join_port .. "|" or _join_port), 38, 191)
			_btn.port_field = {x=30, y=184, w=100, h=30}

			-- Discovered servers
			love.graphics.setFont(FONT_SMALL)
			love.graphics.setColor(0.5, 0.65, 0.85, 0.7)
			love.graphics.print("Discovered on LAN:", 30, 228)
			if #_discovered == 0 then
				love.graphics.setColor(0.4, 0.5, 0.65, 0.6)
				love.graphics.print("(none found yet)", 30, 248)
			else
				for i, d in ipairs(_discovered) do
					local dy = 248 + (i-1)*30
					love.graphics.setColor(0.08, 0.14, 0.26, 0.9)
					love.graphics.rectangle("fill", 30, dy, 300, 26, 4, 4)
					love.graphics.setColor(0.8, 0.9, 1.0, 0.9)
					love.graphics.print(string.format("%s  %s  %d/%d", d.name, d.ip, d.players, d.max), 38, dy + 5)
					_btn["disc_" .. i] = {x=30, y=dy, w=300, h=26, ip=d.ip, port=d.port}
				end
			end

		else
			-- Steam lobby list
			local list = SteamLobby.get_list()
			love.graphics.setFont(FONT_SMALL)
			if not Steam.available then
				love.graphics.setColor(1.0, 0.7, 0.3, 0.9)
				love.graphics.print("Steam not available.", 30, 108)
			elseif #list == 0 then
				love.graphics.setColor(0.4, 0.5, 0.65, 0.7)
				love.graphics.print("No lobbies found. Refreshing…", 30, 108)
			else
				for i, lobby in ipairs(list) do
					local ly = 100 + (i-1)*40
					love.graphics.setColor(0.08, 0.14, 0.26, 0.9)
					love.graphics.rectangle("fill", 30, ly, 400, 34, 5, 5)
					love.graphics.setColor(0.8, 0.9, 1.0, 0.9)
					love.graphics.print(string.format("%s   %d/%d players", lobby.name, lobby.players, lobby.max), 40, ly + 9)
					_btn["steam_lobby_" .. i] = {x=30, y=ly, w=400, h=34, lobby_id=lobby.lobby_id}
				end
			end
		end

		-- Error message
		if _connect_error then
			love.graphics.setColor(1.0, 0.4, 0.3, 0.9)
			love.graphics.setFont(FONT_SMALL)
			love.graphics.print(_connect_error, 30, H - 100)
		end

		-- Connect button (LAN)
		if _join_tab == "lan" then
			local bx, by, bw, bh = W - 200, H - 60, 170, 40
			love.graphics.setColor(0.15, 0.35, 0.7, 1.0)
			love.graphics.rectangle("fill", bx, by, bw, bh, 6, 6)
			love.graphics.setFont(FONT_BODY)
			love.graphics.setColor(1, 1, 1, 1)
			love.graphics.printf("Connect", bx, by + 10, bw, "center")
			_btn.connect = {x=bx, y=by, w=bw, h=bh}
		end

		love.graphics.setColor(0.6, 0.3, 0.3, 0.8)
		love.graphics.rectangle("fill", 30, H - 60, 100, 40, 6, 6)
		love.graphics.setColor(1, 1, 1, 1)
		love.graphics.setFont(FONT_BODY)
		love.graphics.printf("Back", 30, H - 50, 100, "center")
		_btn.cancel = {x=30, y=H-60, w=100, h=40}

	elseif _mode == "join_waiting" or _mode == "join_connecting" then
		love.graphics.setFont(FONT_BODY)
		love.graphics.setColor(0.7, 0.85, 1.0, 0.9)
		love.graphics.printf(_mode == "join_connecting" and "Connecting…" or "Waiting for host to start…",
			0, H/2 - 20, W, "center")

		draw_chat(W/2 - 200, H/2 + 30, 400, 200)

		love.graphics.setColor(0.6, 0.3, 0.3, 0.8)
		love.graphics.rectangle("fill", W/2 - 60, H - 60, 120, 40, 6, 6)
		love.graphics.setColor(1, 1, 1, 1)
		love.graphics.printf("Leave", W/2 - 60, H - 50, 120, "center")
		_btn.cancel = {x=W/2-60, y=H-60, w=120, h=40}

		-- Client ready toggle
		if _mode == "join_waiting" then
			local bx, by, bw, bh = W/2 + 70, H - 60, 130, 40
			love.graphics.setColor(_local_is_ready and 0.2 or 0.1, _local_is_ready and 0.7 or 0.3, _local_is_ready and 0.3 or 0.15, 1.0)
			love.graphics.rectangle("fill", bx, by, bw, bh, 6, 6)
			love.graphics.setColor(1, 1, 1, 1)
			love.graphics.printf(_local_is_ready and "Ready ✓" or "Ready?", bx, by + 10, bw, "center")
			_btn.ready = {x=bx, y=by, w=bw, h=bh}
		end
	end
end

-- ── Input ─────────────────────────────────────────────────────────────────────

local function hit(btn, x, y)
	return x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h
end

function Lobby.mousepressed(x, y, button)
	if button ~= 1 then return end

	if _btn.start and hit(_btn.start, x, y) then
		send_start()

	elseif _btn.cancel and hit(_btn.cancel, x, y) then
		Lobby.leave()

	elseif _btn.connect and hit(_btn.connect, x, y) then
		if _join_ip ~= "" then do_connect_lan(_join_ip, _join_port) end

	elseif _btn.ready and hit(_btn.ready, x, y) then
		_local_is_ready = not _local_is_ready
		Net.send_to_server({t = Net.MSG.LOBBY_READY, ready = _local_is_ready})

	elseif _btn.ip_field and hit(_btn.ip_field, x, y) then
		_join_focused = "ip"
	elseif _btn.port_field and hit(_btn.port_field, x, y) then
		_join_focused = "port"

	elseif _btn.tab_lan and hit(_btn.tab_lan, x, y) then
		_join_tab = "lan"
	elseif _btn.tab_steam and hit(_btn.tab_steam, x, y) then
		_join_tab = "steam"
		SteamLobby.refresh_list()
	end

	-- Discovered LAN servers
	for k, b in pairs(_btn) do
		if k:sub(1, 5) == "disc_" and hit(b, x, y) then
			_join_ip = b.ip; _join_port = tostring(b.port)
			do_connect_lan(b.ip, b.port)
			return
		end
		if k:sub(1, 12) == "steam_lobby_" and hit(b, x, y) then
			SteamLobby.join(b.lobby_id, function(host_sid)
				do_connect_steam(host_sid)
			end)
			return
		end
	end
end

function Lobby.keypressed(key)
	if key == "return" or key == "kpenter" then
		if _chat_input ~= "" then
			local text = _chat_input:sub(1, 140)
			_chat_input = ""
			local player = Steam.my_name()
			chat(player, text)
			if Net.is_host() then
				Net.broadcast({t = Net.MSG.LOBBY_CHAT, player = player, text = text})
			else
				Net.send_to_server({t = Net.MSG.LOBBY_CHAT, player = player, text = text})
			end
		elseif _mode == "join_screen" and _join_tab == "lan" and _join_ip ~= "" then
			do_connect_lan(_join_ip, _join_port)
		end
	elseif key == "tab" then
		_join_focused = _join_focused == "ip" and "port" or "ip"
	elseif key == "backspace" then
		if _chat_input ~= "" then
			_chat_input = _chat_input:sub(1, -2)
		elseif _join_focused == "ip" then
			_join_ip = _join_ip:sub(1, -2)
		elseif _join_focused == "port" then
			_join_port = _join_port:sub(1, -2)
		end
	end
end

function Lobby.textinput(text)
	if _join_focused == "ip" and _mode == "join_screen" then
		_join_ip = _join_ip .. text
	elseif _join_focused == "port" and _mode == "join_screen" then
		if text:match("%d") then _join_port = _join_port .. text end
	else
		if #_chat_input < 140 then _chat_input = _chat_input .. text end
	end
end

function Lobby.wheelmoved(_, dy)
	_chat_scroll = math.max(0, _chat_scroll - dy)
end

return Lobby
