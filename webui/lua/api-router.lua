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

    -- CPU load average from /proc/loadavg (1min, 5min, 15min)
    local load1 = "0"
    local load5 = "0"
    local loadavg = read_file("/proc/loadavg")
    if loadavg then
        local l1, l5 = loadavg:match("^([%d%.]+)%s+([%d%.]+)")
        if l1 then load1 = l1; load5 = l5 end
    end

    -- CPU core count from /proc/cpuinfo
    local cpu_cores = 1
    local cpuinfo = read_file("/proc/cpuinfo")
    if cpuinfo then
        local count = 0
        for _ in cpuinfo:gmatch("processor%s*:") do count = count + 1 end
        if count > 0 then cpu_cores = count end
    end

    return '{"ok":true,'
        .. '"hostname":"' .. json_escape(hostname) .. '",'
        .. '"uptime":"' .. json_escape(uptime_str) .. '",'
        .. '"cpu_load":{"load1":' .. load1 .. ',"load5":' .. load5 .. ',"cores":' .. cpu_cores .. '},'
        .. '"memory":{"total_kb":' .. mem_total .. ',"available_kb":' .. mem_available .. '},'
        .. '"disk_opt":{"total_kb":' .. disk_total .. ',"used_kb":' .. disk_used .. ',"free_kb":' .. disk_free .. '}'
        .. '}'
end

--- NDM id type → Linux interface name prefix mapping.
-- Deterministic: works even when interface is down (no IP needed).
local NDM_TYPE_TO_PREFIX = {
    Bridge    = "br",
    Wireguard = "nwg",
    UsbLte    = "lte_br",
    OpenVPN   = "ovpn_br",
}

--- Get interface labels from ndmc.
-- Primary: deterministic id-based mapping (NDM "id: Type<N>" → Linux "prefix<N>").
-- Fallback: IP-address matching for unknown interface types (3rd-party software).
-- @return table — {linux_iface_name = label_string}
local function get_iface_labels()
    local labels = {}

    local ndm_out, _, _ = run_cmd('ndmc -c "show interface" 2>/dev/null')
    if not ndm_out or ndm_out == "" then return labels end

    -- Fallback: Linux IP→iface map (only built if needed)
    local ip_to_linux = nil  -- lazy-init

    local cur_name, cur_id, cur_desc, cur_addr = nil, nil, nil, nil
    for line in ndm_out:gmatch("[^\n]+") do
        local iname = line:match('^Interface, name = "([^"]+)"')
        if iname then
            -- Flush previous block
            if cur_name and cur_id then
                local ntype, idx = cur_id:match("^(%a+)(%d+)$")
                local lbl = cur_desc and cur_desc ~= "" and cur_desc or cur_name
                if ntype and NDM_TYPE_TO_PREFIX[ntype] then
                    -- Primary: deterministic id → linux name
                    labels[NDM_TYPE_TO_PREFIX[ntype] .. idx] = lbl
                elseif cur_addr then
                    -- Fallback: IP-based matching for unknown types
                    if not ip_to_linux then
                        ip_to_linux = {}
                        local ip_out, _, _ = run_cmd("ip -o -4 addr show 2>/dev/null")
                        for ipline in ip_out:gmatch("[^\n]+") do
                            local iface, ip = ipline:match("%d+:%s+(%S+)%s+inet%s+([%d%.]+)")
                            if iface and ip then
                                ip_to_linux[ip] = iface
                            end
                        end
                    end
                    if ip_to_linux[cur_addr] then
                        labels[ip_to_linux[cur_addr]] = lbl
                    end
                end
            end
            cur_name = iname; cur_id = nil; cur_desc = nil; cur_addr = nil
        end
        if not cur_id then
            local id = line:match("^%s+id:%s+(%S+)")
            if id then cur_id = id end
        end
        local desc = line:match("^%s+description:%s+(.+)$")
        if desc then cur_desc = desc:gsub("%s+$", "") end
        local addr = line:match("^%s+address:%s+([%d%.]+)")
        if addr then cur_addr = addr end
    end
    -- Flush last block
    if cur_name and cur_id then
        local ntype, idx = cur_id:match("^(%a+)(%d+)$")
        local lbl = cur_desc and cur_desc ~= "" and cur_desc or cur_name
        if ntype and NDM_TYPE_TO_PREFIX[ntype] then
            labels[NDM_TYPE_TO_PREFIX[ntype] .. idx] = lbl
        elseif cur_addr then
            if not ip_to_linux then
                ip_to_linux = {}
                local ip_out, _, _ = run_cmd("ip -o -4 addr show 2>/dev/null")
                for ipline in ip_out:gmatch("[^\n]+") do
                    local iface, ip = ipline:match("%d+:%s+(%S+)%s+inet%s+([%d%.]+)")
                    if iface and ip then
                        ip_to_linux[ip] = iface
                    end
                end
            end
            if ip_to_linux[cur_addr] then
                labels[ip_to_linux[cur_addr]] = lbl
            end
        end
    end

    return labels
end

--- List network interfaces with UP/DOWN state and human labels.
-- Enriched with descriptions from Keenetic NDM (matched by IP address).
-- @return string — JSON array of {name, up, label?}
local function system_interfaces()
    local output, _, _ = run_cmd("ip -o link show 2>/dev/null")
    local labels = get_iface_labels()

    local items = {}
    for line in output:gmatch("[^\n]+") do
        local name = line:match(":%s+([^:@]+)")
        if name then
            name = name:gsub("%s+$", "")
            if name:match("^br%d") or name:match("^lte_br%d") or
               name:match("^nwg%d") or name:match("^ovpn_") then
                local flags = line:match("<([^>]+)>") or ""
                local is_up = flags:match("UP") and true or false
                local label_json = ""
                if labels[name] then
                    label_json = ',"label":"' .. json_escape(labels[name]) .. '"'
                end
                items[#items + 1] = '{"name":"' .. json_escape(name) .. '","up":' .. tostring(is_up) .. label_json .. '}'
            end
        end
    end

    return '{"ok":true,"interfaces":[' .. table.concat(items, ",") .. ']}'
end

--- Config file registry: service → {defaults, config, restart_cmd, keys}.
local config_registry = {
    ["geo-split"] = {
        defaults = base .. "/geo-split/config/defaults.conf",
        config   = base .. "/geo-split/config/config.conf",
        restart  = base .. "/geo-split/init.d/S99geo-split restart 2>&1",
        keys     = { "ROUTE_OUT", "ROUTE_GW", "ROUTE_IN", "SUBNET_URL", "SUBNET_LOADER",
                     "SUBNET_AGGREGATE", "DOMAINS_UPDATE_INTERVAL", "DNS_FULL_RESOLVER_PORT",
                     "MAX_CACHE_AGE", "DOWNLOAD_INTERFACES" }
    },
    ["smartdns"] = {
        defaults = base .. "/smartdns-conf-ru-split/config/defaults.conf",
        config   = base .. "/smartdns-conf-ru-split/config/config.conf",
        restart  = "/opt/etc/init.d/S38smartdns restart 2>&1",
        keys     = { "SMARTDNS_PORT" }
    },
    ["smartdns-redirect"] = {
        defaults = base .. "/smartdns-redirect/config/defaults.conf",
        config   = base .. "/smartdns-redirect/config/config.conf",
        restart  = base .. "/smartdns-redirect/init.d/S39smartdns-redirect restart 2>&1",
        keys     = { "UPSTREAM_PORT", "INTERFACES", "ENABLE_IPV6", "WATCHDOG_SERVICE", "PRESERVE_FILTER_PROFILES" }
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
local function read_config(svc_id)
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
local function write_config(svc_id, body)
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

    -- Generic port validation: any key ending with _PORT must be 1-65535
    for _, key in ipairs(reg.keys) do
        if values[key] and key:match("_PORT$") then
            local port = tonumber(values[key])
            if not port or port < 1 or port > 65535 then
                return '{"ok":false,"error":"invalid ' .. key .. ' (must be 1-65535)"}'
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

if uri == "/api/system/interfaces" then
    ngx.say(system_interfaces())
    return
end

-- Config endpoints: GET = read, POST = write + restart
local config_match = uri:match("^/api/([%w%-]+)/config$")
if config_match then
    if ngx.req.get_method() == "POST" then
        ngx.req.read_body()
        local body = ngx.req.get_body_data() or ""
        ngx.say(write_config(config_match, body))
    else
        ngx.say(read_config(config_match))
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
