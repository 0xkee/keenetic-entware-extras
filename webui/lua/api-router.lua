-- api-router.lua: unified API router for keenetic-entware-extras WebUI.
-- Dispatches /api/* URIs to shell commands, returns JSON responses.
-- Compatible with LuaJIT (nginx-mod-lua / OpenResty).

local uri = ngx.var.uri
local base = "/opt/keenetic-entware-extras"
local shell_env = "export PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin;"

-- ── Status response cache ────────────────────────────────────────────────────
-- Deduplicates concurrent polling from multiple browser tabs.
-- Only one worker runs the script per TTL window; others get cached result.
-- CLI `status.sh --json` is unaffected (called directly, not through nginx).
local cache = ngx.shared.status_cache
local CACHE_TTL = 5       -- default fresh cache lifetime (seconds)
local STALE_TTL = 30      -- stale fallback while script is running (seconds)
local LOCK_TTL = 45       -- max time to hold execution lock (seconds)
local STATIC_TTL = 3600   -- static data cache (zones, unions) — 1 hour
local IFACE_TTL = 60      -- interfaces list — changes rarely (VPN toggle)

-- Per-endpoint TTL overrides: heavy scripts get longer cache to reduce CPU.
-- POST actions (start/stop/config) invalidate cache instantly regardless of TTL.
local ENDPOINT_TTLS = {
    ["/api/geo-split/status"]        = 10,  -- detect_dns_port inside = 2×dig
    ["/api/geo-split/wan-paths"]     = 60,  -- ip rule/route scanning (stable between VPN changes)
    ["/api/smartdns/status"]          = 15,  -- collect_dns_tests_json = N×dig +time=3
    ["/api/smartdns-redirect/status"] = 5,   -- iptables -C (fast)
    ["/api/webui/status"]             = 5,   -- netstat + pidof (fast)
}

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

--- Fetch cached response or run command with deduplication.
-- @param key string — cache key (URI)
-- @param cmd string — shell command to execute on cache miss
-- @return string — JSON output
local function cached_run(key, cmd)
    -- Fast path: fresh cache hit
    local cached = cache:get(key)
    if cached then
        return cached
    end

    -- Try to acquire execution lock (atomic set-if-not-exists)
    local lock_key = key .. "::lock"
    local ok, _ = cache:add(lock_key, true, LOCK_TTL)
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
    local output, _, _ = run_cmd(cmd)
    output = output:gsub("%s+$", "")

    -- Validate JSON (object or array) and cache with per-endpoint TTL
    if output:sub(1, 1) == "{" or output:sub(1, 1) == "[" then
        local ttl = ENDPOINT_TTLS[key] or CACHE_TTL
        cache:set(key, output, ttl)
        cache:set(key .. "::stale", output, STALE_TTL)
    end

    -- Release lock
    cache:delete(lock_key)

    return output
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

    -- Memory from /proc/meminfo.
    -- Uses MemAvailable (kernel estimate of truly allocatable memory) rather than
    -- naive (total - free - buffers - cached). MemAvailable accounts for non-reclaimable
    -- slab (conntrack tables, dentry cache) and page-table overhead — gives realistic
    -- "memory pressure" reading. May show ~15% higher usage than stock Keenetic UI
    -- which uses the naive formula; this is correct: slab memory on routers with heavy
    -- iptables/conntrack cannot be freed and IS genuinely consumed.
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
    Bridge      = "br",
    Wireguard   = "nwg",
    AmneziaWG   = "awg",
    UsbLte      = "lte_br",
    OpenVPN     = "ovpn_br",
    PPPoE       = "ppp",
    PPTP        = "ppp",
    L2TP        = "ppp",
    Ip6in4      = "ppp",
    WifiStation = "wwan",   -- WifiMaster0/WifiStation0 → wwan0 (WISP)
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

    local cur_name, cur_id, cur_desc, cur_addr, cur_type, cur_link = nil, nil, nil, nil, nil, nil
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
                elseif cur_type and NDM_TYPE_TO_PREFIX[cur_type] then
                    -- Compound id (e.g. WifiMaster0/WifiStation0): use type field
                    -- Only active interfaces (link: up) — inactive WISP hidden from UI
                    if cur_link == "up" then
                        local parent_idx = cur_id:match("^%a+(%d+)/")
                        if parent_idx then
                            labels[NDM_TYPE_TO_PREFIX[cur_type] .. parent_idx] = lbl
                        end
                    end
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
            cur_type = nil; cur_link = nil
        end
        if not cur_id then
            local id = line:match("^%s+id:%s+(%S+)")
            if id then cur_id = id end
        end
        local desc = line:match("^%s+description:%s+(.+)$")
        if desc then cur_desc = desc:gsub("%s+$", "") end
        local tp = line:match("^%s+type:%s+(%S+)")
        if tp then cur_type = tp end
        local lk = line:match("^%s+link:%s+(%S+)")
        if lk then cur_link = lk end
        local addr = line:match("^%s+address:%s+([%d%.]+)")
        if addr then cur_addr = addr end
    end
    -- Flush last block
    if cur_name and cur_id then
        local ntype, idx = cur_id:match("^(%a+)(%d+)$")
        local lbl = cur_desc and cur_desc ~= "" and cur_desc or cur_name
        if ntype and NDM_TYPE_TO_PREFIX[ntype] then
            labels[NDM_TYPE_TO_PREFIX[ntype] .. idx] = lbl
        elseif cur_type and NDM_TYPE_TO_PREFIX[cur_type] then
            if cur_link == "up" then
                local parent_idx = cur_id:match("^%a+(%d+)/")
                if parent_idx then
                    labels[NDM_TYPE_TO_PREFIX[cur_type] .. parent_idx] = lbl
                end
            end
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
-- Uses blacklist to exclude infrastructure interfaces (tunnels, radios, VLANs).
-- @return string — JSON array of {name, up, label?}
local function system_interfaces()
    local output, _, _ = run_cmd("ip -o link show 2>/dev/null")
    local labels = get_iface_labels()

    local items = {}
    for line in output:gmatch("[^\n]+") do
        local name = line:match(":%s+([^:@]+)")
        if name then
            name = name:gsub("%s+$", "")
            -- Blacklist: exclude loopback, kernel tunnels, radios, VLAN sub-ifaces, infra
            local excluded = (
                name == "lo" or
                name:match("^tunl") or name:match("^ip6tnl") or
                name:match("^sit") or name:match("^gre") or
                name:match("^ethoip") or name:match("^dummy") or
                name:match("^ezcfg") or name:match("^ifb") or
                name:match("^ra%d") or name:match("^apcli") or
                name:match("%.%d+$")          -- VLAN sub-interfaces (eth2.1, ra7.1)
            )
            -- Physical/radio ifaces: include only if NDM resolved a label
            -- (eth*=IPoE WAN, usb*=tethering, wwan*=WISP)
            if not excluded and not labels[name] and (
                name:match("^eth%d+$") or
                name:match("^usb%d") or
                name:match("^wwan%d")
            ) then
                excluded = true
            end
            if not excluded then
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

--- List registered clients with their routing policy (fwmark → VPN dev).
-- Joins data from: ndmc hotspot (name/mac/ip), iptables mangle (mac→mark),
-- ip rule (mark→table), ip route (table→dev).
-- @return string — JSON {ok, clients: [{name, mac, ip?, mark?, dev?}]}
local function system_clients()
    local labels = get_iface_labels()

    -- 1) MAC → fwmark mapping AND MAC → policy type from iptables mangle HOTSPOT chain
    --    VPN policy: "-j MARK --set-xmark 0xffff..." (VPN fwmark)
    --    Default policy: "CONNNDMMARK --set-xmark" (NDM connection priority)
    --    Segment default (conform): only "-j RETURN" (no MARK, no CONNNDMMARK)
    local chain_out, _, _ = run_cmd(
        "iptables -t mangle -S _NDM_HOTSPOT_PREROUTING_MANGL 2>/dev/null")
    local mac_to_mark = {}
    local mac_has_connndm = {}
    local mac_has_return = {}
    for line in chain_out:gmatch("[^\n]+") do
        -- VPN mark: "-j MARK --set-xmark 0xffff..."
        local mac_vpn, mark = line:match("%-%-mac%-source%s+(%S+).-%s+%-j%s+MARK%s+%-%-set%-xmark%s+(0xffff%x+)")
        if mac_vpn and mark then
            mac_to_mark[mac_vpn:upper()] = mark
        else
            -- NDM connection mark: "CONNNDMMARK --set-xmark"
            local mac_ndm = line:match("%-%-mac%-source%s+(%S+).-%s+CONNNDMMARK")
            if mac_ndm then
                mac_has_connndm[mac_ndm:upper()] = true
            else
                -- Plain RETURN (registered, no special marks)
                local mac_ret = line:match("%-%-mac%-source%s+(%S+).-%s+%-j%s+RETURN")
                if mac_ret then
                    mac_has_return[mac_ret:upper()] = true
                end
            end
        end
    end

    -- 2) fwmark → table mapping from ip rule
    local rule_out, _, _ = run_cmd("ip rule show 2>/dev/null | grep fwmark")
    local mark_to_table = {}
    for line in rule_out:gmatch("[^\n]+") do
        local mark, tbl = line:match("fwmark%s+(0x%x+)%s+lookup%s+(%d+)")
        if mark and tbl then
            mark_to_table[mark] = tbl
        end
    end

    -- 3) table → dev mapping from default routes
    local route_out, _, _ = run_cmd("ip route show table all 2>/dev/null | grep '^default'")
    local table_to_dev = {}
    for line in route_out:gmatch("[^\n]+") do
        local dev, tbl = line:match("dev%s+(%S+)%s+table%s+(%d+)")
        if dev and tbl and not table_to_dev[tbl] then
            table_to_dev[tbl] = dev
        end
    end

    -- 4) Parse ndmc hotspot for client list (name, mac, ip)
    local ndm_out, _, _ = run_cmd('ndmc -c "show ip hotspot" 2>/dev/null')
    local clients = {}
    local cur = {}

    local function flush_client()
        if not cur.mac then return end
        local mac_upper = cur.mac:upper()
        local mark = mac_to_mark[mac_upper]
        local tbl = mark and mark_to_table[mark]
        local dev = tbl and table_to_dev[tbl]
        local name = cur.name and cur.name ~= "" and cur.name or cur.hostname or mac_upper
        local entry = '{"name":' .. '"' .. json_escape(name) .. '"'
            .. ',"mac":"' .. json_escape(mac_upper) .. '"'
        if cur.ip and cur.ip ~= "" then
            entry = entry .. ',"ip":"' .. json_escape(cur.ip) .. '"'
        end
        if mark then
            entry = entry .. ',"mark":"' .. json_escape(mark) .. '"'
        end
        if dev then
            entry = entry .. ',"dev":"' .. json_escape(dev) .. '"'
            if labels[dev] then
                entry = entry .. ',"dev_label":"' .. json_escape(labels[dev]) .. '"'
            end
        end
        -- Segment: NDM Bridge ID → linux bridge (Bridge0→br0, Bridge1→br1)
        if cur.bridge_id then
            local seg_idx = cur.bridge_id:match("^Bridge(%d+)$")
            if seg_idx then
                local seg_dev = "br" .. seg_idx
                entry = entry .. ',"segment":"' .. seg_dev .. '"'
                -- Use description from interface sub-block, fallback to iface labels
                local seg_lbl = cur.seg_desc or labels[seg_dev]
                if seg_lbl and seg_lbl ~= "" then
                    entry = entry .. ',"segment_label":"' .. json_escape(seg_lbl) .. '"'
                end
            end
        end
        -- active: true if ndmc reports "active: yes"
        if cur.active == "yes" then
            entry = entry .. ',"active":true'
        else
            entry = entry .. ',"active":false'
        end
        entry = entry .. '}'
        clients[#clients + 1] = entry
        cur = {}
    end

    for line in ndm_out:gmatch("[^\n]+") do
        if line:match("^%s+host:%s*$") or line:match("^%s*$") then
            flush_client()
        else
            local key, val = line:match("^%s+(%S+):%s+(.+)$")
            if key == "mac" then cur.mac = val
            elseif key == "name" and not cur.name then cur.name = val
            elseif key == "hostname" and not cur.hostname then cur.hostname = val
            elseif key == "ip" and not cur.ip then cur.ip = val
            elseif key == "active" then cur.active = val
            elseif key == "id" and not cur.bridge_id then
                -- Capture Bridge ID from interface sub-block (e.g. "Bridge0")
                if val:match("^Bridge%d+$") then cur.bridge_id = val end
            elseif key == "description" and not cur.seg_desc then
                -- Capture segment description from interface sub-block
                cur.seg_desc = val
            end
        end
    end
    flush_client()

    return '{"ok":true,"clients":[' .. table.concat(clients, ",") .. ']}'
end

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
        keys     = { "DNS_ZONE", "ZONE_DNS_PROVIDER", "OTHER_DNS_PROVIDER",
                     "ZONE_DNS_INTERFACE", "OTHER_DNS_INTERFACES", "SMARTDNS_PORT" }
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

--- Build /api/system/zones response: parse lib/zone-labels.sh + lib/geo.sh.
-- Returns available zone presets (countries) and unions (multi-country groups).
-- Shared endpoint used by both smartdns and geo-split settings.
-- @return string — JSON
local function system_zones()
    local labels_file = base .. "/lib/zones.sh"
    local geo_lib = base .. "/lib/geo.sh"

    -- Parse zone labels file (format: "CC Country Name" per line, # = comment)
    local zones_raw = {}
    local content = read_file(labels_file)
    if content then
        for line in content:gmatch("[^\n]+") do
            if not line:match("^%s*#") and not line:match("^%s*$") then
                local code, label = line:match("^(%a%a)%s+(.+)$")
                if code and label then
                    -- Strip leading flag emoji (non-ASCII + space) for sort key
                    local sort_name = label:match("^%S+%s+(.+)$") or label
                    zones_raw[#zones_raw + 1] = {
                        sort_key = sort_name,
                        json = '{"value":"' .. json_escape(code) ..
                            '","label":"' .. json_escape(label) .. '","desc":""}'
                    }
                end
            end
        end
    end
    -- Sort zones alphabetically by country name
    table.sort(zones_raw, function(a, b) return a.sort_key < b.sort_key end)
    local zones = {}
    for _, z in ipairs(zones_raw) do zones[#zones + 1] = z.json end

    -- Parse lib/geo.sh: # comment before UNION_xxx="countries"
    local unions = {}
    local content = read_file(geo_lib)
    if content then
        local current_group = "Other"
        local prev_comment = ""
        local expect_title = false
        for line in content:gmatch("[^\n]+") do
            -- Pure separator: # ====...==== (no text between equals)
            if line:match("^#%s*=+=+%s*$") then
                -- First separator opens title expectation, second closes it
                if not expect_title then
                    expect_title = true
                else
                    expect_title = false
                end
                prev_comment = ""
            elseif line:match("^#%s+") and not line:match("^#!/") and not line:match("^# shellcheck") then
                local cmt = line:match("^#%s+(.*)")
                if cmt then
                    if expect_title then
                        -- Comment between separators = section title
                        current_group = cmt
                    else
                        prev_comment = cmt
                    end
                end
            else
                -- UNION_xxx="countries"
                local name, countries = line:match('^UNION_([%w_]+)="([^"]*)"')
                if name then
                    -- Extract label from comment: "NAME / ОПИСАНИЕ (expanded)" or just "NAME"
                    local label = prev_comment:match("^(.-)%s*%(") or prev_comment:match("^(.-)%s*$") or name
                    label = label:gsub("%s+$", "")
                    if label == "" then label = name end
                    unions[#unions + 1] = {
                        group = current_group,
                        json = '{"value":"' .. json_escape(name) ..
                            '","label":"' .. json_escape(label) ..
                            '","desc":"' .. json_escape(countries) .. '"}'
                    }
                    prev_comment = ""
                end
            end
        end
    end

    -- Group unions by section
    local groups_order = {}
    local groups_map = {}
    for _, u in ipairs(unions) do
        if not groups_map[u.group] then
            groups_map[u.group] = {}
            groups_order[#groups_order + 1] = u.group
        end
        local g = groups_map[u.group]
        g[#g + 1] = u.json
    end

    local union_groups = {}
    for _, gname in ipairs(groups_order) do
        union_groups[#union_groups + 1] = '{"group":"' .. json_escape(gname) ..
            '","items":[' .. table.concat(groups_map[gname], ",") .. ']}'
    end

    return '{"ok":true,"zones":[' .. table.concat(zones, ",") ..
        '],"unions":[' .. table.concat(union_groups, ",") .. ']}'
end

--- Build /api/system/dns-providers response: parse dns-providers.conf.
-- Extracts provider names and labels from *_LABEL variables.
-- @return string — JSON with "zone" and "other" arrays
local function system_dns_providers()
    local providers_file = base .. "/smartdns-geo-conf/config/dns-providers.conf"
    local custom_file = base .. "/smartdns-geo-conf/config/dns-providers-custom.conf"
    local content = read_file(providers_file)
    if not content then
        return '{"ok":false,"error":"dns-providers.conf not found"}'
    end

    -- Append custom providers (user-defined, preserved on upgrade)
    local custom = read_file(custom_file)
    if custom then
        content = content .. "\n" .. custom
    end

    local zone_items = {}
    local other_items = {}

    -- Parse lines matching: {GROUP}_{name}_LABEL="..."
    -- GROUP = OTHER or ZONE, name = provider key (may contain underscores)
    for line in content:gmatch("[^\n]+") do
        local n, l = line:match('^%s*OTHER_(.+)_LABEL%s*=%s*"([^"]*)"')
        if n then
            other_items[#other_items + 1] = '{"value":"' .. json_escape(n) .. '","label":"' .. json_escape(l) .. '"}'
        else
            n, l = line:match('^%s*ZONE_(.+)_LABEL%s*=%s*"([^"]*)"')
            if n then
                zone_items[#zone_items + 1] = '{"value":"' .. json_escape(n) .. '","label":"' .. json_escape(l) .. '"}'
            end
        end
    end

    return '{"ok":true,"zone":[' .. table.concat(zone_items, ",") ..
        '],"other":[' .. table.concat(other_items, ",") .. ']}'
end

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
}

-- Lua-computed routes: cached JSON endpoints
local lua_routes = {
    ["/api/system/info"]          = { fn = system_info,          ttl = CACHE_TTL },
    ["/api/system/interfaces"]    = { fn = system_interfaces,    ttl = IFACE_TTL },
    ["/api/system/clients"]       = { fn = system_clients,       ttl = IFACE_TTL },
    ["/api/system/zones"]         = { fn = system_zones,         ttl = STATIC_TTL },
    ["/api/system/dns-providers"] = { fn = system_dns_providers, ttl = STATIC_TTL },
}

-- Alias: /api/smartdns/zones → same handler & cache key as /api/system/zones
lua_routes["/api/smartdns/zones"] = { fn = system_zones, ttl = STATIC_TTL, cache_key = "/api/system/zones" }

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
        local result = write_config(config_match, body)
        -- Invalidate status cache (config save triggers restart)
        local status_key = "/api/" .. config_match .. "/status"
        cache:delete(status_key)
        cache:delete(status_key .. "::stale")
        ngx.say(result)
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
    local host = validate_host(args.host)
    if not host then
        ngx.say('{"ok":false,"error":"invalid_input","message":"host parameter required: only [a-zA-Z0-9._-] allowed"}')
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
