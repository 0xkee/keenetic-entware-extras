-- api-data.lua: zone/provider data handlers for keenetic-entware-extras WebUI.
-- Provides /api/system/zones and /api/system/dns-providers.
-- Compatible with LuaJIT (nginx-mod-lua / OpenResty).

local utils = require("api-utils")

local read_file = utils.read_file
local json_escape = utils.json_escape
local base = utils.base

local M = {}

--- Build /api/system/zones response: parse lib/zone-labels.sh + lib/geo.sh.
-- Returns available zone presets (countries) and unions (multi-country groups).
-- Shared endpoint used by both smartdns and geo-split settings.
-- @return string — JSON
function M.zones()
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
    local geo_content = read_file(geo_lib)
    if geo_content then
        local current_group = "Other"
        local prev_comment = ""
        local expect_title = false
        for line in geo_content:gmatch("[^\n]+") do
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
function M.dns_providers()
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

return M
