-- stock-css-init.lua: detect stock CSS filename from firmware at nginx startup.
-- Reads /usr/share/htdocs_/index.html to find styles-{HASH}.css.
-- Called via init_by_lua_file; result stored in package.loaded._stock_css.
-- After firmware upgrade: `nginx -s reload` re-detects the new hash.

local stock_css = "styles-J4CVWJOW.css"  -- fallback
local f = io.open("/usr/share/htdocs_/index.html", "r")
if f then
    local html = f:read("*a")
    f:close()
    local css = html:match("(styles%-[A-Za-z0-9]+%.css)")
    if css then stock_css = css end
end
package.loaded._stock_css = stock_css
