-- love-build configuration
-- See: https://github.com/ellraiser/love-build

local version = "0.0.0"
local f = io.open("VERSION", "r")
if f then
    version = f:read("*l") or version
    f:close()
end

return {
    name = '{{GAME_NAME}}',
    developer = 'YourStudio',
    version = version,
    love = '11.5',
    icon = 'assets/icons/icon.png',  -- must exist; love-build errors if empty
    identifier = 'com.yourstudio.{{GAME_SLUG}}',
    ignore = {
        '.git', '.github', '.claude',
        'scripts',
        '.build-staging',
        'dist',
        '.DS_Store', '.env', '.env.example', '.gitignore',
        'steam_appid.txt',
    },
    platforms = {'windows', 'macos', 'linux'},
}
