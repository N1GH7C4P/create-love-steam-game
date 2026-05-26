-- {{GAME_NAME}} — entry point
-- State machine: menu → lobby → game

-- Redirect print() to save-dir log file so logs survive between runs.
do
	local _orig_print = print
	local _log_path   = "game_log.txt"
	local _save_dir   = love.filesystem.getSaveDirectory() or "?"
	local header = "=== " .. os.date("%Y-%m-%d %H:%M:%S") .. " | " .. _save_dir .. " ===\n"
	pcall(love.filesystem.write, _log_path, header)
	_orig_print("[Log] " .. _save_dir .. "/" .. _log_path)
	print = function(...)
		_orig_print(...)
		local parts = {}
		for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
		pcall(love.filesystem.append, _log_path, table.concat(parts, "\t") .. "\n")
	end
end

local _ok_ver, _build_version = pcall(require, "src.version")
_build_version = (_ok_ver and type(_build_version) == "string") and _build_version or "dev"
print("[Version] " .. _build_version)

local Menu        = require("src.menu")
local Lobby       = require("src.lobby")
local GameManager = require("src.game_manager")
local Steam       = require("src.steam")
local Net         = require("src.net")

local app_state = "menu"   -- "menu" | "lobby" | "game"

-- ── CLI args ──────────────────────────────────────────────────────────────────
-- love . +connect_lobby <lobby_id>   — Steam overlay "Join Game" deep link
local CLI = {}
for i, v in ipairs(arg or {}) do
	if v == "+connect_lobby" and arg[i+1] then
		CLI.connect_lobby = arg[i+1]
	end
end

-- ── State transitions ─────────────────────────────────────────────────────────

local function go_menu()
	app_state = "menu"
	Menu.init({
		on_host = function()
			Lobby.init({
				on_start  = function(cfg) app_state = "game"; GameManager.init(cfg, {on_quit = go_menu}) end,
				on_cancel = go_menu,
			})
			Lobby.start_host()
			app_state = "lobby"
		end,
		on_join = function()
			Lobby.init({
				on_start  = function(cfg) app_state = "game"; GameManager.init(cfg, {on_quit = go_menu}) end,
				on_cancel = go_menu,
			})
			Lobby.start_join()
			app_state = "lobby"
		end,
		on_quit = function() love.event.quit() end,
	})
end

-- ── Love2D callbacks ──────────────────────────────────────────────────────────

function love.load()
	love.window.setTitle("{{GAME_NAME}}")
	love.graphics.setDefaultFilter("linear", "linear")

	go_menu()

	-- Handle +connect_lobby deep link from Steam
	if CLI.connect_lobby then
		local SteamLobby = require("src.steam_lobby")
		SteamLobby.join(CLI.connect_lobby, function(host_sid)
			Lobby.init({
				on_start  = function(cfg) app_state = "game"; GameManager.init(cfg, {on_quit = go_menu}) end,
				on_cancel = go_menu,
			})
			-- init_client called internally by Lobby via SteamLobby join callback
			app_state = "lobby"
		end)
	end
end

function love.update(dt)
	if     app_state == "menu"  then Menu.update(dt)
	elseif app_state == "lobby" then Lobby.update(dt)
	elseif app_state == "game"  then GameManager.update(dt)
	end
end

function love.draw()
	if     app_state == "menu"  then Menu.draw()
	elseif app_state == "lobby" then Lobby.draw()
	elseif app_state == "game"  then GameManager.draw()
	end
end

function love.mousepressed(x, y, button)
	if     app_state == "menu"  then Menu.mousepressed(x, y, button)
	elseif app_state == "lobby" then Lobby.mousepressed(x, y, button)
	elseif app_state == "game"  then GameManager.mousepressed(x, y, button)
	end
end

function love.keypressed(key, scancode, isrepeat)
	if isrepeat then return end
	if     app_state == "menu"  then Menu.keypressed(key)
	elseif app_state == "lobby" then Lobby.keypressed(key)
	elseif app_state == "game"  then GameManager.keypressed(key)
	end
end

function love.textinput(text)
	if     app_state == "lobby" then Lobby.textinput(text)
	elseif app_state == "game"  then GameManager.textinput(text)
	end
end

function love.wheelmoved(x, y)
	if     app_state == "lobby" then Lobby.wheelmoved(x, y)
	elseif app_state == "game"  then GameManager.wheelmoved(x, y)
	end
end

function love.quit()
	Net.close()
	Steam.shutdown()
end
