-- Placeholder multiplayer game: a synchronized score counter.
-- Every player has a score; click the big button to increment yours.
-- The host owns all state; clients send SCORE_UPDATE and receive FULL_STATE / SYNC_CHECK.
--
-- This is the starting point for your actual game. Replace the score mechanic with
-- whatever your game does, keeping the GAME_READY → FULL_STATE → SYNC_CHECK pattern.
--
-- Message flow:
--   client → host   GAME_READY     "I'm in the game loop, send me the full state"
--   host   → client FULL_STATE     full authoritative state (on GAME_READY + every 5s)
--   client → host   SCORE_UPDATE   player clicked the button
--   host   → all    SYNC_CHECK     compact snapshot every 3 sim-ticks
--   host   → all    GAME_TICK      sim tick (every real second)

local GameManager = {}

local Net = require("src.net")

-- ── State ─────────────────────────────────────────────────────────────────────

local _config        = nil    -- config table passed in from Lobby (is_host, slots, …)
local _local_id      = nil    -- company/player ID for this instance
local _players       = {}     -- {player_id → {id, name, score}}
local _sim_day       = 0
local _game_over     = false
local _winner_id     = nil
local WIN_TARGET     = 10     -- first to 10 clicks wins

-- Timers
local _tick_timer        = 0
local TICK_INTERVAL      = 1.0   -- one sim-day per real second
local _sync_check_timer  = 0
local SYNC_CHECK_EVERY   = 3     -- days between SYNC_CHECK broadcasts
local _push_timer        = nil   -- host proactive FULL_STATE push after game start

-- UI
local _btn_click = nil   -- {x, y, w, h}
local _font_big, _font_body, _font_small
local _chat_messages  = {}
local _chat_input     = ""
local _chat_scroll    = 0
local CHAT_MAX        = 50

-- Callbacks
local _on_quit = nil   -- function() called when player leaves / game ends

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function chat(player, text)
	_chat_messages[#_chat_messages + 1] = {player = player, text = text}
	if #_chat_messages > CHAT_MAX then table.remove(_chat_messages, 1) end
end

local function get_full_state()
	return {
		sim_day    = _sim_day,
		game_over  = _game_over,
		winner_id  = _winner_id,
		win_target = WIN_TARGET,
		local_id   = _local_id,
		players    = _players,
	}
end

local function apply_full_state(state, as_local_id)
	_sim_day   = state.sim_day   or _sim_day
	_game_over = state.game_over or false
	_winner_id = state.winner_id
	WIN_TARGET = state.win_target or WIN_TARGET
	_players   = state.players   or _players
	if as_local_id then _local_id = as_local_id end
end

local function check_win()
	if _game_over then return end
	for id, p in pairs(_players) do
		if p.score >= WIN_TARGET then
			_game_over = true
			_winner_id = id
			chat("System", (p.name or id) .. " wins with " .. p.score .. " points!")
			return
		end
	end
end

local function broadcast_sync_check()
	local snap = {players = {}}
	for id, p in pairs(_players) do
		snap.players[id] = {name = p.name, score = p.score}
	end
	snap.day = _sim_day
	Net.broadcast({t = Net.MSG.SYNC_CHECK, snap = snap})
end

local function push_full_state_to_all()
	local state = get_full_state()
	local conns = Net.get_p2p_conns and Net.get_p2p_conns() or {}
	for hConn in pairs(conns) do
		local cid = Net.get_company_for_peer(hConn)
		if cid then
			Net.send(hConn, {t = Net.MSG.FULL_STATE, state = state, company_id = cid})
		end
	end
end

-- ── Init ──────────────────────────────────────────────────────────────────────

function GameManager.init(config, opts)
	opts     = opts or {}
	_on_quit = opts.on_quit
	_config  = config

	_sim_day    = 0
	_game_over  = false
	_winner_id  = nil
	_players    = {}
	_chat_messages = {}
	_chat_input = ""
	_tick_timer       = 0
	_sync_check_timer = 0
	_push_timer       = nil

	if not _font_big then
		_font_big   = love.graphics.newFont(32)
		_font_body  = love.graphics.newFont(16)
		_font_small = love.graphics.newFont(12)
	end

	Net._status_cb = function(msg) chat("Net", msg) end
	Net.start_log()

	if config.is_host then
		-- Build player table from lobby slots
		local slot_id = 1
		for _, slot in ipairs(config.slots or {}) do
			if slot.kind == "human" then
				local pid = "p" .. slot_id
				_players[pid] = {id = pid, name = slot.player_name or ("Player " .. slot_id), score = 0}
				if slot.is_host then
					_local_id = pid
				else
					Net.register_peer(pid, slot.peer)
				end
				slot_id = slot_id + 1
			end
		end
		_push_timer = 5.0   -- push FULL_STATE to late-joiners after 5s
		chat("System", "Game started. First to " .. WIN_TARGET .. " wins!")
	else
		-- Client: send GAME_READY and wait for FULL_STATE
		local _ok_bv, _bv = pcall(require, "src.version")
		local build = (_ok_bv and type(_bv) == "string") and _bv or "dev"
		Net.send_to_server({t = Net.MSG.GAME_READY, build = build})
		chat("System", "Connected. Waiting for game state…")
	end
end

-- ── Net event handling ────────────────────────────────────────────────────────

local function handle_event(ev)
	local t = ev.msg_type

	if t == Net.MSG.GAME_READY then
		if Net.is_host() then
			local build = ev.data and ev.data.build or "unknown"
			local _ok_bv, _bv = pcall(require, "src.version")
			local my_build = (_ok_bv and type(_bv) == "string") and _bv or "dev"
			if build ~= my_build then
				print("[GameManager] Version mismatch: client=" .. build .. " host=" .. my_build)
			end
			-- Find this client's player ID and send their state
			local cid = Net.get_company_for_peer(ev.peer)
			if cid then
				local state = get_full_state()
				Net.send(ev.peer, {t = Net.MSG.FULL_STATE, state = state, company_id = cid})
			end
		end

	elseif t == Net.MSG.FULL_STATE then
		if ev.data and ev.data.state and ev.data.company_id then
			apply_full_state(ev.data.state, ev.data.company_id)
			local me = _players[_local_id]
			chat("System", "State received. You are: " .. (me and me.name or _local_id or "?"))
		end

	elseif t == Net.MSG.SYNC_CHECK then
		if ev.data and ev.data.snap then
			-- Compare local scores; request resync if out of sync
			local snap = ev.data.snap
			local desync = false
			for id, sp in pairs(snap.players or {}) do
				local lp = _players[id]
				if lp and lp.score ~= sp.score then
					desync = true; break
				end
			end
			if desync then
				Net.send_to_server({t = Net.MSG.SYNC_REQUEST})
			end
			_sim_day = ev.data.day or _sim_day
		end

	elseif t == Net.MSG.SYNC_REQUEST then
		if Net.is_host() then
			local cid = Net.get_company_for_peer(ev.peer)
			if cid then
				Net.send(ev.peer, {t = Net.MSG.FULL_STATE, state = get_full_state(), company_id = cid})
			end
		end

	elseif t == Net.MSG.SCORE_UPDATE then
		if Net.is_host() then
			local pid = ev.data and ev.data.player_id
			if pid and _players[pid] and not _game_over then
				_players[pid].score = (_players[pid].score or 0) + 1
				check_win()
				-- Immediately push updated state back to sender
				local state = get_full_state()
				Net.send(ev.peer, {t = Net.MSG.FULL_STATE, state = state, company_id = pid})
				broadcast_sync_check()
			end
		end

	elseif t == Net.MSG.GAME_TICK then
		_sim_day = ev.data and ev.data.day or _sim_day

	elseif t == "disconnect" then
		local cid = Net.get_company_for_peer(ev.peer)
		if cid and _players[cid] then
			chat("System", (_players[cid].name or cid) .. " disconnected.")
		end
		if not Net.is_host() then
			chat("System", "Lost connection to host.")
		end
	end
end

-- ── Update ────────────────────────────────────────────────────────────────────

function GameManager.update(dt)
	-- Host proactive push
	if _push_timer then
		_push_timer = _push_timer - dt
		if _push_timer <= 0 then
			_push_timer = nil
			if Net.is_host() then push_full_state_to_all() end
		end
	end

	-- Host: sim tick + periodic sync check
	if Net.is_host() and not _game_over then
		_tick_timer = _tick_timer + dt
		if _tick_timer >= TICK_INTERVAL then
			_tick_timer = _tick_timer - TICK_INTERVAL
			_sim_day = _sim_day + 1
			Net.broadcast({t = Net.MSG.GAME_TICK, day = _sim_day})
			_sync_check_timer = _sync_check_timer + 1
			if _sync_check_timer >= SYNC_CHECK_EVERY then
				_sync_check_timer = 0
				broadcast_sync_check()
			end
		end
	end

	-- Net events
	local events = Net.poll()
	for _, ev in ipairs(events) do
		handle_event(ev)
	end
end

-- ── Draw ──────────────────────────────────────────────────────────────────────

local function draw_chat(x, y, w, h)
	love.graphics.setColor(0.04, 0.06, 0.12, 0.88)
	love.graphics.rectangle("fill", x, y, w, h, 6, 6)
	love.graphics.setColor(0.22, 0.32, 0.52, 0.7)
	love.graphics.rectangle("line", x, y, w, h, 6, 6)

	love.graphics.setFont(_font_small)
	local lh   = _font_small:getHeight() + 2
	local rows = math.floor((h - 30) / lh)
	local start = math.max(1, #_chat_messages - rows - _chat_scroll + 1)
	local cy = y + 6
	for i = start, math.min(#_chat_messages, start + rows - 1) do
		local m = _chat_messages[i]
		love.graphics.setColor(0.65, 0.8, 1.0, 0.9)
		love.graphics.print((m.player or "") .. ":", x + 8, cy)
		love.graphics.setColor(0.88, 0.92, 1.0, 0.9)
		love.graphics.printf(m.text or "", x + 76, cy, w - 84, "left")
		cy = cy + lh
	end
	-- Input
	love.graphics.setColor(0.07, 0.1, 0.2, 1.0)
	love.graphics.rectangle("fill", x+4, y+h-26, w-8, 22, 4, 4)
	love.graphics.setColor(0.9, 0.92, 1.0, 0.9)
	love.graphics.setFont(_font_small)
	love.graphics.print(_chat_input .. "|", x+10, y+h-23)
end

function GameManager.draw()
	local W, H = love.graphics.getDimensions()
	_btn_click = nil

	love.graphics.setColor(0.04, 0.06, 0.12, 1.0)
	love.graphics.rectangle("fill", 0, 0, W, H)

	-- Scoreboard
	love.graphics.setFont(_font_body)
	love.graphics.setColor(0.6, 0.75, 1.0, 0.8)
	love.graphics.print("Day " .. _sim_day .. "   First to " .. WIN_TARGET .. " wins", 20, 16)

	local py = 60
	local sorted = {}
	for _, p in pairs(_players) do sorted[#sorted+1] = p end
	table.sort(sorted, function(a, b) return (a.score or 0) > (b.score or 0) end)

	for rank, p in ipairs(sorted) do
		local is_me = (p.id == _local_id)
		love.graphics.setColor(is_me and 0.12 or 0.07, is_me and 0.2 or 0.1, is_me and 0.38 or 0.2, 0.9)
		love.graphics.rectangle("fill", 20, py, 280, 36, 5, 5)
		love.graphics.setColor(is_me and 0.4 or 0.25, is_me and 0.6 or 0.35, is_me and 0.9 or 0.55, 0.7)
		love.graphics.rectangle("line", 20, py, 280, 36, 5, 5)
		love.graphics.setFont(_font_body)
		love.graphics.setColor(is_me and 1.0 or 0.8, is_me and 1.0 or 0.88, 1.0, 1.0)
		love.graphics.print(string.format("#%d  %s", rank, p.name or p.id), 30, py + 9)
		love.graphics.printf(tostring(p.score or 0), 20, py + 9, 280, "right")
		py = py + 44
	end

	-- Win banner
	if _game_over then
		local winner = _winner_id and _players[_winner_id]
		love.graphics.setColor(0, 0, 0, 0.7)
		love.graphics.rectangle("fill", 0, 0, W, H)
		love.graphics.setFont(_font_big)
		love.graphics.setColor(1.0, 0.9, 0.3, 1.0)
		love.graphics.printf(winner and (winner.name .. " wins!") or "Game over!", 0, H/2 - 40, W, "center")
		love.graphics.setFont(_font_body)
		love.graphics.setColor(0.7, 0.8, 1.0, 0.8)
		love.graphics.printf("Press Escape to return to menu", 0, H/2 + 20, W, "center")
		return
	end

	-- Click button (the whole game mechanic)
	local me = _local_id and _players[_local_id]
	if me then
		local bw, bh = 220, 80
		local bx, by = W/2 - bw/2, H - 180
		love.graphics.setColor(0.12, 0.35, 0.7, 1.0)
		love.graphics.rectangle("fill", bx, by, bw, bh, 12, 12)
		love.graphics.setColor(0.35, 0.6, 1.0, 0.7)
		love.graphics.rectangle("line", bx, by, bw, bh, 12, 12)
		love.graphics.setFont(_font_big)
		love.graphics.setColor(1, 1, 1, 1)
		love.graphics.printf("Click! (" .. (me.score or 0) .. ")", bx, by + 22, bw, "center")
		_btn_click = {x = bx, y = by, w = bw, h = bh}
	end

	-- Chat box
	draw_chat(W - 340, 60, 320, H - 80)

	-- Net debug overlay (F2)
	Net.draw_debug(W, H)
end

-- ── Input ─────────────────────────────────────────────────────────────────────

function GameManager.mousepressed(x, y, button)
	if button ~= 1 then return end
	if _game_over then return end
	if _btn_click then
		local b = _btn_click
		if x >= b.x and x <= b.x+b.w and y >= b.y and y <= b.y+b.h then
			if Net.is_host() then
				-- Host scores directly
				local me = _local_id and _players[_local_id]
				if me then
					me.score = (me.score or 0) + 1
					check_win()
					broadcast_sync_check()
				end
			else
				Net.send_to_server({t = Net.MSG.SCORE_UPDATE, player_id = _local_id})
			end
		end
	end
end

function GameManager.keypressed(key)
	if key == "escape" then
		Net.close()
		if _on_quit then _on_quit() end
	elseif key == "f2" then
		Net.toggle_debug()
	elseif key == "return" or key == "kpenter" then
		if _chat_input ~= "" then
			local text = _chat_input:sub(1, 140)
			_chat_input = ""
			local Steam = require("src.steam")
			local player = Steam.my_name()
			chat(player, text)
			-- Chat relay: for simplicity, host and clients both broadcast
			Net.broadcast({t = Net.MSG.LOBBY_CHAT, player = player, text = text})
		end
	elseif key == "backspace" then
		_chat_input = _chat_input:sub(1, -2)
	end
end

function GameManager.textinput(text)
	if #_chat_input < 140 then _chat_input = _chat_input .. text end
end

function GameManager.wheelmoved(_, dy)
	_chat_scroll = math.max(0, _chat_scroll - dy)
end

return GameManager
