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

    /** Updatable detail keys → POST action URL (geo-split only). */
    var GEO_UPDATE_ACTIONS = {
        'geo_zone':       '/api/geo-split/update-subnets',
        'domain_sources': '/api/geo-split/update-domains'
    };

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
     * @param {Object} [opts.checks] - checks map from backend (ok/warn/fail per key)
     * @returns {Array<{isSpacer?:boolean, key:string, label:string, value:string,
     *   lines?:Array<{text:string, isError:boolean}>, isError:boolean, isWarning:boolean,
     *   isTimer:boolean, freshnessKey:string|null, updateAction:string|null}>}
     */
    function parseDetails(details, opts) {
        opts = opts || {};
        var skipKeys = opts.skipKeys || { uptime: 1 };
        var isRunning = opts.isRunning !== false;
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

            entries.push({
                key: key,
                label: formatKey(key),
                value: strVal,
                lines: lines,
                isError: isError,
                isWarning: isWarning,
                isTimer: isTimer,
                freshnessKey: TIMER_KEYS[key] ? key : null,
                updateAction: GEO_UPDATE_ACTIONS[key] || null
            });
        }
        return entries;
    }

    return {
        SERVICE_APIS: SERVICE_APIS,
        TIMER_KEYS: TIMER_KEYS,
        GEO_UPDATE_ACTIONS: GEO_UPDATE_ACTIONS,
        formatUptimeStock: formatUptimeStock,
        formatKey: formatKey,
        formatBool: formatBool,
        createPoller: createPoller,
        createTicker: createTicker,
        parseDetails: parseDetails
    };
})();
