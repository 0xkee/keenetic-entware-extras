// config-schemas.js — Config field definitions (pure data) for Entware Extras WebUI.
// Extracted from config-editor.js for maintainability.
// No dependencies. Referenced by: config-editor.js, app.js (buildUI).
"use strict";

// ── Config Schemas ───────────────────────────────────────────────────────────

/** Config field definitions per service (schema for form rendering). */
var CONFIG_SCHEMAS = {
    'geo-split': [
        { key: 'GEO_ZONE', label: 'GeoIP Zone', type: 'zone_selector',
          desc: 'GeoIP zone for subnet routing: select countries or a geopolitical union (expands to multiple countries). All 240 country zones pre-packaged.' },
        { key: 'ROUTE_IN', label: 'Source Interfaces', type: 'iface_select', hint: 'LAN/tunnel interfaces for policy rules',
          desc: 'Source LAN/tunnel interfaces for ip rule iif (space-separated). Each interface gets its own ip rule \u2192 custom route table.' },
        { key: 'ROUTE_OUT', label: 'Outgoing Interface', type: 'iface_select', multi: false, hint: 'Target outgoing interface for matched GEO traffic',
          preItems: [{ value: 'auto', label: 'Auto (ISP detect)' }],
          desc: '"auto" or empty = detect ISP automatically from default route. Explicit: "lte_br1" (ISP), "nwg0" (tunnel), "ppp0", etc.' },
        { key: 'ROUTE_GW', label: 'Gateway', type: 'radio_text', hint: 'Gateway (nexthop) for routes in geo-split tables',
          presets: [{ value: 'auto', label: 'Auto (from route)' }, { value: 'none', label: 'None (dev-only)' }],
          desc: '"auto" = detect from default route of ROUTE_OUT interface. On point-to-point interfaces (LTE/PPP) auto returns empty \u2192 routes without gateway (correct for those types).' },
        { key: 'SUBNET_LOADER', label: 'Subnet Loader', type: 'select',
          options: [{ value: 'cidr-plain', label: 'CIDR Plain' }, { value: 'ripe-json', label: 'RIPE JSON (requires jq)' }],
          hint: 'Format parser for downloaded list',
          desc: 'Available loaders: cidr-plain (default, one CIDR per line), ripe-json (RIPE stat JSON, requires jq).' },
        { key: 'SUBNET_URL', label: 'Subnet URL Override', type: 'text', hint: 'Empty = use GEO_ZONE (recommended)',
          desc: 'Override URL: if set, ignores GEO_ZONE and downloads this single URL directly. Leave empty to use GEO_ZONE (recommended).' },
        { key: 'SUBNET_AGGREGATE', label: 'Aggregate CIDRs', type: 'toggle', on: '1', off: '0', hint: 'Merge adjacent subnets \u2192 fewer routes',
          desc: 'Aggregate (merge) adjacent/overlapping CIDR subnets after download. Reduces route entries count.' },
        { key: 'DOWNLOAD_INTERFACES', label: 'Download Interfaces', type: 'iface_select', hint: 'Interfaces for subnet/zone downloads',
          preItems: [{ value: 'default', label: 'Default route' }, { value: '*', label: 'All Tunnels (*)' }],
          desc: 'Outgoing interfaces to try for downloads (in order). "default" = system default route. "*" = auto-detect all active tunnel interfaces.' },
        { key: 'DOMAINS_UPDATE_INTERVAL', label: 'Domain Update Interval', type: 'number', min: 0, hint: 'Seconds (0 = disable)',
          desc: 'Controls how often geo-split re-resolves domains and updates routes. Lower = faster reaction to CDN IP changes; higher = fewer DNS queries.' },
        { key: 'DNS_FULL_RESOLVER_PORT', label: 'DNS Resolver Port', type: 'text', hint: 'Empty = auto-detect',
          desc: 'DNS resolver port for full A-record resolution (all IPs, no speed-check). Empty = auto-detect (probe localhost:6153, then :6053, then system resolver).' },
        { key: 'MAX_CACHE_AGE', label: 'Subnet Cache TTL', type: 'number', min: 0, hint: 'Seconds (default 604800 = 7 days)',
          desc: 'Max age of cached subnet list in seconds. After expiry, subnets are re-downloaded on next start/update.' }
    ],
    'smartdns': [
        { key: 'DNS_ZONE', label: 'DNS Zone', type: 'zone_selector',
          desc: 'DNS zone preset: select countries or a geopolitical union (expands to multiple countries).' },
        { key: 'ZONE_DNS_PROVIDER', label: 'Zone DNS Provider', type: 'multi_select',
          dynamicOptions: 'zone',
          hint: 'Upstream DNS for zone group',
          desc: 'DNS provider(s) for zone/regional group. Select one or more. Resolves zone domains (ccTLDs + CDN-optimized services).' },
        { key: 'ZONE_DNS_INTERFACE', label: 'Zone Tunnel Interface', type: 'iface_select', multi: false, hint: 'Default = ISP direct',
          desc: 'Outgoing interface for zone DNS (Yandex/AdGuard). Default = ISP direct. Usually unchanged — MITM does not affect.' },
        { key: 'OTHER_DNS_PROVIDER', label: 'Other DNS Provider', type: 'multi_select',
          dynamicOptions: 'other',
          hint: 'Upstream DNS for default group',
          desc: 'DNS provider(s) for international/default group. Select one or more. Resolves all non-zone domains.' },
        { key: 'OTHER_DNS_INTERFACES', label: 'International Tunnel Interfaces', type: 'iface_select', hint: 'Default = ISP direct',
          desc: 'Outgoing interfaces for international DNS. When set, all DNS goes through tunnel only — no direct fallback (privacy by design).' },
        { key: 'DNS_TRANSPORT', label: 'DNS Transport', type: 'select',
          options: [{ value: 'auto', label: 'Auto (DoT/DoH + UDP fallback)' }, { value: 'strict', label: 'Strict (DoT/DoH only, no UDP)' }],
          hint: 'Upstream DNS encryption policy',
          desc: 'Auto: DoT/DoH preferred with UDP fallback for zone providers (Yandex, AliDNS). Strict: DoT/DoH only — all DNS queries encrypted, no plain UDP. Use Strict when DNS privacy matters (e.g., abroad with non-local ISP).' }
    ],
    'smartdns-redirect': [
        { key: 'UPSTREAM_PORT', label: 'Upstream Port', type: 'number', min: 1, max: 65535, hint: 'SmartDNS=6053, AGH=5353, Unbound=5335',
          desc: 'Port to redirect DNS traffic to (local DNS on router).' },
        { key: 'INTERFACES', label: 'Interfaces', type: 'iface_select', hint: 'LAN interfaces to intercept DNS on',
          desc: 'Interfaces to intercept (space-separated). Typical: "br0" for LAN. Add "br1" for Guest VLAN.' },
        { key: 'REDIRECT_MODE', label: 'Redirect Mode', type: 'select',
          options: [{ value: 'force', label: 'Force (intercept all DNS + block DoT)' }, { value: 'local', label: 'Local (only router-targeted DNS)' }],
          hint: 'Force = full interception | Local = permissive',
          desc: 'Force: intercepts ALL :53 DNS + blocks DoT :853. Clients cannot bypass SmartDNS. Local: intercepts only DNS to router IP. External DNS (8.8.8.8:53) and DoT (:853) pass through. For IoT devices or corporate laptops with hardcoded DNS.' },
        { key: 'WATCHDOG_SERVICE', label: 'Watchdog Service', type: 'text', hint: 'e.g. S38smartdns',
          desc: 'Restart upstream DNS service if unresponsive. Set to service name (e.g., "S38smartdns") or leave empty to disable.' },
        { key: 'PRESERVE_FILTER_PROFILES', label: 'Preserve Filter Profiles', type: 'toggle', hint: 'Not yet implemented',
          desc: 'When enabled: MACs bound via Keenetic parental-control filters are excluded from DNAT.' }
    ],
    'webui': [
        { key: 'LISTEN_PORT', label: 'Listen Port', type: 'number', min: 1, max: 65535, hint: 'Page reloads after save!',
          desc: 'Listen port for nginx-webui. Changing this will make the page reload on the new port.' },
        { key: 'INJECT_SIDEBAR', label: 'Inject Sidebar', type: 'toggle', on: '1', off: '0', hint: 'Stock Keenetic menu patch',
          desc: 'When 1: adds "Entware Extras" group with pages into the stock Keenetic sidebar. When 0: stock sidebar untouched.' },
        { key: 'DASH_POLL_INTERVAL', label: 'Poll Interval', type: 'number', min: 1000, hint: 'Milliseconds',
          desc: 'Dashboard auto-refresh polling interval in milliseconds. Lower = more responsive but more traffic.' }
    ]
};

/** Labels for modal title per service. */
var CONFIG_LABELS = {
    'geo-split': 'Geo-Split',
    'smartdns': 'SmartDNS Geo-Config',
    'smartdns-redirect': 'DNS Redirect',
    'webui': 'WebUI'
};
