-- api-router.lua: unified API router for keenetic-entware-extras WebUI.
-- Dispatches /api/* URIs to shell commands, returns JSON responses.
-- Compatible with LuaJIT (nginx-mod-lua / OpenResty).

local utils   = require("api-utils")
local system  = require("api-system")
local config  = require("api-config")
local data    = require("api-data")

local uri = ngx.var.uri
local base = utils.base
local cache = utils.cache
local run_cmd = utils.run_cmd
local json_escape = utils.json_escape
local cached_run = utils.cached_run

-- Status script routes: URI → shell command
-- JSON routes call status.sh --json → output is already valid JSON
local json_routes = {
    ["/api/geo-split/status"]        = base .. "/geo-split/scripts/status.sh --json 2>&1",
    ["/api/geo-split/wan-paths"]     = base .. "/geo-split/scripts/wan-paths.sh 2>&1",
    ["/api/smartdns/status"]          = base .. "/smartdns-geo-conf/scripts/status.sh --json 2>&1",
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
    ["/api/smartdns/start"]            = base .. "/smartdns-geo-conf/scripts/toggle.sh enable 2>&1",
    ["/api/smartdns/stop"]             = base .. "/smartdns-geo-conf/scripts/toggle.sh disable 2>&1",
    ["/api/smartdns-redirect/start"]   = base .. "/smartdns-redirect/init.d/S39smartdns-redirect enable 2>&1",
    ["/api/smartdns-redirect/stop"]    = base .. "/smartdns-redirect/init.d/S39smartdns-redirect disable 2>&1",
    -- Update (geo-split only, runs in background)
    -- Wrap in subshell (...&) so run_cmd's appended '; echo "::EXIT:$?"'
    -- does not produce "&;" which is a syntax error in BusyBox ash.
    ["/api/geo-split/update-subnets"]  = "(" .. base .. "/geo-split/scripts/update-subnets.sh --force >/dev/null 2>&1 &)",
    ["/api/geo-split/update-domains"]  = "(" .. base .. "/geo-split/scripts/update-domains.sh --force >/dev/null 2>&1 &)",
    -- Cache flush (smartdns: stop daemon, delete persistent cache, restart)
    ["/api/smartdns/flush-cache"]      = base .. "/smartdns-geo-conf/init.d/S37smartdns-conf flush-cache 2>&1",
}

-- Lua-computed routes: cached JSON endpoints
local lua_routes = {
    ["/api/system/info"]          = { fn = system.info,          ttl = utils.CACHE_TTL },
    ["/api/system/interfaces"]    = { fn = system.interfaces,    ttl = utils.IFACE_TTL },
    ["/api/system/clients"]       = { fn = system.clients,       ttl = utils.IFACE_TTL },
    ["/api/system/zones"]         = { fn = data.zones,           ttl = utils.STATIC_TTL },
    ["/api/system/dns-providers"] = { fn = data.dns_providers,   ttl = utils.STATIC_TTL },
}

-- Alias: /api/smartdns/zones → same handler & cache key as /api/system/zones
lua_routes["/api/smartdns/zones"] = { fn = data.zones, ttl = utils.STATIC_TTL, cache_key = "/api/system/zones" }

--- Serve a lua_routes entry with shared_dict caching.
-- @param cfg table {fn, ttl, cache_key?}
local function serve_cached_lua(cfg)
    local key = cfg.cache_key or uri
    local cached = cache:get(key)
    if cached then
        ngx.say(cached)
    else
        local result = cfg.fn()
        cache:set(key, result, cfg.ttl)
        ngx.say(result)
    end
end

-- ── Dispatch ─────────────────────────────────────────────────────────────────

-- Dispatch: lua_routes lookup
local route_cfg = lua_routes[uri]
if route_cfg then
    serve_cached_lua(route_cfg)
    return
end

-- Cache flush: POST-only, pure Lua (no shell), flushes all status cache entries
if uri == "/api/webui/flush-cache" then
    if ngx.req.get_method() ~= "POST" then
        ngx.status = 405
        ngx.header["Allow"] = "POST"
        ngx.say('{"ok":false,"error":"method not allowed"}')
        return
    end
    local status_keys = {
        "/api/geo-split/status", "/api/smartdns/status",
        "/api/smartdns-redirect/status", "/api/webui/status",
    }
    for _, key in ipairs(status_keys) do
        cache:delete(key)
        cache:delete(key .. "::stale")
        cache:delete(key .. "::lock")
    end
    ngx.say('{"ok":true}')
    return
end

-- Config endpoints: GET = read, POST = write + restart
local config_match = uri:match("^/api/([%w%-]+)/config$")
if config_match then
    if ngx.req.get_method() == "POST" then
        ngx.req.read_body()
        local body = ngx.req.get_body_data() or ""
        local result = config.write(config_match, body)
        -- Invalidate status cache (config save triggers restart)
        local status_key = "/api/" .. config_match .. "/status"
        cache:delete(status_key)
        cache:delete(status_key .. "::stale")
        ngx.say(result)
    else
        ngx.say(config.read(config_match))
    end
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
    -- Invalidate status cache for this service so next poll sees new state
    local svc = uri:match("^/api/([^/]+)/")
    if svc then
        local status_key = "/api/" .. svc .. "/status"
        cache:delete(status_key)
        cache:delete(status_key .. "::stale")
        cache:delete(status_key .. "::lock")
    end
    ngx.say('{"ok":' .. tostring(ok) .. ',"output":"' .. json_escape(output) .. '"}')
    return
end

-- JSON passthrough: script outputs valid JSON directly (with cache)
local json_cmd = json_routes[uri]
if json_cmd then
    local output = cached_run(uri, json_cmd)
    -- Inject lua_shared_dict usage into webui cache field (shell can't access nginx internals)
    if uri == "/api/webui/status" then
        local used_kb = math.floor((cache:capacity() - cache:free_space()) / 1024 + 0.5)
        output = output:gsub('"cache":true', '"cache":"' .. used_kb .. ' KB"')
    end
    if output:sub(1, 1) == "{" or output:sub(1, 1) == "[" then
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

-- ── Diagnostic routes (GET, rate-limited at nginx level) ─────────────────────
-- Real-time diagnostic tools: call external scripts with sanitized query params.
-- Rate limiting is handled by nginx limit_req zone=api_diag (1r/s per IP).

--- Validate host parameter: only [a-zA-Z0-9._-] allowed, max 253 chars.
-- @param s string|nil
-- @return string|nil — sanitized host or nil if invalid
local function validate_host(s)
    if not s or s == "" then return nil end
    if #s <= 253 and s:match("^[a-zA-Z0-9._%-]+$") then
        return s
    end
    return nil
end

--- Validate CIDR notation: A.B.C.D/N where N is 0-32, max 18 chars.
-- @param s string|nil
-- @return string|nil — sanitized CIDR or nil if invalid
local function validate_cidr(s)
    if not s or s == "" then return nil end
    if #s > 18 then return nil end
    local ip, prefix = s:match("^(%d+%.%d+%.%d+%.%d+)/(%d+)$")
    if ip and prefix then
        local n = tonumber(prefix)
        if n and n >= 0 and n <= 32 then
            return s
        end
    end
    return nil
end

--- Validate interface parameter: only [a-z0-9_] allowed, max 15 chars.
-- @param s string|nil
-- @return string|nil — sanitized iif or nil if invalid
local function validate_iif(s)
    if not s or s == "" then return nil end
    if #s <= 15 and s:match("^[a-z0-9_]+$") then
        return s
    end
    return nil
end

--- Validate MAC address: XX:XX:XX:XX:XX:XX format (hex + colons).
-- @param s string|nil
-- @return string|nil — uppercased MAC or nil if invalid
local function validate_mac(s)
    if not s or s == "" then return nil end
    if s:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
        return s:upper()
    end
    return nil
end

-- Diagnostic: /api/geo-split/route-check?host=...&from=...
-- "from" can be an interface name (br0, local) or a client MAC (XX:XX:XX:XX:XX:XX).
-- MAC resolution to fwmark is done inside route-check.sh via --from flag.
if uri == "/api/geo-split/route-check" then
    local args = ngx.req.get_uri_args()
    local host = validate_host(args.host) or validate_cidr(args.host)
    if not host then
        ngx.say('{"ok":false,"error":"invalid_input","message":"host parameter required: domain, IPv4, or CIDR notation"}')
        return
    end
    local from_arg = ""
    local from = args.from or args.iif  -- backward compat: accept both "from" and "iif"
    if from then
        local mac = validate_mac(from)
        if mac then
            -- Client MAC → pass to script's --from flag (resolves fwmark internally)
            from_arg = ' --from "' .. mac .. '"'
        else
            local iif = validate_iif(from)
            if not iif then
                ngx.say('{"ok":false,"error":"invalid_input","message":"from parameter invalid: interface [a-z0-9_] or MAC XX:XX:XX:XX:XX:XX"}')
                return
            end
            from_arg = ' "' .. iif .. '"'
        end
    end
    local cmd = base .. '/geo-split/scripts/route-check.sh --json "' .. host .. '"' .. from_arg .. " 2>&1"
    local output, _, _ = run_cmd(cmd)
    output = output:gsub("%s+$", "")
    if output == "" or output:sub(1, 1) ~= "{" then
        ngx.say('{"ok":false,"error":"script_error","message":"' .. json_escape(output ~= "" and output or "empty output") .. '"}')
        return
    end
    ngx.say(output)
    return
end

-- Diagnostic: /api/smartdns/dns-check?host=...
if uri == "/api/smartdns/dns-check" then
    local args = ngx.req.get_uri_args()
    local host = validate_host(args.host)
    if not host then
        ngx.say('{"ok":false,"error":"invalid_input","message":"host parameter required: only [a-zA-Z0-9._-] allowed"}')
        return
    end
    local cmd = base .. '/smartdns-geo-conf/scripts/dns-check.sh --json "' .. host .. '" 2>&1'
    local output, _, _ = run_cmd(cmd)
    output = output:gsub("%s+$", "")
    if output == "" or output:sub(1, 1) ~= "{" then
        ngx.say('{"ok":false,"error":"script_error","message":"' .. json_escape(output ~= "" and output or "empty output") .. '"}')
        return
    end
    ngx.say(output)
    return
end

ngx.status = 404
ngx.say('{"ok":false,"error":"not found","uri":"' .. json_escape(uri) .. '"}')
