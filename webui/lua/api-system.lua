-- api-system.lua: system endpoint handlers for keenetic-entware-extras WebUI.
-- Provides /api/system/info, /api/system/interfaces, /api/system/clients.
-- Compatible with LuaJIT (nginx-mod-lua / OpenResty).

local utils = require("api-utils")

local read_file = utils.read_file
local run_cmd = utils.run_cmd
local json_escape = utils.json_escape
local cache = utils.cache

local M = {}

-- ── Per-worker cached hardware info (resolved once, never changes) ────────────
-- Thermal zone: nil = not probed, false = not found, string = path to temp file.
local _thermal_path
-- Pre-built JSON fragment for thermal limits (resolved at probe time).
-- Contains warn/crit/max thresholds + zone type for frontend tooltip.
local _thermal_limits_json = "null"
-- CPU core count: nil = not probed, number = core count.
local _cpu_cores

-- SoC thermal limits from datasheets: {substring, warn, crit, Tj_max}.
-- First match wins (plain substring on lowercased zone type). Order matters.
local THERMAL_SPECS = {
    { "mtktscpu",    85, 100, 105 },  -- MT7621/MT7628/MT7620 MIPS
    { "mt7622",      85, 100, 105 },  -- MT7622BV ARM Cortex-A53
    { "cpu-thermal", 90, 105, 115 },  -- Filogic 830/820 (MT7986/MT7981)
    { "cpu_thermal", 90, 105, 115 },  -- alternative DT naming
    { "cpu-",        85, 100, 110 },  -- Qualcomm IPQ (cpu-0-0-usr etc)
    { "soc",         85, 100, 105 },  -- soc-thermal / soc_thermal
}

--- Scan /sys/class/thermal/ for a CPU/SoC thermal zone.
-- Matches zone type containing "cpu" or "soc", resolves SoC-specific limits.
-- @return string|false — path to temp file, or false if not found
local function resolve_thermal_path()
    for i = 0, 9 do
        local prefix = "/sys/class/thermal/thermal_zone" .. i
        local ztype = io.open(prefix .. "/type", "r")
        if not ztype then break end  -- no more zones
        local tname = ztype:read("*a")
        ztype:close()
        if tname then
            local tl = tname:lower()
            if tl:find("cpu", 1, true) or tl:find("soc", 1, true) then
                local zone_type = tname:gsub("%s+$", "")
                -- Lookup limits: first matching substring wins, else conservative default
                local w, c, m = 70, 85, 100
                for _, spec in ipairs(THERMAL_SPECS) do
                    if tl:find(spec[1], 1, true) then
                        w, c, m = spec[2], spec[3], spec[4]
                        break
                    end
                end
                _thermal_limits_json = '{"warn":' .. w
                    .. ',"crit":' .. c .. ',"max":' .. m
                    .. ',"type":"' .. zone_type .. '"}'
                return prefix .. "/temp"
            end
        end
    end
    return false
end

--- NDM id type → Linux interface name prefix mapping.
-- Deterministic: works even when interface is down (no IP needed).
local NDM_TYPE_TO_PREFIX = {
    Bridge      = "br",
    Wireguard   = "nwg",
    AmneziaWG   = "awg",
    UsbLte      = "lte_br",
    UsbQmi      = "qmi_br",   -- QMI-based LTE modems (Keenetic Hero 4G)
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
                            local prefix = NDM_TYPE_TO_PREFIX[cur_type]
                            local dev_name = prefix .. parent_idx
                            -- WifiStation: on mipsel, actual WISP device is apcli, not wwan.
                            -- Detect by checking if wwan{N} is a slave (master X) of another device.
                            if cur_type == "WifiStation" then
                                local link_info = run_cmd("ip -o link show " .. dev_name .. " 2>/dev/null")
                                if link_info and link_info:find("master ", 1, true) then
                                    -- wwan0 is a QMI modem slave — WISP is actually apcli{idx}
                                    local apcli_name = "apcli" .. parent_idx
                                    local apcli_info = run_cmd("ip -o link show " .. apcli_name .. " 2>/dev/null")
                                    if apcli_info and apcli_info:find("UP", 1, true) then
                                        labels[apcli_name] = lbl
                                    else
                                        labels[dev_name] = lbl  -- fallback: normal assignment
                                    end
                                else
                                    labels[dev_name] = lbl  -- aarch64: wwan IS the WISP device
                                end
                            else
                                labels[dev_name] = lbl
                            end
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
                    local prefix = NDM_TYPE_TO_PREFIX[cur_type]
                    local dev_name = prefix .. parent_idx
                    -- WifiStation: on mipsel, actual WISP device is apcli, not wwan.
                    if cur_type == "WifiStation" then
                        local link_info = run_cmd("ip -o link show " .. dev_name .. " 2>/dev/null")
                        if link_info and link_info:find("master ", 1, true) then
                            local apcli_name = "apcli" .. parent_idx
                            local apcli_info = run_cmd("ip -o link show " .. apcli_name .. " 2>/dev/null")
                            if apcli_info and apcli_info:find("UP", 1, true) then
                                labels[apcli_name] = lbl
                            else
                                labels[dev_name] = lbl
                            end
                        else
                            labels[dev_name] = lbl
                        end
                    else
                        labels[dev_name] = lbl
                    end
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

--- Build /api/system/info response purely in Lua (no shell JSON construction).
-- @return string — JSON
function M.info()
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

    -- CPU load average from /proc/loadavg (kept for tooltip, not for bar)
    local load1 = "0"
    local load5 = "0"
    local loadavg = read_file("/proc/loadavg")
    if loadavg then
        local l1, l5 = loadavg:match("^([%d%.]+)%s+([%d%.]+)")
        if l1 then load1 = l1; load5 = l5 end
    end

    -- CPU core count (cached per worker — never changes at runtime)
    if not _cpu_cores then
        _cpu_cores = 1
        local cpuinfo = read_file("/proc/cpuinfo")
        if cpuinfo then
            local count = 0
            for _ in cpuinfo:gmatch("processor%s*:") do count = count + 1 end
            if count > 0 then _cpu_cores = count end
        end
    end
    local cpu_cores = _cpu_cores

    -- Actual CPU utilization from /proc/stat delta.
    -- Load average includes I/O-waiting processes (USB, DNS, network) and
    -- grossly overstates CPU on embedded SoCs (e.g. 57% shown vs 7% real on
    -- Peak KN-2710).  /proc/stat cpu ticks are what top/htop use.
    -- Previous snapshot stored in lua_shared_dict; first poll returns -1.
    local cpu_pct = -1
    local stat_line = read_file("/proc/stat")
    if stat_line then
        local u, n, s, idle, iow, irq, sirq, st =
            stat_line:match("^cpu%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
        if u then
            u = tonumber(u);  n = tonumber(n);  s = tonumber(s)
            idle = tonumber(idle); iow = tonumber(iow); irq = tonumber(irq)
            sirq = tonumber(sirq); st = tonumber(st)

            local total = u + n + s + idle + iow + irq + sirq + st
            local busy  = u + n + s + irq + sirq + st

            local pt = tonumber(cache:get("cpu::prev_total")) or 0
            local pb = tonumber(cache:get("cpu::prev_busy"))  or 0

            local dt = total - pt
            local db = busy  - pb

            if pt > 0 and dt > 0 then
                cpu_pct = math.floor(db / dt * 100 + 0.5)
                if cpu_pct < 0   then cpu_pct = 0   end
                if cpu_pct > 100 then cpu_pct = 100 end
            end

            cache:set("cpu::prev_total", tostring(total))
            cache:set("cpu::prev_busy",  tostring(busy))
        end
    end

    -- CPU temperature from thermal zone (path + limits resolved once per worker).
    -- Returns integer °C or JSON null if no CPU thermal zone on this SoC.
    local cpu_temp_json = "null"
    if _thermal_path == nil then
        _thermal_path = resolve_thermal_path()
    end
    if _thermal_path then
        local raw = read_file(_thermal_path)
        if raw then
            local md = tonumber(raw:match("(%d+)"))
            if md then cpu_temp_json = tostring(math.floor(md / 1000)) end
        end
    end

    return '{"ok":true,'
        .. '"hostname":"' .. json_escape(hostname) .. '",'
        .. '"uptime":"' .. json_escape(uptime_str) .. '",'
        .. '"cpu_load":{"load1":' .. load1 .. ',"load5":' .. load5
        .. ',"cores":' .. cpu_cores .. ',"cpu_pct":' .. cpu_pct .. '},'
        .. '"cpu_temp":' .. cpu_temp_json .. ',"cpu_temp_limits":' .. _thermal_limits_json .. ','
        .. '"memory":{"total_kb":' .. mem_total .. ',"available_kb":' .. mem_available .. '},'
        .. '"disk_opt":{"total_kb":' .. disk_total .. ',"used_kb":' .. disk_used .. ',"free_kb":' .. disk_free .. '}'
        .. '}'
end

--- List network interfaces with UP/DOWN state and human labels.
-- Enriched with descriptions from Keenetic NDM (matched by IP address).
-- Uses exclusion list to skip infrastructure interfaces (tunnels, radios, VLANs).
-- @return string — JSON array of {name, up, label?}
function M.interfaces()
    local output, _, _ = run_cmd("ip -o link show 2>/dev/null")
    local labels = get_iface_labels()

    local items = {}
    for line in output:gmatch("[^\n]+") do
        local name = line:match(":%s+([^:@]+)")
        if name then
            name = name:gsub("%s+$", "")
            -- Exclude: loopback, kernel tunnels, radios, VLAN sub-ifaces, infra
            local excluded = (
                name == "lo" or
                name:match("^tunl") or name:match("^ip6tnl") or
                name:match("^sit") or name:match("^gre") or
                name:match("^ethoip") or name:match("^dummy") or
                name:match("^ezcfg") or name:match("^ifb") or
                name:match("^ra%d") or name:match("^rai%d") or
                name:match("^rax%d") or
                name:match("^xfrm") or
                name:match("%.%d+$")          -- VLAN sub-interfaces (eth2.1, ra7.1)
            )
            -- Physical/radio ifaces: include only if NDM resolved a label
            -- (eth*=IPoE WAN, usb*=tethering, wwan*=WISP)
            if not excluded and not labels[name] and (
                name:match("^eth%d+$") or
                name:match("^usb%d") or
                name:match("^wwan%d") or
                name:match("^apcli%d")   -- WISP radio: show only if labeled
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

--- List registered clients with their routing policy (fwmark → tunnel dev).
-- Joins data from: ndmc hotspot (name/mac/ip), iptables mangle (mac→mark),
-- ip rule (mark→table), ip route (table→dev).
-- @return string — JSON {ok, clients: [{name, mac, ip?, mark?, dev?}]}
function M.clients()
    local labels = get_iface_labels()

    -- 1) MAC → fwmark mapping AND MAC → policy type from iptables mangle HOTSPOT chain
    --    Tunnel policy: "-j MARK --set-xmark 0xffff..." (tunnel fwmark)
    --    Default policy: "CONNNDMMARK --set-xmark" (NDM connection priority)
    --    Segment default (conform): only "-j RETURN" (no MARK, no CONNNDMMARK)
    local chain_out, _, _ = run_cmd(
        "iptables -t mangle -S _NDM_HOTSPOT_PREROUTING_MANGL 2>/dev/null")
    local mac_to_mark = {}
    local mac_has_connndm = {}
    local mac_has_return = {}
    for line in chain_out:gmatch("[^\n]+") do
        -- Tunnel mark: "-j MARK --set-xmark 0xffff..."
        local mac_tun, mark = line:match("%-%-mac%-source%s+(%S+).-%s+%-j%s+MARK%s+%-%-set%-xmark%s+(0xffff%x+)")
        if mac_tun and mark then
            mac_to_mark[mac_tun:upper()] = mark
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

return M
