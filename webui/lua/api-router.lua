-- api-router.lua: unified API router for keenetic-entware-extras WebUI.
-- Dispatches /api/* URIs to shell commands, returns JSON responses.
-- Compatible with LuaJIT (nginx-mod-lua / OpenResty).

local uri = ngx.var.uri
local base = "/opt/keenetic-entware-extras"
local shell_env = "export PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin;"

--- Read entire file contents or return nil.
-- @param path string — absolute file path
-- @return string|nil
local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

--- Run shell command and return (output, ok, exit_code).
-- Appends exit code marker to command output for robust parsing
-- (nginx lua module may patch io.popen close() behavior).
-- @param cmd string — shell command
-- @return string, boolean, number
local function run_cmd(cmd)
    -- Append exit code marker to reliably capture it
    local full_cmd = shell_env .. " " .. cmd .. '; echo "::EXIT:$?"'
    local handle = io.popen(full_cmd)
    if not handle then
        return "", false, -1
    end
    local raw = handle:read("*a")
    handle:close()

    -- Extract exit code from the last line marker
    local output, code_str = raw:match("^(.-)::EXIT:(%d+)%s*$")
    if not output then
        -- Marker not found — treat as failure
        return raw, false, 1
    end

    local exit_code = tonumber(code_str) or 1
    return output, (exit_code == 0), exit_code
end

--- Escape string for safe JSON embedding.
-- @param s string
-- @return string
local function json_escape(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    return s
end

--- Build /api/system/info response purely in Lua (no shell JSON construction).
-- @return string — JSON
local function system_info()
    -- hostname (read from /proc — more reliable than hostname command)
    local hostname = "unknown"
    local h_data = read_file("/proc/sys/kernel/hostname")
    if h_data then
        hostname = h_data:gsub("%s+$", "")
    end

    -- uptime from /proc/uptime (seconds since boot)
    local uptime_str = "unknown"
    local proc_uptime = read_file("/proc/uptime")
    if proc_uptime then
        local secs = tonumber(proc_uptime:match("^([%d%.]+)"))
        if secs then
            local days = math.floor(secs / 86400)
            local hours = math.floor((secs % 86400) / 3600)
            local mins = math.floor((secs % 3600) / 60)
            if days > 0 then
                uptime_str = string.format("%dd %dh %dm", days, hours, mins)
            elseif hours > 0 then
                uptime_str = string.format("%dh %dm", hours, mins)
            else
                uptime_str = string.format("%dm", mins)
            end
        end
    end

    -- memory from /proc/meminfo
    local mem_total = 0
    local mem_available = 0
    local meminfo = read_file("/proc/meminfo")
    if meminfo then
        mem_total = tonumber(meminfo:match("MemTotal:%s+(%d+)")) or 0
        mem_available = tonumber(meminfo:match("MemAvailable:%s+(%d+)")) or 0
    end

    -- disk usage for /opt
    local disk_total = 0
    local disk_used = 0
    local disk_free = 0
    local df_out = run_cmd("df -k /opt 2>/dev/null | awk 'NR==2{print $2,$3,$4}'")
    if df_out then
        local t, u, a = df_out:match("(%d+)%s+(%d+)%s+(%d+)")
        if t then
            disk_total = t
            disk_used = u
            disk_free = a
        end
    end

    return '{"ok":true,'
        .. '"hostname":"' .. json_escape(hostname) .. '",'
        .. '"uptime":"' .. json_escape(uptime_str) .. '",'
        .. '"memory":{"total_kb":' .. mem_total .. ',"available_kb":' .. mem_available .. '},'
        .. '"disk_opt":{"total_kb":' .. disk_total .. ',"used_kb":' .. disk_used .. ',"free_kb":' .. disk_free .. '}'
        .. '}'
end

-- Status script routes: URI → shell command
-- JSON routes call status.sh --json → output is already valid JSON
local json_routes = {
    ["/api/geo-split/status"]        = base .. "/geo-split/scripts/status.sh --json 2>&1",
    ["/api/smartdns/status"]          = base .. "/smartdns-conf-ru-split/scripts/status.sh --json 2>&1",
    ["/api/smartdns-redirect/status"] = base .. "/smartdns-redirect/scripts/status.sh --json 2>&1",
    ["/api/webui/status"]             = base .. "/webui/scripts/status.sh --json 2>&1",
}

-- Text routes (legacy, no --json support yet)
local text_routes = {
}

-- Action routes: POST-only commands (start/stop/update)
-- enable/disable: persistent on/off (survives reboot, hooks respect it)
local action_routes = {
    -- Start/Stop (enable/disable for persistent state)
    ["/api/geo-split/start"]           = base .. "/geo-split/init.d/S99geo-split enable 2>&1",
    ["/api/geo-split/stop"]            = base .. "/geo-split/init.d/S99geo-split disable 2>&1",
    ["/api/smartdns/start"]            = base .. "/smartdns-conf-ru-split/scripts/toggle.sh enable 2>&1",
    ["/api/smartdns/stop"]             = base .. "/smartdns-conf-ru-split/scripts/toggle.sh disable 2>&1",
    ["/api/smartdns-redirect/start"]   = base .. "/smartdns-redirect/init.d/S39smartdns-redirect enable 2>&1",
    ["/api/smartdns-redirect/stop"]    = base .. "/smartdns-redirect/init.d/S39smartdns-redirect disable 2>&1",
    -- Update (geo-split only, runs in background)
    -- Wrap in subshell (...&) so run_cmd's appended '; echo "::EXIT:$?"'
    -- does not produce "&;" which is a syntax error in BusyBox ash.
    ["/api/geo-split/update-subnets"]  = "(" .. base .. "/geo-split/scripts/update-subnets.sh --force >/dev/null 2>&1 &)",
    ["/api/geo-split/update-domains"]  = "(" .. base .. "/geo-split/scripts/update-domains.sh --force >/dev/null 2>&1 &)",
}

-- Dispatch
if uri == "/api/system/info" then
    ngx.say(system_info())
    return
end

-- Action routes: POST-only
local action_cmd = action_routes[uri]
if action_cmd then
    if ngx.req.get_method() ~= "POST" then
        ngx.status = 405
        ngx.header["Allow"] = "POST"
        ngx.say('{"ok":false,"error":"method not allowed"}')
        return
    end
    local output, ok, _ = run_cmd(action_cmd)
    output = output:gsub("%s+$", "")
    ngx.say('{"ok":' .. tostring(ok) .. ',"output":"' .. json_escape(output) .. '"}')
    return
end

-- JSON passthrough: script outputs valid JSON directly
local json_cmd = json_routes[uri]
if json_cmd then
    local output, _, _ = run_cmd(json_cmd)
    -- Trim trailing whitespace and check if output looks like JSON
    output = output:gsub("%s+$", "")
    if output:sub(1, 1) == "{" then
        ngx.say(output)
    else
        -- Fallback: script failed before JSON output
        ngx.say('{"running":false,"ok":false,"error":"' .. json_escape(output) .. '"}')
    end
    return
end

-- Text routes: wrap output in JSON string
local text_cmd = text_routes[uri]
if text_cmd then
    local output, _, exit_code = run_cmd(text_cmd)
    output = json_escape(output)
    ngx.say('{"ok":' .. tostring(exit_code == 0) .. ',"output":"' .. output .. '"}')
    return
end

ngx.status = 404
ngx.say('{"ok":false,"error":"not found","uri":"' .. json_escape(uri) .. '"}')
