-- api-utils.lua: shared utility functions for keenetic-entware-extras WebUI API.
-- Used by api-system, api-config, api-data modules.
-- Compatible with LuaJIT (nginx-mod-lua / OpenResty).

local M = {}

-- ── Shared constants ─────────────────────────────────────────────────────────
M.base = "/opt/keenetic-entware-extras"
M.shell_env = "export PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin;"

-- ── Status response cache ────────────────────────────────────────────────────
-- Deduplicates concurrent polling from multiple browser tabs.
-- Only one worker runs the script per TTL window; others get cached result.
-- CLI `status.sh --json` is unaffected (called directly, not through nginx).
local cache = ngx.shared.status_cache
M.cache = cache
M.CACHE_TTL = 5       -- default fresh cache lifetime (seconds)
M.STALE_TTL = 30      -- stale fallback while script is running (seconds)
M.LOCK_TTL = 45       -- max time to hold execution lock (seconds)
M.STATIC_TTL = 3600   -- static data cache (zones, unions) — 1 hour
M.IFACE_TTL = 60      -- interfaces list — changes rarely (tunnel toggle)

-- Per-endpoint TTL overrides: heavy scripts get longer cache to reduce CPU.
-- POST actions (start/stop/config) invalidate cache instantly regardless of TTL.
M.ENDPOINT_TTLS = {
    ["/api/geo-split/status"]        = 10,  -- detect_dns_port inside = 2×dig
    ["/api/geo-split/wan-paths"]     = 60,  -- ip rule/route scanning (stable between tunnel changes)
    ["/api/smartdns/status"]          = 15,  -- collect_dns_tests_json = N×dig +time=3
    ["/api/smartdns-redirect/status"] = 5,   -- iptables -C (fast)
    ["/api/webui/status"]             = 5,   -- netstat + pidof (fast)
}

--- Read entire file contents or return nil.
-- @param path string — absolute file path
-- @return string|nil
function M.read_file(path)
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
function M.run_cmd(cmd)
    -- Append exit code marker to reliably capture it
    local full_cmd = M.shell_env .. " " .. cmd .. '; echo "::EXIT:$?"'
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

--- Fetch cached response or run command with deduplication.
-- @param key string — cache key (URI)
-- @param cmd string — shell command to execute on cache miss
-- @return string — JSON output
function M.cached_run(key, cmd)
    -- Fast path: fresh cache hit
    local cached = cache:get(key)
    if cached then
        return cached
    end

    -- Try to acquire execution lock (atomic set-if-not-exists)
    local lock_key = key .. "::lock"
    local ok, _ = cache:add(lock_key, true, M.LOCK_TTL)
    if not ok then
        -- Another worker is executing — return stale data if available
        local stale = cache:get(key .. "::stale")
        if stale then
            return stale
        end
        -- No stale data (cold start) — return pending indicator.
        -- Frontend treats missing "running" field as "status unknown, don't update badge".
        return '{"status":"pending"}'
    end

    -- Execute the script
    local output, _, _ = M.run_cmd(cmd)
    output = output:gsub("%s+$", "")

    -- Validate JSON (object or array) and cache with per-endpoint TTL
    if output:sub(1, 1) == "{" or output:sub(1, 1) == "[" then
        local ttl = M.ENDPOINT_TTLS[key] or M.CACHE_TTL
        cache:set(key, output, ttl)
        cache:set(key .. "::stale", output, M.STALE_TTL)
    end

    -- Release lock
    cache:delete(lock_key)

    return output
end

--- Escape string for safe JSON embedding.
-- @param s string
-- @return string
function M.json_escape(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    -- Escape remaining control characters (0x00-0x1F) as \uXXXX
    s = s:gsub('%c', function(c)
        local b = string.byte(c)
        if b < 32 then
            return string.format('\\u%04x', b)
        end
        return c
    end)
    return s
end

return M
