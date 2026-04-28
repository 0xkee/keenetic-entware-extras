-- serve-index.lua: serve custom index.html with stock CSS auto-detection.
-- Replaces the placeholder <link> for stock CSS with actual links detected
-- at startup by stock-css-init.lua (filesystem scan of /usr/share/htdocs_/).
-- Called via content_by_lua_file for /custom/index.html requests.

local css_files = package.loaded._stock_css or {}
local path = "/opt/keenetic-entware-extras/webui/static/index.html"

local f = io.open(path, "r")
if not f then
    ngx.status = 404
    ngx.say("index.html not found")
    return
end

local html = f:read("*a")
f:close()

-- Build <link> tags for all detected stock CSS files
if #css_files > 0 then
    local links = {}
    for i = 1, #css_files do
        links[i] = '<link rel="stylesheet" href="/' .. css_files[i] .. '">'
    end
    -- Replace the placeholder stock CSS link with actual detected links
    html = html:gsub('<link rel="stylesheet" href="/styles%-[A-Za-z0-9]+%.css">', table.concat(links, "\n    "))
else
    -- No stock CSS found — remove the placeholder link (graceful degradation)
    html = html:gsub('%s*<link rel="stylesheet" href="/styles%-[A-Za-z0-9]+%.css">', "")
end

ngx.header["Content-Type"] = "text/html"
ngx.header["Cache-Control"] = "no-cache, must-revalidate"
ngx.print(html)
