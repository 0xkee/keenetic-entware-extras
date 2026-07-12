// shared.js — Shared utilities for Entware Extras WebUI.
// Used by both inject.js (stock Keenetic page) and app.js (custom iframe page).
"use strict";

window.EW = (function() {

    /** Service registry — single source of truth for IDs, labels, URLs, API endpoints. */
    var SERVICE_APIS = [
        { id: 'geo-split',         label: 'Geo-Split',       desc: 'Policy-based geographic split routing',      url: '/custom/#geo-split',        api: '/api/geo-split/status' },
        { id: 'smartdns',          label: 'SmartDNS Geo-Config',  desc: 'Geo-zone DNS splitting (configurable zones)', url: '/custom/#smartdns',          api: '/api/smartdns/status' },
        { id: 'smartdns-redirect', label: 'DNS Redirect',     desc: 'Transparent DNS redirect for local networks', url: '/custom/#smartdns-redirect', api: '/api/smartdns-redirect/status' },
        { id: 'webui',             label: 'WebUI',            desc: 'Entware Extras web dashboard',               url: '/custom/#webui',             api: '/api/webui/status' },
    ];

    /** Detail keys whose numeric values are seconds — formatted and live-ticked. */
    var TIMER_KEYS = { subnet_freshness: 1, domain_freshness: 1 };

    /** Updatable detail keys → POST action config.
     *  String values are shorthand for { url: ... , tooltip: 'Force Reload' }.
     *  Object values may override tooltip text. */
    var UPDATE_ACTIONS = {
        'geo_zone':       '/api/geo-split/update-subnets',
        'domain_sources': '/api/geo-split/update-domains',
        'smartdns:cache': { url: '/api/smartdns/flush-cache', tooltip: 'Flush DNS Cache' },
        'webui:cache':    { url: '/api/webui/flush-cache', tooltip: 'Flush UI Cache' }
    };

    /** Detail keys whose string values contain Linux device names.
     *  Used by parseDetails to humanize interface names for UI display.
     *  Types: 'space-list' = space-separated devs,
     *         'single-suffix' = "dev (auto)" or "dev",
     *         'prefixed-lines' = multiline "dev: description",
     *         'gateway' = "via IP" | "scope link" | "none". */
    var IFACE_DETAIL_KEYS = {
        route_in: 'space-list',
        route_out: 'single-suffix',
        other_interfaces: 'space-list',
        interfaces: 'space-list',
        gateway: 'gateway'
    };

    /** Special config keywords that look like device names but aren't.
     *  Mapped to human labels for UI display. */
    var IFACE_SPECIAL = { 'auto': 'Auto (ISP detect)', 'default': 'Default route', 'direct': 'Direct (ISP)', '*': 'All VPNs (*)' };

    /**
     * Eagerly load interface label map from backend.
     * Populates window._ewIfaceMap (dev → human label).
     * Safe to call multiple times — returns cached promise.
     * @returns {Promise}
     */
    var _ifaceMapPromise = null;
    function loadIfaceMap() {
        if (_ifaceMapPromise) return _ifaceMapPromise;
        _ifaceMapPromise = fetch('/api/system/interfaces')
            .then(function(r) { return r.ok ? r.json() : null; })
            .then(function(data) {
                if (data && data.interfaces) {
                    var map = {};
                    for (var i = 0; i < data.interfaces.length; i++) {
                        var ifc = data.interfaces[i];
                        map[ifc.id || ifc.name] = ifc.label || ifc.description || ifc.id || ifc.name || '';
                    }
                    window._ewIfaceMap = map;
                }
                return data;
            }).catch(function() { return null; });
        return _ifaceMapPromise;
    }

    /**
     * Format device name for UI: "Human Label (dev)" when label is known,
     * or just "dev" when no label available. Handles special keywords.
     * @param {string} dev - Linux device name (e.g. "br0", "nwg0")
     * @returns {string}
     */
    function ifaceLabelFull(dev) {
        if (!dev) return '';
        if (IFACE_SPECIAL[dev]) return IFACE_SPECIAL[dev];
        var map = window._ewIfaceMap;
        var label = (map && map[dev]) ? map[dev] : null;
        return label ? label + ' (' + dev + ')' : dev;
    }

    /**
     * Format device name for stock dashboard: human label only, no (dev).
     * @param {string} dev - Linux device name
     * @returns {string}
     */
    function _ifaceLabelShort(dev) {
        if (!dev) return '';
        if (IFACE_SPECIAL[dev]) return IFACE_SPECIAL[dev];
        var map = window._ewIfaceMap;
        return (map && map[dev]) ? map[dev] : dev;
    }

    /**
     * Humanize a space-separated list of device names.
     * Each device on its own line with label.
     * @param {string} val - e.g. "br0 br1"
     * @param {boolean} showDev - include (dev) in output
     * @returns {string} - e.g. "Home network (br0)\nGuest (br1)"
     */
    function _humanizeIfaceList(val, showDev) {
        var fn = showDev ? ifaceLabelFull : _ifaceLabelShort;
        var devs = val.split(/\s+/).filter(function(s) { return s; });
        return devs.map(fn).join('\n');
    }

    /**
     * Humanize route_out value.
     * Custom (showDev=true):  "lte_br1 (auto)" → "Beeline 4G (lte_br1, auto)"
     * Stock  (showDev=false): "lte_br1 (auto)" → "Beeline 4G"
     * @param {string} val - e.g. "lte_br1 (auto)" or "lte_br1" or "detached"
     * @param {boolean} showDev - include (dev) in output
     * @returns {string}
     */
    function _humanizeRouteOut(val, showDev) {
        var suffix = '';
        var core = val;
        var m = val.match(/^(.*?)\s*\(([^)]+)\)$/);
        if (m) {
            core = m[1].trim();
            suffix = m[2].trim();
        }
        if (!core || core === 'detached' || core === '\u2014') return val;
        var fn = showDev ? ifaceLabelFull : _ifaceLabelShort;
        var devs = core.split(/\s+/).filter(Boolean);
        var labeled = devs.map(fn);
        // Single dev with suffix: integrate into brackets or hide
        if (suffix && labeled.length === 1) {
            var lbl = labeled[0];
            if (!showDev) return lbl;
            // Custom: "Beeline 4G (lte_br1, auto)" or "lte_br1 (auto)"
            if (lbl.charAt(lbl.length - 1) === ')') {
                return lbl.slice(0, -1) + ', ' + suffix + ')';
            }
            return lbl + ' (' + suffix + ')';
        }
        // Multiple devs: each on own line, suffix as separate line
        if (suffix && showDev) labeled.push(suffix);
        return labeled.join('\n');
    }

    /**
     * Humanize multiline rules: "br0: #1000 domains" → "Home network (br0): #1000 domains".
     * Preserves leading "!" prefix for error lines.
     * @param {string} val - multiline rules string
     * @param {boolean} showDev - include (dev) in output
     * @returns {string}
     */
    function _humanizeRulesLines(val, showDev) {
        var fn = showDev ? ifaceLabelFull : _ifaceLabelShort;
        return val.split('\n').map(function(line) {
            var prefix = '';
            var rest = line;
            if (rest.charAt(0) === '!') {
                prefix = '!';
                rest = rest.substring(1);
            }
            var colonIdx = rest.indexOf(':');
            if (colonIdx === -1) return line;
            var dev = rest.substring(0, colonIdx).trim();
            var desc = rest.substring(colonIdx);
            return prefix + fn(dev) + desc;
        }).join('\n');
    }

    /**
     * Humanize gateway value.
     * "scope link" → "Direct", "none" → "—".
     * @param {string} val
     * @returns {string}
     */
    function _humanizeGateway(val) {
        if (val === 'scope link') return 'Direct (scope link)';
        if (val === 'none') return '\u2014';
        return val;
    }

    /**
     * Apply interface label humanization to a detail value if its key
     * is in IFACE_DETAIL_KEYS and the iface map is loaded.
     * @param {string} key - detail key
     * @param {*} val - detail value (string expected)
     * @param {boolean} showDev - include (dev) in output (default: true)
     * @returns {*} - humanized value or original
     */
    function _humanizeIfaceDetail(key, val, showDev) {
        var type = IFACE_DETAIL_KEYS[key];
        if (!type || typeof val !== 'string') return val;
        if (type === 'gateway') return _humanizeGateway(val);
        if (!window._ewIfaceMap) return val;
        switch (type) {
            case 'space-list': return _humanizeIfaceList(val, showDev);
            case 'single-suffix': return _humanizeRouteOut(val, showDev);
            case 'prefixed-lines': return _humanizeRulesLines(val, showDev);
            default: return val;
        }
    }

    /**
     * Format seconds as stock Keenetic uptime: "N DAYS HH:MM:SS" or "HH:MM:SS".
     * @param {number} totalSeconds
     * @returns {string}
     */
    function formatUptimeStock(totalSeconds) {
        var days = Math.floor(totalSeconds / 86400);
        var hours = Math.floor((totalSeconds % 86400) / 3600);
        var mins = Math.floor((totalSeconds % 3600) / 60);
        var secs = Math.floor(totalSeconds % 60);
        var hms = ('0' + hours).slice(-2) + ':' +
                  ('0' + mins).slice(-2) + ':' +
                  ('0' + secs).slice(-2);
        if (days > 0) {
            return days + (days === 1 ? ' DAY ' : ' DAYS ') + hms;
        }
        return hms;
    }

    /**
     * Format a snake_case key as Title Case label.
     * @param {string} key
     * @returns {string}
     */
    function formatKey(key) {
        return key.replace(/_/g, ' ').replace(/\b\w/g, function(c) { return c.toUpperCase(); });
    }

    /**
     * Format a boolean value: true → "Ok", false → "Fail".
     * @param {boolean} val
     * @returns {string}
     */
    function formatBool(val) {
        return val ? 'Ok' : 'Fail';
    }

    /**
     * Create a polling timer that can be started and stopped.
     * @param {Function} fetchFn - function to call on each tick
     * @param {number} interval - polling interval in ms
     * @param {Function} [afterStop] - optional cleanup callback after stop
     * @returns {{start: Function, stop: Function, isRunning: Function}}
     */
    function createPoller(fetchFn, interval, afterStop) {
        var timerId = null;
        return {
            start: function() {
                if (timerId) return;
                timerId = setInterval(fetchFn, interval);
            },
            stop: function() {
                if (!timerId) return;
                clearInterval(timerId);
                timerId = null;
                if (afterStop) afterStop();
            },
            isRunning: function() { return timerId !== null; }
        };
    }

    /**
     * Create a 1-second ticker for live uptime counters and freshness fields.
     * Manages baselines internally; calls uptimeCallback(id, currentSeconds, extra)
     * for each tracked service, and updates DOM [data-freshness-key] elements.
     * @param {Function} uptimeCallback - (id, currentSeconds, extra) per service
     * @returns {{start, stop, setUptimeBaseline, removeUptimeBaseline, setFreshnessBaseline, hasBaselines}}
     */
    function createTicker(uptimeCallback) {
        var timerId = null;
        var uptimeBaselines = {};
        var freshnessBaselines = {};

        function tick() {
            var now = Date.now();
            for (var id in uptimeBaselines) {
                var bl = uptimeBaselines[id];
                var elapsed = Math.floor((now - bl.timestamp) / 1000);
                uptimeCallback(id, bl.seconds + elapsed, bl.extra);
            }
            for (var fkey in freshnessBaselines) {
                var fbl = freshnessBaselines[fkey];
                var fcurrent = fbl.seconds + Math.floor((now - fbl.timestamp) / 1000);
                var fEl = document.querySelector('[data-freshness-key="' + fkey + '"]');
                if (fEl) fEl.textContent = formatUptimeStock(fcurrent);
            }
        }

        return {
            start: function() {
                if (timerId) return;
                timerId = setInterval(tick, 1000);
            },
            stop: function() {
                if (timerId) { clearInterval(timerId); timerId = null; }
                uptimeBaselines = {};
                freshnessBaselines = {};
            },
            setUptimeBaseline: function(id, seconds, extra) {
                uptimeBaselines[id] = { seconds: seconds, timestamp: Date.now(), extra: extra };
            },
            removeUptimeBaseline: function(id) {
                delete uptimeBaselines[id];
            },
            setFreshnessBaseline: function(key, seconds) {
                freshnessBaselines[key] = { seconds: seconds, timestamp: Date.now() };
            },
            hasBaselines: function() {
                return Object.keys(uptimeBaselines).length > 0;
            }
        };
    }

    /**
     * Parse detail entries from a status API response into structured objects.
     * Common logic for both inject.js (grid) and app.js (list) rendering.
     * @param {Object} details - data.details from status API
     * @param {Object} [opts]
     * @param {Object} [opts.skipKeys] - keys to skip entirely (default: {uptime:1})
     * @param {boolean} [opts.isRunning] - affects red error highlighting (default: true)
     * @param {boolean} [opts.showDev] - include (dev) in humanized interface labels (default: true)
     * @param {Object} [opts.checks] - checks map from backend (ok/warn/fail per key)
     * @returns {Array<{isSpacer?:boolean, key:string, label:string, value:string,
     *   lines?:Array<{text:string, isError:boolean}>, isError:boolean, isWarning:boolean,
     *   isTimer:boolean, freshnessKey:string|null, updateAction:string|null}>}
     */
    function parseDetails(details, opts) {
        opts = opts || {};
        var skipKeys = opts.skipKeys || { uptime: 1 };
        var isRunning = opts.isRunning !== false;
        var showDev = opts.showDev !== false;
        var checks = opts.checks || null;
        var entries = [];
        var keys = Object.keys(details);

        for (var i = 0; i < keys.length; i++) {
            var key = keys[i];
            if (skipKeys[key]) continue;

            if (key.charAt(0) === '_') {
                entries.push({ isSpacer: true });
                continue;
            }

            var val = details[key];
            if (val === '' || val === null || val === undefined) continue;

            var check = (checks && checks[key]) || null;
            var isError = false;
            var isWarning = false;

            if (typeof val === 'boolean') {
                val = formatBool(val);
            } else if (typeof val === 'number' && val === 0 && TIMER_KEYS[key] && check === 'fail') {
                // Timer key with 0 value and explicit fail → show dash
                val = '\u2014';
            }

            // Humanize interface device names for UI display (e.g. "br0" → "Home network (br0)")
            var rawVal = val;
            val = _humanizeIfaceDetail(key, val, showDev);

            // Determine color: checks takes priority over type-based fallback
            if (check && isRunning) {
                if (check === 'fail') {
                    isError = true;
                } else if (check === 'warn') {
                    isWarning = true;
                }
                // check === 'ok' → no highlight
            } else if (!check) {
                // Fallback: type-based detection (backward compat)
                if (typeof details[key] === 'boolean' && !details[key] && isRunning) {
                    isError = true;
                } else if (typeof details[key] === 'number' && details[key] === 0 && isRunning) {
                    isError = true;
                }
            }

            var isTimer = typeof details[key] === 'number' && !!TIMER_KEYS[key];
            if (isTimer && typeof val === 'number') val = formatUptimeStock(val);

            var strVal = String(val);
            var lines = null;
            if (strVal.indexOf('\n') !== -1) {
                lines = strVal.split('\n').map(function(line) {
                    if (line.charAt(0) === '!') {
                        return { text: line.substring(1), isError: isRunning };
                    }
                    return { text: line, isError: false };
                });
            }

            var actionCfg = (opts.serviceId ? UPDATE_ACTIONS[opts.serviceId + ':' + key] : null) || UPDATE_ACTIONS[key] || null;
            var updateUrl = null;
            var updateTooltip = null;
            if (actionCfg) {
                if (typeof actionCfg === 'string') {
                    updateUrl = actionCfg;
                    updateTooltip = 'Force Reload';
                } else {
                    updateUrl = actionCfg.url;
                    updateTooltip = actionCfg.tooltip || 'Force Reload';
                }
            }

            // Short value for summary mode: human label without (dev), newlines → ", "
            var shortValue = null;
            if (showDev && IFACE_DETAIL_KEYS[key] && typeof rawVal === 'string') {
                var sv = _humanizeIfaceDetail(key, rawVal, false);
                if (sv !== rawVal) shortValue = String(sv).replace(/\n/g, ', ');
            }

            entries.push({
                key: key,
                label: formatKey(key),
                value: strVal,
                shortValue: shortValue,
                lines: lines,
                isError: isError,
                isWarning: isWarning,
                isTimer: isTimer,
                freshnessKey: TIMER_KEYS[key] ? key : null,
                updateAction: updateUrl,
                updateTooltip: updateTooltip
            });
        }
        return entries;
    }

    /**
     * Shorten a hostname to its registrable (2nd-level) domain.
     * E.g. "common.dot.dns.yandex.net" → "yandex.net",
     *      "dns10.quad9.net" → "quad9.net", "dns.google" → "dns.google".
     * @param {string} host
     * @returns {string}
     */
    function shortDomain(host) {
        var parts = host.split('.');
        return parts.length <= 2 ? host : parts.slice(-2).join('.');
    }

    /**
     * Escape HTML special characters for safe insertion into DOM.
     * @param {string} str
     * @returns {string}
     */
    function escapeHtml(str) {
        return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }

    /**
     * Find service definition by ID.
     * @param {string} id - service id (e.g. 'geo-split')
     * @returns {Object|null}
     */
    function getService(id) {
        for (var i = 0; i < SERVICE_APIS.length; i++) {
            if (SERVICE_APIS[i].id === id) return SERVICE_APIS[i];
        }
        return null;
    }

    /**
     * Check if any detail field is boolean false.
     * @param {Object} details - data.details from status API
     * @returns {boolean}
     */
    function hasFailField(details) {
        if (!details) return false;
        var keys = Object.keys(details);
        for (var i = 0; i < keys.length; i++) {
            if (details[keys[i]] === false) return true;
        }
        return false;
    }

    /**
     * Get inline style attribute for error/warning coloring.
     * @param {Object} e - parsed entry from parseDetails
     * @returns {string} style attribute string (includes leading space) or empty
     */
    function detailValueStyle(e) {
        if (e.isError) return ' style="color:var(--error,#f44336)"';
        if (e.isWarning) return ' style="color:var(--status-caution-text,#ffbb57)"';
        return '';
    }

    /**
     * Render detail entry value to HTML.
     * Shared logic between app.js (custom dashboard) and inject.js (stock card).
     * @param {Object} e - parsed entry from parseDetails
     * @param {Object} [opts]
     * @param {Array} [opts.dnsServerChecks] - DNS server check results for provider enrichment
     * @returns {string} value HTML
     */
    function renderDetailValue(e, opts) {
        var checks = (opts && opts.dnsServerChecks) || [];

        // Ok/Fail icons
        if (e.value === 'Ok') {
            return '<span class="ew-bool-icon ew-bool-icon--ok">\u2713</span>';
        }
        if (e.value === 'Fail') {
            return '<span class="ew-bool-icon ew-bool-icon--fail">\u2717</span>';
        }

        // Multiline entries (e.lines from parseDetails)
        if (e.lines) {
            return e.lines.map(function(l) {
                return l.isError ? '<span style="color:var(--error,#f44336)">' + escapeHtml(l.text) + '</span>' : escapeHtml(l.text);
            }).join('<br>');
        }

        // DNS provider enrichment
        if (/_providers?$/.test(e.key) && checks.length) {
            var provLines = e.value.split(' ').map(function(prov) {
                var chk = null;
                for (var ci = 0; ci < checks.length; ci++) {
                    if (checks[ci].provider === prov) { chk = checks[ci]; break; }
                }
                if (chk) {
                    var cIcon = chk.ok ? '\u2713' : '\u2717';
                    var cCls = chk.ok ? 'ew-bool-icon--ok' : 'ew-bool-icon--fail';
                    return '<span class="ew-bool-icon ' + cCls + '">' + cIcon + '</span> ' +
                        '<a class="ew-dns-link" href="https://' + escapeHtml(chk.host) + '" target="_blank" rel="noopener" data-tooltip="' + escapeHtml(chk.host) + '">' +
                        escapeHtml(chk.provider) + '</a>';
                }
                return escapeHtml(prov);
            });
            return '<div class="ew-dns-line">' + provLines.join('</div><div class="ew-dns-line">') + '</div>';
        }

        // Multiline splitting for addresses/ports/providers
        if (e.value.indexOf(' ') !== -1 && !e.isTimer && (e.value.indexOf(':') !== -1 || /_providers?$/.test(e.key))) {
            return e.value.split(' ').map(function(s) { return escapeHtml(s); }).join('<br>');
        }

        return escapeHtml(e.value);
    }

    /**
     * Render update button HTML for an entry.
     * @param {Object} e - parsed entry with updateAction/updateTooltip
     * @returns {string} button HTML or empty string
     */
    function renderUpdateBtn(e) {
        if (!e.updateAction) return '';
        var tooltip = e.updateTooltip || 'Force Reload';
        return ' <button class="ew-update-btn" data-action="' + e.updateAction + '" data-tooltip="' + escapeHtml(tooltip) + '">' +
            '<svg class="ndw-svg-icon svg-restart-dims" style="width:14px;height:14px;fill:currentColor"><use href="/assets/sprite/sprite.svg#restart"></use></svg></button>';
    }

    /**
     * Factory for toggle polling — fast-poll a service API after toggle until state settles.
     * @param {Object} [opts]
     * @param {number} [opts.interval] - poll interval (ms), default 500
     * @param {number} [opts.timeout] - max polling time (ms), default 10000
     * @returns {{start: Function, stop: Function, stopAll: Function, isPolling: Function}}
     */
    function createTogglePoller(opts) {
        var interval = (opts && opts.interval) || 500;
        var timeout = (opts && opts.timeout) || 10000;
        var pollers = {};

        function stop(serviceId) {
            if (pollers[serviceId]) {
                clearInterval(pollers[serviceId]);
                delete pollers[serviceId];
            }
        }

        function stopAll() {
            for (var id in pollers) {
                clearInterval(pollers[id]);
            }
            pollers = {};
        }

        /**
         * Start fast-polling for a service.
         * @param {string} serviceId
         * @param {Function} pollFn - called each tick: pollFn(svc, done). Must call done() when finished.
         */
        function start(serviceId, pollFn) {
            stop(serviceId);
            var svc = getService(serviceId);
            if (!svc) return;
            var startTime = Date.now();
            pollers[serviceId] = setInterval(function() {
                if (Date.now() - startTime > timeout) {
                    stop(serviceId);
                    return;
                }
                pollFn(svc, function() { stop(serviceId); });
            }, interval);
        }

        function isPolling(serviceId) {
            return !!pollers[serviceId];
        }

        return { start: start, stop: stop, stopAll: stopAll, isPolling: isPolling };
    }

    /**
     * Check if a Linux device name is a VPN/tunnel interface.
     * Matches prefixes: nwg, awg, wg, ovpn, l2tp, pptp, sstp, ipsec,
     * tun[0-9], tap, gre, vti, sit, ip6tnl, xfrm.
     * @param {string} dev - Linux device name
     * @returns {boolean}
     */
    function isTunnelIface(dev) {
        if (!dev) return false;
        return /^(nwg|awg|wg|ovpn|l2tp|pptp|sstp|ipsec|tun\d|tap|gre|vti|sit|ip6tnl|xfrm)/.test(dev);
    }

    return {
        SERVICE_APIS: SERVICE_APIS,
        TIMER_KEYS: TIMER_KEYS,
        UPDATE_ACTIONS: UPDATE_ACTIONS,
        loadIfaceMap: loadIfaceMap,
        ifaceLabelFull: ifaceLabelFull,
        ifaceLabelShort: _ifaceLabelShort,
        escapeHtml: escapeHtml,
        getService: getService,
        hasFailField: hasFailField,
        formatUptimeStock: formatUptimeStock,
        formatKey: formatKey,
        formatBool: formatBool,
        createPoller: createPoller,
        createTogglePoller: createTogglePoller,
        createTicker: createTicker,
        parseDetails: parseDetails,
        shortDomain: shortDomain,
        detailValueStyle: detailValueStyle,
        renderDetailValue: renderDetailValue,
        renderUpdateBtn: renderUpdateBtn,
        isTunnelIface: isTunnelIface
    };
})();
