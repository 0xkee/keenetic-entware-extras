// shared.js — Shared utilities for Entware Extras WebUI.
// Used by both inject.js (stock Keenetic page) and app.js (custom iframe page).
"use strict";

window.EW = (function() {

    /** Service registry — single source of truth for IDs, labels, URLs, API endpoints. */
    var SERVICE_APIS = [
        { id: 'geo-split',         label: 'Geo-Split',       desc: 'Policy-based geographic split routing',      url: '/custom/#geo-split',        api: '/api/geo-split/status' },
        { id: 'smartdns',          label: 'SmartDNS Config',  desc: 'RU zone DNS splitting (.ru/.рф/.su)',        url: '/custom/#smartdns',          api: '/api/smartdns/status' },
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

    return {
        SERVICE_APIS: SERVICE_APIS,
        TIMER_KEYS: TIMER_KEYS,
        GEO_UPDATE_ACTIONS: GEO_UPDATE_ACTIONS,
        formatUptimeStock: formatUptimeStock,
        formatKey: formatKey,
        formatBool: formatBool
    };
})();
