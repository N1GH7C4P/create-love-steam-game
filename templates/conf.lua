function love.conf(t)
	t.identity       = "{{GAME_IDENTITY}}"
	t.window.width   = {{WINDOW_WIDTH}}
	t.window.height  = {{WINDOW_HEIGHT}}
	t.window.title   = "{{GAME_NAME}}"
	t.window.resizable = true
	t.window.msaa    = 4
	t.console = false

	-- Extend cpath so require("luasteam") finds the native library.
	-- love.filesystem is available here; love.system is NOT.
	-- getSourceBaseDirectory() returns Contents/Resources/ for a love-build macOS bundle,
	-- which is where the build script places luasteam.so/.dll.
	-- The lib/<platform> entries cover local dev runs via `love .` (cwd = project root).
	local src = love.filesystem.getSourceBaseDirectory() or ""
	if src ~= "" then
		if not src:match("[/\\]$") then src = src .. "/" end
		package.cpath = src .. "?.so;" .. src .. "?.dll;" .. package.cpath
	end
	package.cpath = "lib/macos/?.so;lib/windows/?.dll;lib/linux/?.so;" .. package.cpath
end
