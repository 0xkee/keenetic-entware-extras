-- serve-index.lua: serve custom index.html with stock CSS auto-detection.
-- Reads the template index.html, replaces styles-{HASH}.css with the actual
-- firmware hash detected at startup by stock-css-init.lua.
-- Called via content_by_lua_file for /custom/index.html requests.

local stock_css = package.loaded._stock_css or "styles-J4CVWJOW.css"
local path = "/opt/keenetic-entware-extras/webui/static/index.html"

local f = io.open(path, "r")
if not f then
    ngx.status = 404
    ngx.say("index.html not found")
    return
end

local html = f:read("*a")
f:close()

html = html:gsub("styles%-[A-Za-z0-9]+%.css", stock_css)
ngx.header["Content-Type"] = "text/html"
ngx.header["Cache-Control"] = "no-cache, must-revalidate"
ngx.print(html)
