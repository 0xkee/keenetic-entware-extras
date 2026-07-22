// config-editor.js — Config Editor modal dialog for Entware Extras WebUI.
// Extracted from app.js for maintainability.
// Depends on: shared.js (EW namespace), app.js (refreshAll).
"use strict";

// ── Config Editor (Modal Dialog) ─────────────────────────────────────────────

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
        { key: 'OTHER_DNS_PROVIDER', label: 'Other DNS Provider', type: 'multi_select',
          dynamicOptions: 'other',
          hint: 'Upstream DNS for default group',
          desc: 'DNS provider(s) for international/default group. Select one or more. Resolves all non-zone domains.' },
        { key: 'ZONE_DNS_INTERFACE', label: 'Zone Tunnel Interface', type: 'iface_select', multi: false, hint: 'Default = ISP direct',
          desc: 'Outgoing interface for zone DNS (Yandex/AdGuard). Default = ISP direct. Usually unchanged — MITM does not affect.' },
        { key: 'OTHER_DNS_INTERFACES', label: 'International Tunnel Interfaces', type: 'iface_select', hint: 'Default = ISP direct',
          desc: 'Outgoing interfaces for international DNS. When set, DNS goes through encrypted tunnel (DPI protection).' },
        { key: 'SMARTDNS_PORT', label: 'SmartDNS Port', type: 'number', min: 1, max: 65535, hint: 'Listen port (default 6053)',
          desc: 'SmartDNS listen port (main, used for DNS tests).' }
    ],
    'smartdns-redirect': [
        { key: 'UPSTREAM_PORT', label: 'Upstream Port', type: 'number', min: 1, max: 65535, hint: 'SmartDNS=6053, AGH=5353, Unbound=5335',
          desc: 'Port to redirect DNS traffic to (local DNS on router).' },
        { key: 'INTERFACES', label: 'Interfaces', type: 'iface_select', hint: 'LAN interfaces to intercept DNS on',
          desc: 'Interfaces to intercept (space-separated). Typical: "br0" for LAN. Add "br1" for Guest VLAN.' },
        { key: 'ENABLE_IPV6', label: 'IPv6 Redirect', type: 'toggle', hint: 'Experimental',
          desc: 'Enable IPv6 redirect (ip6tables). Experimental feature.' },
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

/** Cached defaults for comparison (populated on first load). */
var configDefaults = {};

/**
 * Open config editor modal for a service.
 * @param {string} svcId - service id
 */
function toggleConfigEditor(svcId) {
    var schema = CONFIG_SCHEMAS[svcId];
    if (!schema) return;
    openConfigModal(svcId);
}

/**
 * Create and show modal dialog with loading spinner, then load data.
 * @param {string} svcId
 */
function openConfigModal(svcId) {
    // Remove any existing modal
    closeConfigModal();

    var label = CONFIG_LABELS[svcId] || svcId;
    var backdrop = document.createElement('div');
    backdrop.className = 'ew-modal-backdrop';
    backdrop.id = 'config-modal';
    backdrop.innerHTML =
        '<div class="ew-modal">' +
            '<div class="ew-modal__header">' +
                '<h2 class="ew-modal__title"><span style="display:inline-block;transform:scaleX(-1)">\u270f\ufe0f</span> ' + EW.escapeHtml(label) + ' Settings</h2>' +
                '<button class="ew-modal__close" data-modal-close>&times;</button>' +
            '</div>' +
            '<div class="ew-modal__body" id="modal-body">' +
                '<div class="ew-modal__spinner"><div class="ew-spinner"></div></div>' +
            '</div>' +
            '<div class="ew-modal__footer" id="modal-footer" style="display:none">' +
                '<button class="ndw-button ndw-button--toggle ndw-button--small ew-modal__reset-all" data-reset-all="' + svcId + '">Reset All</button>' +
                '<span class="ew-modal__footer-spacer"></span>' +
                '<button class="ndw-button ndw-button--toggle ndw-button--small" data-modal-close>Cancel</button>' +
                '<button class="ndw-button ndw-button--toggle ndw-button--toggle-enabled ndw-button--small" data-save-config="' + svcId + '">Save & Restart</button>' +
            '</div>' +
        '</div>';

    document.body.appendChild(backdrop);

    // Close on backdrop click
    backdrop.addEventListener('click', function(e) {
        if (e.target === backdrop) closeConfigModal();
    });

    // Close on Escape key
    document.addEventListener('keydown', modalEscHandler);

    // Load data
    loadConfigModal(svcId);
}

/** Close modal on Escape. */
function modalEscHandler(e) {
    if (e.key !== 'Escape') return;
    // If any dropdown panel is open, close it instead of the modal
    var modal = document.getElementById('config-modal');
    if (modal) {
        var openPanels = modal.querySelectorAll('.ew-modal__iface-select-panel:not(.ew-hidden)');
        if (openPanels.length > 0) {
            for (var i = 0; i < openPanels.length; i++) {
                openPanels[i].classList.add('ew-hidden');
            }
            e.stopPropagation();
            return;
        }
    }
    closeConfigModal();
}

/** Remove config modal from DOM. */
function closeConfigModal() {
    var existing = document.getElementById('config-modal');
    if (existing) existing.remove();
    document.removeEventListener('keydown', modalEscHandler);
}

/**
 * Load config + interfaces and render form inside modal body.
 * @param {string} svcId
 */
function loadConfigModal(svcId) {
    var body = document.getElementById('modal-body');
    var footer = document.getElementById('modal-footer');
    if (!body) return;

    var schema = CONFIG_SCHEMAS[svcId];
    var configPromise = fetch('/api/' + svcId + '/config').then(function(r) { return r.json(); });
    var ifacesPromise = fetch('/api/system/interfaces').then(function(r) { return r.json(); });
    // Fetch zone data for services with zone_selector fields (smartdns + geo-split)
    var zonesPromise = (svcId === 'smartdns' || svcId === 'geo-split')
        ? fetch('/api/system/zones').then(function(r) { return r.json(); })
        : Promise.resolve(null);
    // Fetch DNS providers list dynamically (smartdns config editor)
    var providersPromise = (svcId === 'smartdns')
        ? fetch('/api/system/dns-providers').then(function(r) { return r.json(); })
        : Promise.resolve(null);

    Promise.all([configPromise, ifacesPromise, zonesPromise, providersPromise])
        .then(function(results) {
            var configData = results[0];
            var ifacesData = results[1];
            var zonesData = results[2];
            var providersData = results[3];

            if (!configData.ok) {
                body.innerHTML = '<div class="ew-editor-msg ew-editor-msg--error">Failed: ' + EW.escapeHtml(configData.error || 'unknown') + '</div>';
                return;
            }

            // Cache defaults for reset and diff-save
            configDefaults[svcId] = configData.defaults || {};

            renderModalForm(body, svcId, schema, configData.config, configData.defaults || {}, ifacesData.interfaces || [], zonesData, providersData);
            if (footer) footer.style.display = '';
        })
        .catch(function(err) {
            body.innerHTML = '<div class="ew-editor-msg ew-editor-msg--error">Error: ' + EW.escapeHtml(err.message) + '</div>';
        });
}

/**
 * Render a unified dropdown component (single-select or multi-select).
 * Handles search bar, grouped options, pre-items with dot indicators.
 * @param {Object} opts
 * @param {string} opts.mode - 'single' (radio) or 'multi' (checkbox)
 * @param {string} opts.configKey - data-config-key attribute value
 * @param {string} opts.displayText - text shown in the trigger button
 * @param {Array} opts.options - [{value, label, desc?}] flat options
 * @param {Array} [opts.groups] - [{group, items:[{value, label, desc?}]}] grouped options (overrides opts.options)
 * @param {Array} [opts.preItems] - [{value, label}] special items before main list (with dot indicator)
 * @param {string} [opts.radioName] - name attribute for radio inputs (required for single mode)
 * @param {string|Array} [opts.selected] - current value(s): string for single, array for multi
 * @param {boolean} [opts.dots] - show up/down dot indicators on options
 * @param {Array} [opts.ifaces] - [{name, label?, up}] interface data (when dots=true)
 * @returns {string} HTML string
 */
function renderDropdown(opts) {
    var mode = opts.mode || 'single';
    var isMulti = (mode === 'multi');
    var selected = opts.selected || (isMulti ? [] : '');
    var selArray = isMulti ? (Array.isArray(selected) ? selected : String(selected).split(/\s+/).filter(Boolean)) : [];
    var selVal = isMulti ? '' : String(selected);
    var displayText = opts.displayText || (isMulti ? (selArray.length ? selArray.join(', ') : 'None') : selVal);

    var html = '';
    // Container
    var keyAttr = opts.configKey ? ' data-config-key="' + EW.escapeHtml(opts.configKey) + '"' : '';
    if (isMulti) {
        html += '<div class="ew-modal__iface-select"' + keyAttr + ' data-selection-order="' + EW.escapeHtml(selArray.join(' ')) + '">';
    } else {
        html += '<div class="ew-modal__iface-select"' + keyAttr + '>';
    }
    // Trigger button
    html += '<button type="button" class="ew-modal__iface-select-trigger">' +
        '<span class="ew-modal__iface-select-text">' + EW.escapeHtml(displayText) + '</span>' +
        '<svg class="ew-modal__select-arrow" width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M7 10l5 5 5-5z"/></svg></button>';
    // Panel
    html += '<div class="ew-modal__iface-select-panel ew-hidden">';
    // Search bar (always present)
    html += '<div class="ew-modal__iface-filter-wrap"><input type="text" class="ew-modal__iface-filter" placeholder="Search..." autocomplete="off"><span class="ew-modal__iface-filter-count"></span></div>';

    // Pre-items (special options with dot indicators, e.g. "Default route", "All VPNs")
    if (opts.preItems) {
        for (var pi = 0; pi < opts.preItems.length; pi++) {
            var pre = opts.preItems[pi];
            if (isMulti) {
                var preChk = selArray.indexOf(pre.value) !== -1;
                html += '<label class="ew-modal__iface-select-option">' +
                    '<input type="checkbox" value="' + EW.escapeHtml(pre.value) + '"' + (preChk ? ' checked' : '') + '>' +
                    '<span class="ew-modal__iface-dot ew-modal__iface-dot--up"></span>' +
                    '<span>' + EW.escapeHtml(pre.label) + '</span></label>';
            } else {
                var preRChk = (pre.value === selVal);
                html += '<label class="ew-modal__iface-select-option">' +
                    '<input type="radio" name="' + EW.escapeHtml(opts.radioName || '') + '" value="' + EW.escapeHtml(pre.value) + '"' + (preRChk ? ' checked' : '') + '>' +
                    '<span class="ew-modal__iface-dot ew-modal__iface-dot--up"></span>' +
                    '<span>' + EW.escapeHtml(pre.label) + '</span></label>';
            }
        }
    }

    // Grouped options (for unions)
    if (opts.groups) {
        for (var gi = 0; gi < opts.groups.length; gi++) {
            var grp = opts.groups[gi];
            html += '<div class="ew-modal__iface-select-group">' + EW.escapeHtml(grp.group) + '</div>';
            var items = grp.items || [];
            for (var ui = 0; ui < items.length; ui++) {
                var u = items[ui];
                var uChk = (u.value === selVal);
                html += '<label class="ew-modal__iface-select-option">' +
                    '<input type="radio" name="' + EW.escapeHtml(opts.radioName || '') + '" value="' + EW.escapeHtml(u.value) + '"' + (uChk ? ' checked' : '') + '>' +
                    '<span>' + EW.escapeHtml(u.label) + (u.desc ? ' (' + EW.escapeHtml(u.desc) + ')' : '') + '</span></label>';
            }
        }
    } else {
        // Flat options
        var optionsList = opts.options || [];
        for (var oi = 0; oi < optionsList.length; oi++) {
            var opt = optionsList[oi];
            if (isMulti) {
                var mChk = selArray.indexOf(opt.value) !== -1;
                html += '<label class="ew-modal__iface-select-option">';
                html += '<input type="checkbox" value="' + EW.escapeHtml(opt.value) + '"' + (mChk ? ' checked' : '') + '>';
                if (opts.dots && opts.ifaces) {
                    var ifc = null;
                    for (var ii = 0; ii < opts.ifaces.length; ii++) {
                        if (opts.ifaces[ii].name === opt.value) { ifc = opts.ifaces[ii]; break; }
                    }
                    var dotState = (ifc && ifc.up) ? 'up' : 'down';
                    html += '<span class="ew-modal__iface-dot ew-modal__iface-dot--' + dotState + '"></span>';
                }
                html += '<span>' + EW.escapeHtml(opt.label) + (opt.desc ? ' \u2014 ' + EW.escapeHtml(opt.desc) : '') + '</span></label>';
            } else {
                var sChk = (opt.value === selVal);
                html += '<label class="ew-modal__iface-select-option">' +
                    '<input type="radio" name="' + EW.escapeHtml(opts.radioName || '') + '" value="' + EW.escapeHtml(opt.value) + '"' + (sChk ? ' checked' : '') + '>';
                if (opts.dots && opts.ifaces) {
                    var sIfc = null;
                    for (var si2 = 0; si2 < opts.ifaces.length; si2++) {
                        if (opts.ifaces[si2].name === opt.value) { sIfc = opts.ifaces[si2]; break; }
                    }
                    var sDotState = (sIfc && sIfc.up) ? 'up' : 'down';
                    html += '<span class="ew-modal__iface-dot ew-modal__iface-dot--' + sDotState + '"></span>';
                }
                html += '<span>' + EW.escapeHtml(opt.label) + (opt.desc ? ' \u2014 ' + EW.escapeHtml(opt.desc) : '') + '</span></label>';
            }
        }
    }

    html += '</div></div>';
    return html;
}

/**
 * Render form fields inside modal body.
 * @param {HTMLElement} body
 * @param {string} svcId
 * @param {Array} schema
 * @param {Object} config - current merged values
 * @param {Object} defaults - default values
 * @param {Array} interfaces
 * @param {Object|null} zonesData - zone selector data (for smartdns)
 * @param {Object|null} providersData - DNS providers from /api/system/dns-providers
 */
function renderModalForm(body, svcId, schema, config, defaults, interfaces, zonesData, providersData) {
    var html = '';

    for (var i = 0; i < schema.length; i++) {
        var field = schema[i];
        var val = config[field.key] !== undefined ? config[field.key] : '';
        var defVal = defaults[field.key] !== undefined ? defaults[field.key] : '';
        var isDefault = (String(val) === String(defVal));

        var fieldClass = field.type === 'toggle' ? 'ew-modal__field ew-modal__field--toggle' : 'ew-modal__field';
        html += '<div class="' + fieldClass + '">';

        // Help icon (?) with CSS tooltip — rendered inline right after label
        var helpHtml = '';
        if (field.desc) {
            helpHtml = '<span class="ew-modal__help" data-tooltip="' + EW.escapeHtml(field.desc) + '">?</span>';
        }

        if (field.type === 'toggle') {
            // Toggle: row=[switch, label, help, reset], hint below
            var onVal = field.on || 'yes';
            var checked = (val === onVal || val === true) ? ' checked' : '';
            var toggleId = 'cfg-' + field.key;
            html += '<div class="ew-modal__toggle-row">';
            html += '<label class="ew-toggle ew-modal__toggle">' +
                '<input type="checkbox" id="' + toggleId + '" data-config-key="' + field.key + '" data-on-val="' + EW.escapeHtml(field.on || 'yes') + '"' + checked + '>' +
                '<span class="ew-toggle__bar"></span></label>';
            html += '<label class="ew-modal__label ew-modal__label--clickable" for="' + toggleId + '">' + EW.escapeHtml(field.label) + '</label>';
            html += helpHtml;
            html += '<button class="ew-modal__reset' + (isDefault ? ' ew-modal__reset--default' : '') + '" data-reset-key="' + field.key + '" data-reset-val="' + EW.escapeHtml(String(defVal)) + '" data-tooltip="Reset to default:\n' + EW.escapeHtml(String(defVal)) + '">' +
                '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M12.5 8c-2.65 0-5.05 1.04-6.83 2.73L3 8v8h8l-2.81-2.81C9.59 11.82 10.96 11 12.5 11c2.76 0 5.07 1.75 5.94 4.2l2.37-.78C19.63 10.96 16.35 8 12.5 8z"/></svg>' +
                '</button>';
            html += '</div>';
        } else {
            // Other fields: [header with label + help + reset] then input below
            html += '<div class="ew-modal__field-header">';
            html += '<label class="ew-modal__label">' + EW.escapeHtml(field.label) + '</label>';
            html += helpHtml;
            html += '<button class="ew-modal__reset' + (isDefault ? ' ew-modal__reset--default' : '') + '" data-reset-key="' + field.key + '" data-reset-val="' + EW.escapeHtml(String(defVal)) + '" data-tooltip="Reset to default:\n' + EW.escapeHtml(String(defVal)) + '">' +
                '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M12.5 8c-2.65 0-5.05 1.04-6.83 2.73L3 8v8h8l-2.81-2.81C9.59 11.82 10.96 11 12.5 11c2.76 0 5.07 1.75 5.94 4.2l2.37-.78C19.63 10.96 16.35 8 12.5 8z"/></svg>' +
                '</button>';
            html += '</div>';
        }

        if (field.type === 'number') {
            html += '<input type="number" class="ew-modal__input" ' +
                'data-config-key="' + field.key + '" ' +
                'value="' + EW.escapeHtml(String(val)) + '" ' +
                (field.min !== undefined ? 'min="' + field.min + '" ' : '') +
                (field.max !== undefined ? 'max="' + field.max + '" ' : '') + '>';
        } else if (field.type === 'text') {
            html += '<input type="text" class="ew-modal__input" ' +
                'data-config-key="' + field.key + '" ' +
                'value="' + EW.escapeHtml(String(val)) + '">';
        } else if (field.type === 'radio_text') {
            // Radio presets + custom text input
            var presets = field.presets || [];
            var isPreset = false;
            html += '<div class="ew-modal__radio-text" data-config-key="' + field.key + '">';
            for (var p = 0; p < presets.length; p++) {
                var pr = presets[p];
                var prChecked = (val === pr.value) ? ' checked' : '';
                if (val === pr.value) isPreset = true;
                html += '<label class="ew-modal__radio-item">' +
                    '<input type="radio" name="rt-' + field.key + '" value="' + EW.escapeHtml(pr.value) + '"' + prChecked + '>' +
                    '<span class="ew-modal__radio-label">' + EW.escapeHtml(pr.label) + '</span>' +
                    '</label>';
            }
            var customChecked = !isPreset ? ' checked' : '';
            var customVal = !isPreset ? EW.escapeHtml(String(val)) : '';
            html += '<label class="ew-modal__radio-item ew-modal__radio-item--custom">' +
                '<input type="radio" name="rt-' + field.key + '" value="__custom__"' + customChecked + '>' +
                '<span class="ew-modal__radio-label">IP:</span>' +
                '<input type="text" class="ew-modal__radio-input" placeholder="e.g. 176.65.44.1" value="' + customVal + '"' + (isPreset ? ' disabled' : '') + '>' +
                '</label>';
            html += '</div>';
        } else if (field.type === 'select') {
            // Single-select dropdown (radio buttons)
            var selDisplayText = String(val);
            for (var sd = 0; sd < field.options.length; sd++) {
                if (field.options[sd].value === String(val)) { selDisplayText = field.options[sd].label; break; }
            }
            html += renderDropdown({
                mode: 'single',
                configKey: field.key,
                displayText: selDisplayText,
                radioName: 'sel-' + field.key,
                selected: String(val),
                options: field.options
            });
        } else if (field.type === 'multi_select') {
            // Multi-select dropdown (checkboxes) with dynamic options from API
            var msOptions = field.options || [];
            if (field.dynamicOptions && providersData && providersData[field.dynamicOptions]) {
                msOptions = providersData[field.dynamicOptions];
            }
            html += renderDropdown({
                mode: 'multi',
                configKey: field.key,
                selected: val,
                options: msOptions
            });
        } else if (field.type === 'zone_selector' && zonesData) {
            // Zone selector: wrapper with radio pills + two dropdown panels
            var zones = zonesData.zones || [];
            var unions = zonesData.unions || [];
            var valParts = String(val).split(/\s+/).filter(function(s) { return s; });
            var zoneValues = {};
            for (var zi = 0; zi < zones.length; zi++) { zoneValues[zones[zi].value] = true; }
            var isZone = valParts.length > 0 && valParts.every(function(v) { return zoneValues[v]; });
            var isUnion = !isZone;
            var zsRadioName = 'zs-mode-' + field.key;

            html += '<div class="ew-modal__zone-selector" data-config-key="' + field.key + '">';
            // Radio pills: Zone / Union
            html += '<div class="ew-modal__zone-radio">';
            html += '<label class="ew-modal__radio-item' + (isZone ? ' ew-modal__radio-item--active' : '') + '">' +
                '<input type="radio" name="' + zsRadioName + '" value="zone"' + (isZone ? ' checked' : '') + '>' +
                '<span class="ew-modal__radio-label">Zone</span></label>';
            html += '<label class="ew-modal__radio-item' + (isUnion ? ' ew-modal__radio-item--active' : '') + '">' +
                '<input type="radio" name="' + zsRadioName + '" value="union"' + (isUnion ? ' checked' : '') + '>' +
                '<span class="ew-modal__radio-label">Union</span></label>';
            html += '</div>';

            // Zone panel: multi-select countries
            var selectedZones = isZone ? valParts : [];
            html += '<div class="ew-modal__zone-panel' + (isZone ? '' : ' ew-hidden') + '" data-zone-panel="zone">';
            html += renderDropdown({
                mode: 'multi',
                configKey: '',
                selected: selectedZones,
                options: zones
            });
            html += '</div>';

            // Union panel: single-select grouped unions
            // Pre-compute display text for union
            var unionDisplayText = 'None';
            for (var ugi = 0; ugi < unions.length; ugi++) {
                var uitems = unions[ugi].items || [];
                for (var uii = 0; uii < uitems.length; uii++) {
                    if (uitems[uii].value === val) {
                        unionDisplayText = uitems[uii].label + ' (' + uitems[uii].desc + ')';
                    }
                }
            }
            html += '<div class="ew-modal__zone-panel' + (isUnion ? '' : ' ew-hidden') + '" data-zone-panel="union">';
            html += renderDropdown({
                mode: 'single',
                configKey: '',
                displayText: unionDisplayText,
                radioName: 'zs-union-' + field.key,
                selected: String(val),
                groups: unions
            });
            html += '</div>';
            html += '</div>';
        } else if (field.type === 'iface_select') {
            // Interface selector (sorted: up first, then down, alphabetically)
            var isIfaceMulti = field.multi !== false;
            var sortedIfaces = interfaces.slice().sort(function(a, b) {
                if (a.up !== b.up) return a.up ? -1 : 1;
                return (a.name || '').localeCompare(b.name || '');
            });
            var ifaceOpts = [];
            for (var si = 0; si < sortedIfaces.length; si++) {
                ifaceOpts.push({ value: sortedIfaces[si].name, label: sortedIfaces[si].label || sortedIfaces[si].name });
            }
            if (isIfaceMulti) {
                // Multi-select (checkboxes, space-separated values)
                var selectedIfs = String(val).split(/\s+/).filter(function(s) { return s; });
                var _preMap = {};
                if (field.preItems) { for (var pi = 0; pi < field.preItems.length; pi++) _preMap[field.preItems[pi].value] = field.preItems[pi].label; }
                var ifDisplayText = selectedIfs.length ? selectedIfs.map(function(n) { return _preMap[n] || EW.ifaceLabelFull(n); }).join(', ') : (field.preItems ? field.preItems[0].label : 'Default route');
                html += renderDropdown({
                    mode: 'multi',
                    configKey: field.key,
                    displayText: ifDisplayText,
                    selected: selectedIfs,
                    preItems: field.preItems || [{ value: 'default', label: 'Default route' }],
                    options: ifaceOpts,
                    dots: true,
                    ifaces: sortedIfaces
                });
            } else {
                // Single-select (radio buttons, one value)
                var selIfVal = String(val);
                var singlePreItems = field.preItems || [{ value: '', label: 'Default route' }];
                var ifSingleDisplay = '';
                for (var spi = 0; spi < singlePreItems.length; spi++) {
                    if (singlePreItems[spi].value === selIfVal) { ifSingleDisplay = singlePreItems[spi].label; break; }
                }
                if (!ifSingleDisplay) {
                    ifSingleDisplay = selIfVal ? EW.ifaceLabelFull(selIfVal) : singlePreItems[0].label;
                }
                html += renderDropdown({
                    mode: 'single',
                    configKey: field.key,
                    displayText: ifSingleDisplay,
                    radioName: 'iface-' + field.key,
                    selected: selIfVal,
                    preItems: singlePreItems,
                    options: ifaceOpts,
                    dots: true,
                    ifaces: sortedIfaces
                });
            }
        }

        if (field.hint) {
            html += '<span class="ew-modal__hint">' + EW.escapeHtml(field.hint) + '</span>';
        }
        html += '</div>';
    }

    body.innerHTML = html;
}

/**
 * Collect form data, diff against defaults, POST only changed values.
 * @param {string} svcId
 */
function saveConfig(svcId) {
    var modal = document.getElementById('config-modal');
    if (!modal) return;

    var schema = CONFIG_SCHEMAS[svcId];
    if (!schema) return;

    var defaults = configDefaults[svcId] || {};
    var config = {};
    var hasChanges = false;

    for (var i = 0; i < schema.length; i++) {
        var field = schema[i];
        var val;
        if (field.type === 'toggle') {
            var cb = modal.querySelector('[data-config-key="' + field.key + '"]');
            val = cb && cb.checked ? (field.on || 'yes') : (field.off || 'no');
        } else if (field.type === 'radio_text') {
            var rtContainer = modal.querySelector('[data-config-key="' + field.key + '"]');
            var selRadio = rtContainer ? rtContainer.querySelector('input[type="radio"]:checked') : null;
            if (selRadio && selRadio.value === '__custom__') {
                var txtInput = rtContainer.querySelector('.ew-modal__radio-input');
                val = txtInput ? txtInput.value : '';
            } else {
                val = selRadio ? selRadio.value : '';
            }
        } else if (field.type === 'zone_selector') {
            var zsContainer = modal.querySelector('[data-config-key="' + field.key + '"]');
            if (zsContainer) {
                var zsMode = zsContainer.querySelector('input[name^="zs-mode-"]:checked');
                var panelType = (zsMode && zsMode.value) || 'zone';
                var activePanel = zsContainer.querySelector('[data-zone-panel="' + panelType + '"]');
                if (panelType === 'zone') {
                    // Multi-select zones: collect checked checkboxes
                    var zChecked = activePanel ? activePanel.querySelectorAll('.ew-modal__iface-select-panel input:checked') : [];
                    var zVals = [];
                    for (var zvi = 0; zvi < zChecked.length; zvi++) zVals.push(zChecked[zvi].value);
                    val = zVals.join(' ');
                } else {
                    // Union: single select (radio buttons)
                    var unionRadio = activePanel ? activePanel.querySelector('input[type="radio"]:checked') : null;
                    val = unionRadio ? unionRadio.value : '';
                }
            } else {
                val = '';
            }
        } else if (field.type === 'iface_select') {
            var isContainer = modal.querySelector('[data-config-key="' + field.key + '"]');
            if (field.multi === false) {
                // Single-select: read checked radio
                var ifRadio = isContainer ? isContainer.querySelector('input[type="radio"]:checked') : null;
                val = ifRadio ? ifRadio.value : '';
            } else {
                val = isContainer ? (isContainer.dataset.selectionOrder || '') : '';
            }
        } else if (field.type === 'select') {
            // Custom dropdown with radio buttons (single-select)
            var selContainer = modal.querySelector('[data-config-key="' + field.key + '"]');
            var selRadio = selContainer ? selContainer.querySelector('input[type="radio"]:checked') : null;
            val = selRadio ? selRadio.value : '';
        } else if (field.type === 'multi_select') {
            // Custom dropdown with checkboxes (multi-select) — preserves selection order
            var msContainer = modal.querySelector('[data-config-key="' + field.key + '"]');
            val = msContainer ? (msContainer.dataset.selectionOrder || '') : '';
        } else {
            var input = modal.querySelector('[data-config-key="' + field.key + '"]');
            val = input ? input.value : '';
        }
        // Only include if different from default
        if (String(val) !== String(defaults[field.key] || '')) {
            config[field.key] = val;
            hasChanges = true;
        }
    }

    var saveBtn = modal.querySelector('[data-save-config]');
    var statusEl = modal.querySelector('.ew-modal__status');
    if (!statusEl) {
        // Add status span next to save button
        var footer = document.getElementById('modal-footer');
        if (footer) {
            var span = document.createElement('span');
            span.className = 'ew-modal__status';
            footer.appendChild(span);
            statusEl = span;
        }
    }

    if (saveBtn) saveBtn.disabled = true;
    if (statusEl) { statusEl.textContent = 'Saving...'; statusEl.className = 'ew-modal__status'; }

    fetch('/api/' + svcId + '/config', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(config)
    })
    .then(function(r) { return r.json(); })
    .then(function(data) {
        if (saveBtn) saveBtn.disabled = false;
        if (data.ok) {
            // webui self-restart: keep modal open, poll until back online
            if (data.output === 'restarting') {
                if (statusEl) {
                    statusEl.textContent = 'Restarting...';
                    statusEl.className = 'ew-modal__status';
                }
                if (saveBtn) saveBtn.disabled = true;
                var pollTimer = setInterval(function() {
                    fetch('/api/' + svcId + '/status', { signal: AbortSignal.timeout(2000) })
                        .then(function(r) { return r.json(); })
                        .then(function() {
                            clearInterval(pollTimer);
                            if (statusEl) {
                                statusEl.textContent = '\u2713 Restarted';
                                statusEl.className = 'ew-modal__status ew-modal__status--ok';
                            }
                            setTimeout(function() {
                                closeConfigModal();
                                fetchStatus('/api/' + svcId + '/status', svcId, true);
                            }, 800);
                        })
                        .catch(function() { /* still restarting, keep polling */ });
                }, 1500);
                return;
            }
            if (statusEl) {
                statusEl.textContent = '\u2713 Saved';
                statusEl.className = 'ew-modal__status ew-modal__status--ok';
            }
            setTimeout(function() {
                closeConfigModal();
                fetchStatus('/api/' + svcId + '/status', svcId, true);
            }, 1200);
        } else {
            if (statusEl) {
                statusEl.textContent = 'Error: ' + (data.error || 'failed');
                statusEl.className = 'ew-modal__status ew-modal__status--error';
            }
        }
    })
    .catch(function(err) {
        if (saveBtn) saveBtn.disabled = false;
        if (statusEl) {
            statusEl.textContent = err.message;
            statusEl.className = 'ew-modal__status ew-modal__status--error';
        }
    });
}

/**
 * Handle reset button click: restore field to default value.
 * @param {HTMLElement} btn - reset button
 */
function handleResetField(btn) {
    var key = btn.getAttribute('data-reset-key');
    var defVal = btn.getAttribute('data-reset-val');
    var modal = document.getElementById('config-modal');
    if (!modal || !key) return;

    var el = modal.querySelector('[data-config-key="' + key + '"]');
    if (!el) return;

    if (el.type === 'checkbox') {
        var onVal = el.getAttribute('data-on-val') || 'yes';
        el.checked = (defVal === onVal);
    } else if (el.tagName === 'DIV' && el.classList.contains('ew-modal__radio-text')) {
        // Radio + text (presets)
        var rtRadios = el.querySelectorAll('input[type="radio"]');
        var rtInput = el.querySelector('.ew-modal__radio-input');
        var isPresetVal = false;
        for (var i = 0; i < rtRadios.length; i++) {
            if (rtRadios[i].value !== '__custom__' && rtRadios[i].value === defVal) {
                rtRadios[i].checked = true;
                isPresetVal = true;
            } else if (rtRadios[i].value === '__custom__' && !isPresetVal) {
                // Will be handled after loop
            } else {
                rtRadios[i].checked = false;
            }
        }
        if (!isPresetVal) {
            var customRadio = el.querySelector('input[value="__custom__"]');
            if (customRadio) customRadio.checked = true;
            if (rtInput) { rtInput.value = defVal; rtInput.disabled = false; }
        } else {
            if (rtInput) { rtInput.value = ''; rtInput.disabled = true; }
        }
    } else if (el.tagName === 'DIV' && el.classList.contains('ew-modal__zone-selector')) {
        // Zone selector: find which panel has the default value, switch to it
        var zsPanels = el.querySelectorAll('[data-zone-panel]');
        var zsRadios = el.querySelectorAll('input[name^="zs-mode-"]');
        var found = false;
        for (var pi = 0; pi < zsPanels.length; pi++) {
            // Check union panel (radio buttons)
            var unionRadios = zsPanels[pi].querySelectorAll('input[type="radio"][name^="zs-union-"]');
            for (var uri = 0; uri < unionRadios.length; uri++) {
                if (unionRadios[uri].value === defVal) {
                    unionRadios[uri].checked = true;
                    // Update trigger text
                    var uLabel = unionRadios[uri].closest('.ew-modal__iface-select-option');
                    var uTrigger = zsPanels[pi].querySelector('.ew-modal__iface-select-text');
                    if (uTrigger && uLabel) uTrigger.textContent = uLabel.textContent.trim();
                    // Show this panel, hide others
                    var panelType = zsPanels[pi].getAttribute('data-zone-panel');
                    for (var r = 0; r < zsRadios.length; r++) {
                        zsRadios[r].checked = (zsRadios[r].value === panelType);
                    }
                    for (var q = 0; q < zsPanels.length; q++) {
                        zsPanels[q].classList.toggle('ew-hidden', zsPanels[q] !== zsPanels[pi]);
                    }
                    found = true;
                    break;
                }
            }
            if (found) break;
            // Check zone panel (checkboxes) — defVal is space-separated zone codes
            var zoneCheckboxes = zsPanels[pi].querySelectorAll('.ew-modal__iface-select-panel input[type="checkbox"]');
            if (zoneCheckboxes.length > 0) {
                var defZones = defVal ? defVal.split(/\s+/) : [];
                var anyMatch = defZones.length > 0 && defZones.every(function(dz) {
                    for (var ci = 0; ci < zoneCheckboxes.length; ci++) {
                        if (zoneCheckboxes[ci].value === dz) return true;
                    }
                    return false;
                });
                if (anyMatch) {
                    for (var ci2 = 0; ci2 < zoneCheckboxes.length; ci2++) {
                        zoneCheckboxes[ci2].checked = defZones.indexOf(zoneCheckboxes[ci2].value) !== -1;
                    }
                    var zTrigger = zsPanels[pi].querySelector('.ew-modal__iface-select-text');
                    if (zTrigger) zTrigger.textContent = defZones.length ? defZones.join(', ') : 'None';
                    var panelType2 = zsPanels[pi].getAttribute('data-zone-panel');
                    for (var r2 = 0; r2 < zsRadios.length; r2++) {
                        zsRadios[r2].checked = (zsRadios[r2].value === panelType2);
                    }
                    for (var q2 = 0; q2 < zsPanels.length; q2++) {
                        zsPanels[q2].classList.toggle('ew-hidden', zsPanels[q2] !== zsPanels[pi]);
                    }
                    found = true;
                }
            }
            if (found) break;
        }
    } else if (el.tagName === 'DIV' && el.classList.contains('ew-modal__iface-select')) {
        var radios = el.querySelectorAll('.ew-modal__iface-select-panel input[type="radio"]');
        if (radios.length > 0) {
            // Single-select (select/union type): check matching radio
            for (var ri = 0; ri < radios.length; ri++) {
                radios[ri].checked = (radios[ri].value === defVal);
            }
            var trigger = el.querySelector('.ew-modal__iface-select-text');
            if (trigger) {
                var checkedLabel = el.querySelector('input[type="radio"]:checked');
                var labelEl = checkedLabel ? checkedLabel.closest('.ew-modal__iface-select-option') : null;
                var spanEls = labelEl ? labelEl.querySelectorAll('span') : [];
                var spanEl = spanEls.length > 0 ? spanEls[spanEls.length - 1] : null;
                trigger.textContent = spanEl ? spanEl.textContent : (defVal || 'Default route');
            }
        } else {
            // Multi-select (iface_select): check/uncheck based on defVal (space-separated)
            var defIfs = defVal ? defVal.split(/\s+/) : [];
            var isBoxes = el.querySelectorAll('.ew-modal__iface-select-panel input[type="checkbox"]');
            for (var i = 0; i < isBoxes.length; i++) {
                isBoxes[i].checked = defIfs.indexOf(isBoxes[i].value) !== -1;
            }
            el.dataset.selectionOrder = defIfs.join(' ');
            var trigger2 = el.querySelector('.ew-modal__iface-select-text');
            if (trigger2) trigger2.textContent = defIfs.length ? defIfs.map(function(n) { return EW.ifaceLabelFull(n); }).join(', ') : 'Default route';
        }
    } else {
        el.value = defVal;
    }
    btn.classList.add('ew-modal__reset--default');
}

/**
 * Reset ALL fields to their default values.
 * @param {string} svcId
 */
function handleResetAll(svcId) {
    var modal = document.getElementById('config-modal');
    if (!modal) return;
    var resetBtns = modal.querySelectorAll('[data-reset-key]');
    for (var i = 0; i < resetBtns.length; i++) {
        handleResetField(resetBtns[i]);
    }
}
