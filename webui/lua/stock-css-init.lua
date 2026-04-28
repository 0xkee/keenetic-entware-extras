-- stock-css-init.lua: detect ALL stock CSS files from firmware filesystem.
-- Scans /usr/share/htdocs_/ root for *.css (NOT recursive — wizards/ has
-- its own separate CSS that would conflict with the main UI styles).
-- Typically finds one: styles-{HASH}.css (Angular content-hash build).
-- Called via init_by_lua_file; result stored in package.loaded._stock_css.
-- After firmware upgrade: `nginx -s reload` re-detects the new filenames.

local HTDOCS = "/usr/share/htdocs_"

local css_files = {}
local ok, _ = pcall(function()
    -- Shell glob *.css is root-level only (no subdirectory descent).
    local p = io.popen("ls " .. HTDOCS .. "/*.css 2>/dev/null")
    if p then
        for line in p:lines() do
            local name = line:match("([^/]+)$")
            if name then css_files[#css_files + 1] = name end
        end
        p:close()
    end
end)

-- Store all found CSS files (table); empty table if none found.
-- serve-index.lua generates <link> tags for each one.
package.loaded._stock_css = css_files
