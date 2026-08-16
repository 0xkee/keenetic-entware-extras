-- api-config.lua: config CRUD handlers for keenetic-entware-extras WebUI.
-- Provides read_config / write_config for all registered services.
-- Compatible with LuaJIT (nginx-mod-lua / OpenResty).

local utils = require("api-utils")

local read_file = utils.read_file
local run_cmd = utils.run_cmd
local json_escape = utils.json_escape
local base = utils.base
local shell_env = utils.shell_env

local M = {}

--- Config file registry: service → {defaults, config, restart_cmd, keys}.
local config_registry = {
    ["geo-split"] = {
        defaults = base .. "/geo-split/config/defaults.conf",
        config   = base .. "/geo-split/config/config.conf",
        -- Invalidate merged subnet cache before restart: zone may have changed,
        -- forces re-merge from current GEO_ZONE on next start (local files only, fast).
        restart  = "rm -f " .. base .. "/geo-split-data/lists/merged-subnets.txt; " .. base .. "/geo-split/init.d/S99geo-split restart 2>&1",
        keys     = { "GEO_ZONE", "ROUTE_OUT", "ROUTE_GW", "ROUTE_IN", "SUBNET_URL",
                     "SUBNET_LOADER", "SUBNET_AGGREGATE", "DOMAINS_UPDATE_INTERVAL",
                     "DNS_FULL_RESOLVER_PORT", "MAX_CACHE_AGE", "DOWNLOAD_INTERFACES" }
    },
    ["smartdns"] = {
        defaults = base .. "/smartdns-geo-conf/config/defaults.conf",
        config   = base .. "/smartdns-geo-conf/config/config.conf",
        restart  = "/opt/etc/init.d/S37smartdns-conf restart 2>&1",
        keys     = { "DNS_ZONE", "ZONE_DNS_PROVIDER", "ZONE_DNS_INTERFACE",
                     "OTHER_DNS_PROVIDER", "OTHER_DNS_INTERFACES",
                     "DNS_TRANSPORT" }
    },
    ["smartdns-redirect"] = {
        defaults = base .. "/smartdns-redirect/config/defaults.conf",
        config   = base .. "/smartdns-redirect/config/config.conf",
        restart  = base .. "/smartdns-redirect/init.d/S39smartdns-redirect restart 2>&1",
        keys     = { "UPSTREAM_PORT", "INTERFACES", "REDIRECT_MODE", "WATCHDOG_SERVICE", "PRESERVE_FILTER_PROFILES" }
    },
    ["webui"] = {
        defaults = base .. "/webui/config/defaults.conf",
        config   = base .. "/webui/config/config.conf",
        restart  = "exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- 10>&- 11>&- 12>&- 13>&- 14>&- 15>&-; " .. base .. "/webui/init.d/S80nginx-webui restart >/dev/null 2>&1",
        keys     = { "LISTEN_PORT", "INJECT_SIDEBAR", "DASH_POLL_INTERVAL" }
    }
}

--- Parse shell config file (KEY=VALUE or KEY="VALUE") into table.
-- @param path string — file path
-- @param keys table — allowed keys to extract
-- @return table
local function parse_shell_config(path, keys)
    local result = {}
    local content = read_file(path)
    if not content then return result end

    local allowed = {}
    for _, k in ipairs(keys) do allowed[k] = true end

    for line in content:gmatch("[^\n]+") do
        -- Skip comments and empty lines
        if not line:match("^%s*#") and not line:match("^%s*$") then
            local key, val = line:match("^%s*([A-Z_][A-Z0-9_]*)%s*=%s*(.*)$")
            if key and allowed[key] then
                -- Strip quotes
                val = val:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
                result[key] = val
            end
        end
    end
    return result
end

--- Read merged config (defaults + overrides) for a service.
-- Returns both current (merged) values and raw defaults for reset/diff logic.
-- @param svc_id string
-- @return string — JSON with config + defaults
function M.read(svc_id)
    local reg = config_registry[svc_id]
    if not reg then
        return '{"ok":false,"error":"unknown service"}'
    end

    -- Parse defaults first, then override with config.conf
    local defaults = parse_shell_config(reg.defaults, reg.keys)
    local overrides = parse_shell_config(reg.config, reg.keys)
    local config = {}
    for _, key in ipairs(reg.keys) do
        config[key] = overrides[key] or defaults[key] or ""
    end

    -- Build JSON for config and defaults
    local cfg_items = {}
    local def_items = {}
    for _, key in ipairs(reg.keys) do
        cfg_items[#cfg_items + 1] = '"' .. key .. '":"' .. json_escape(config[key]) .. '"'
        def_items[#def_items + 1] = '"' .. key .. '":"' .. json_escape(defaults[key] or "") .. '"'
    end

    return '{"ok":true,"config":{' .. table.concat(cfg_items, ",") .. '},"defaults":{' .. table.concat(def_items, ",") .. '}}'
end

--- Write config.conf for a service and restart.
-- @param svc_id string
-- @param body string — raw request body (JSON)
-- @return string — JSON response
function M.write(svc_id, body)
    local reg = config_registry[svc_id]
    if not reg then
        return '{"ok":false,"error":"unknown service"}'
    end

    -- Parse JSON body manually (no cjson dependency)
    local values = {}
    for _, key in ipairs(reg.keys) do
        -- Extract "KEY":"VALUE" from JSON
        local pattern = '"' .. key .. '"%s*:%s*"([^"]*)"'
        local val = body:match(pattern)
        if val then
            -- Unescape basic JSON escapes
            val = val:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\\\\", "\\")
            values[key] = val
        end
    end

    -- Generic port validation: any key ending with _PORT must be 0-65535.
    -- 0 is allowed as a sentinel value meaning "auto-detect" (e.g. SMARTDNS_PORT=0).
    for _, key in ipairs(reg.keys) do
        if values[key] and key:match("_PORT$") then
            local port = tonumber(values[key])
            if not port or port < 0 or port > 65535 then
                return '{"ok":false,"error":"invalid ' .. key .. ' (must be 0-65535)"}'
            end
        end
    end

    -- Validate DASH_POLL_INTERVAL (min 1000ms)
    if values.DASH_POLL_INTERVAL then
        local ms = tonumber(values.DASH_POLL_INTERVAL)
        if not ms or ms < 1000 then
            return '{"ok":false,"error":"invalid DASH_POLL_INTERVAL (min 1000ms)"}'
        end
    end

    -- If no values differ from defaults, remove config.conf
    local has_values = false
    for _ in pairs(values) do has_values = true; break end

    if not has_values then
        os.remove(reg.config)
    else
        -- Write config.conf with only non-default overrides
        local lines = {
            "#!/opt/bin/sh",
            "# Auto-generated by WebUI config editor.",
            '# Last modified: ' .. os.date("%Y-%m-%d %H:%M:%S"),
            "# shellcheck disable=SC2034",
            ""
        }
        for _, key in ipairs(reg.keys) do
            if values[key] then
                local v = values[key]
                if v:match("%s") then
                    lines[#lines + 1] = key .. '="' .. v .. '"'
                else
                    lines[#lines + 1] = key .. '=' .. v
                end
            end
        end
        lines[#lines + 1] = ""

        local f = io.open(reg.config, "w")
        if not f then
            return '{"ok":false,"error":"cannot write config file"}'
        end
        f:write(table.concat(lines, "\n"))
        f:close()
    end

    -- Restart service
    -- webui requires deferred restart (background & doesn't work from io.popen in nginx-lua)
    if svc_id == "webui" then
        local restart_cmd = shell_env .. " " .. reg.restart
        ngx.timer.at(1, function()
            os.execute(restart_cmd)
        end)
        return '{"ok":true,"output":"restarting"}'
    end
    local output, ok, _ = run_cmd(reg.restart)
    output = output:gsub("%s+$", "")
    if ok then
        return '{"ok":true,"output":"' .. json_escape(output) .. '"}'
    else
        return '{"ok":true,"restarted":false,"output":"' .. json_escape(output) .. '"}'
    end
end

return M
