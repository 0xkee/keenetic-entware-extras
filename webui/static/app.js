// Entware Extras Dashboard — vanilla JS frontend.
// Uses stock Keenetic DOM classes for native look.
// Renders structured JSON from status.sh --json.

"use strict";

var POLL_ACTIVE = 5000;       // 5s when page is visible
var POLL_BACKGROUND = 60000;  // 60s when hidden (background tab)
var FETCH_TIMEOUT = 15000;    // 15 seconds (allows for queued io.popen in nginx)

/** Key detail labels shown in Summary mode per service. Others are hidden via CSS. */
var SUMMARY_KEYS = {
    'geo-split':         ['geo_zone', 'active_zones', 'subnets', 'domains', 'route_in', 'route_out'],
    'smartdns':          ['dns_zone', 'active_zones', 'zone_dns_provider', 'other_dns_provider', 'ports', 'rules'],
    'smartdns-redirect': ['interfaces', 'upstream'],
    'webui':             ['ports', 'http']
};

/** Get skeleton count for a service: cached from last API response, or default 6. */
function getSkeletonCount(id) {
    try {
        var cached = JSON.parse(localStorage.getItem('ew-skel-counts') || '{}');
        return cached[id] || 9;
    } catch (e) { return 9; }
}
/** Save real field count after first API response to localStorage. */
function saveSkeletonCount(id, count) {
    try {
        var cached = JSON.parse(localStorage.getItem('ew-skel-counts') || '{}');
        if (cached[id] !== count) {
            cached[id] = count;
            localStorage.setItem('ew-skel-counts', JSON.stringify(cached));
        }
    } catch (e) { /* ignore */ }
}

var autoRefreshTimer = null;
var activeTab = "all";
var _skipHashPush = false;      // Guard: skip pushState when applying hash from popstate/hashchange
var _inflightControllers = {};  // { serviceId: AbortController } — cancel stale in-flight requests
var _lastGoodData = {};    // { serviceId: { data: Object, timestamp: number } }
var STALE_MAX = 30000;     // 30s — после этого показываем "stale" badge

// ── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Format a timestamp as HH:MM:SS.
 * @param {Date} date
 * @returns {string}
 */
function formatTime(date) {
    return date.toLocaleTimeString("ru-RU", { hour12: false });
}

// ── Status badge rendering ───────────────────────────────────────────────────

/**
 * Set status badge for a service card using stock ndw-status classes.
 * @param {string} id - service id
 * @param {"ok"|"caution"|"warn"|"fail"|"error"|"stopped"|"stale"|"loading"} state
 * @param {string} [text] - status text
 */
function setStatus(id, state, text) {
    var el = document.getElementById("status-" + id);
    if (!el) return;

    var statusClass = "status";
    var iconHtml = "";

    if (state === "loading") {
        el.innerHTML = '<div class="ew-skeleton ew-skeleton--medium"></div>';
        return;
    } else if (state === "ok") {
        statusClass = "status status--success";
        iconHtml = '<div class="status__icon"></div>';
    } else if (state === "caution") {
        statusClass = "status status--caution";
        iconHtml = '<div class="status__icon"></div>';
    } else if (state === "warn") {
        statusClass = "status status--warning";
        iconHtml = '<div class="status__icon"></div>';
    } else if (state === "fail" || state === "error") {
        statusClass = "status status--warning";
        iconHtml = '<div class="status__icon"></div>';
    } else if (state === "stopped") {
        statusClass = "status status--stopped";
        iconHtml = '<div class="status__icon"></div>';
    } else if (state === "stale") {
        statusClass = "status status--stale";
        iconHtml = '<div class="status__icon"></div>';
    }

    el.innerHTML = '<div class="' + statusClass + '">' +
        iconHtml +
        '<div class="status__text">' + EW.escapeHtml(text || "") + '</div>' +
        '</div>';
}

// ── Details rendering ────────────────────────────────────────────────────────

var GEO_FAST_POLL = 1000;  // 1s when background update is running

/** Ticker for live uptime/freshness counters — updates status badges.
 *  Guard: only updates if the badge is currently in ok/caution state (not error/stopped).
 *  This prevents the ticker from overwriting error or stopped badges. */
var ticker = EW.createTicker(function(id, currentSeconds, extra) {
    var el = document.getElementById("status-" + id);
    if (!el) return;
    var inner = el.querySelector('.status');
    if (!inner) return;
    // Only tick if status is currently success or caution (service is running)
    if (!inner.classList.contains('status--success') && !inner.classList.contains('status--caution')) return;
    setStatus(id, (extra && extra.state) || "ok", "Running " + EW.formatUptimeStock(currentSeconds));
});

/** Fast poller for geo-split during background updates. */
var geoPoller = EW.createPoller(
    function() { fetchStatus("/api/geo-split/status", "geo-split", true); },
    GEO_FAST_POLL,
    function() {
        document.querySelectorAll('.ew-update-btn--spinning').forEach(function(btn) {
            btn.classList.remove('ew-update-btn--spinning');
            btn.disabled = false;
        });
    }
);

/**
 * Set structured details for a service card.
 * Uses EW.parseDetails() for parsing, wraps entries in list rows.
 * @param {string} id - service id
 * @param {Object} data - full JSON response from API
 */
function setDetails(id, data) {
    var el = document.getElementById("details-" + id);
    if (!el) return;
    if (!data.details) { el.innerHTML = ""; return; }

    var entries = EW.parseDetails(data.details, { isRunning: data.running, serviceId: id });
    var html = "";
    var summaryKeys = SUMMARY_KEYS[id] || [];
    for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        if (e.isSpacer) { html += '<div class="ew-detail-item"></div>'; continue; }

        // Base rendering from shared
        var valHtml = EW.renderDetailValue(e, { dnsServerChecks: data.dns_server_checks });
        var valStyle = EW.detailValueStyle(e);

        // app.js-specific: priority for summary condensed mode
        var priority = (summaryKeys.indexOf(e.key) !== -1) ? 'high' : 'low';
        if (priority === 'high' && e.shortValue) {
            valHtml = '<span class="ew-val-short">' + EW.escapeHtml(e.shortValue) + '</span>' +
                '<span class="ew-val-full">' + valHtml + '</span>';
        }

        // app.js-specific: version badge link
        if (e.label.toLowerCase() === 'version') {
            // TODO: replace forum link with GitHub releases URL when available
            valHtml = '<a class="ew-version-badge" href="https://forum.keenetic.ru/topic/28369-geo-split-routing-%D0%B4%D0%BB%D1%8F-keenetic-%D1%81-entware-geoip-%D0%B4%D0%BE%D0%BC%D0%B5%D0%BD%D1%8B-ipk-%D0%BF%D0%B0%D0%BA%D0%B5%D1%82%D1%8B/" target="_blank" rel="noopener" data-tooltip="Open project page">' + EW.escapeHtml(e.value) + '</a>';
        }

        var isNumericOnly = /^\d[\d,.]*[KMG]?[Bb]?$/.test(e.value.trim());
        var numClass = isNumericOnly ? ' ew-detail-value--numeric' : '';
        var updateBtn = EW.renderUpdateBtn(e);
        var dataAttr = e.freshnessKey ? ' data-freshness-key="' + e.freshnessKey + '"' : '';
        html += '<div class="ew-detail-item" data-priority="' + priority + '">' +
            '<div class="ew-detail-label">' + EW.escapeHtml(e.label) + '</div>' +
            '<div class="ew-detail-value' + numClass + '"' + valStyle + dataAttr + '>' + valHtml + updateBtn + '</div></div>';
    }
    // DNS test results: one grid item with all tests as lines (like Ports)
    if (data.dns_tests && data.dns_tests.length) {
        var dnsLines = [];
        for (var ti = 0; ti < data.dns_tests.length; ti++) {
            var t = data.dns_tests[ti];
            var tOk = t.result && t.result !== 'FAILED';
            var tIcon = tOk ? '\u2713' : '\u2717';
            var tClass = tOk ? 'ew-bool-icon--ok' : 'ew-bool-icon--fail';
            dnsLines.push('<span class="ew-bool-icon ' + tClass + '">' + tIcon + '</span> ' +
                '<a class="ew-dns-link" href="https://' + EW.escapeHtml(t.domain) + '" target="_blank" rel="noopener">' +
                EW.escapeHtml(t.domain) + '</a> \u2192 ' + EW.escapeHtml(t.result || 'FAILED'));
        }
        var dnsItem = '<div class="ew-detail-item" data-priority="low">' +
            '<div class="ew-detail-label">DNS Tests</div>' +
            '<div class="ew-detail-value">' +
            '<div class="ew-dns-line">' + dnsLines.join('</div><div class="ew-dns-line">') + '</div>' +
            '</div></div>';
        // Insert before cache
        var cachePos = html.indexOf('ew-detail-label">Cache<');
        if (cachePos !== -1) {
            var insertPos = html.lastIndexOf('<div class="ew-detail-item"', cachePos);
            if (insertPos !== -1) {
                html = html.substring(0, insertPos) + dnsItem + html.substring(insertPos);
            } else {
                html += dnsItem;
            }
        } else {
            html += dnsItem;
        }
    }
    // Cache real field count for next page load skeleton rendering
    var dnsExtra = (data.dns_tests && data.dns_tests.length) ? 1 : 0;
    var realCount = entries.filter(function(e) { return !e.isSpacer; }).length + dnsExtra;
    saveSkeletonCount(id, realCount);
    el.innerHTML = html;
}

/**
 * Update left accent border color on card based on service state.
 * @param {string} id - service id
 * @param {"running"|"caution"|"stopped"|"stale"|"error"} state
 */
function updateCardAccent(id, state) {
    var card = document.getElementById("card-" + id);
    if (!card) return;
    card.classList.remove("dashboard-card--running", "dashboard-card--caution", "dashboard-card--stopped", "dashboard-card--stale", "dashboard-card--error");
    if (state) card.classList.add("dashboard-card--" + state);
}

// ── Tab switching ────────────────────────────────────────────────────────────

/**
 * Switch active tab and show/hide service cards accordingly.
 * Updates location.hash for deep-linking support.
 * @param {string} tabId - "all", "geo-split", "smartdns", "smartdns-redirect", "webui"
 */
function switchTab(tabId) {
    activeTab = tabId;

    var tabs = document.querySelectorAll("#service-tabs .ndw-tabs__tab");
    for (var i = 0; i < tabs.length; i++) {
        var tab = tabs[i];
        if (tab.id === "tab-" + tabId) {
            tab.classList.add("ndw-tabs__tab--active");
            tab.setAttribute("aria-selected", "true");
        } else {
            tab.classList.remove("ndw-tabs__tab--active");
            tab.setAttribute("aria-selected", "false");
        }
    }

    var container = document.getElementById("service-cards");
    if (container) {
        if (tabId === "all") {
            container.classList.add("ew-summary-mode");
        } else {
            container.classList.remove("ew-summary-mode");
        }
    }

    var serviceIds = EW.SERVICE_APIS.map(function(svc) { return svc.id; });
    for (var j = 0; j < serviceIds.length; j++) {
        var card = document.getElementById("card-" + serviceIds[j]);
        if (!card) continue;
        if (tabId === "all" || tabId === serviceIds[j]) {
            card.classList.remove("ew-hidden");
        } else {
            card.classList.add("ew-hidden");
        }
    }

    // Close modal when switching tabs
    closeConfigModal();

    // Update URL hash — pushState for browser back/forward support
    var newHash = (tabId === "all") ? "" : "#" + tabId;
    if (window.location.hash !== newHash) {
        if (_skipHashPush) {
            history.replaceState(null, "", newHash || window.location.pathname);
        } else {
            history.pushState(null, "", newHash || window.location.pathname);
        }
    }
}

/**
 * Read location.hash and switch to matching tab.
 * Called on page load and hashchange events.
 */
function applyHashRoute() {
    var hash = window.location.hash.replace(/^#/, "");
    if (!hash) { switchTab("all"); return; }
    var valid = EW.SERVICE_APIS.some(function(svc) { return svc.id === hash; });
    if (valid) {
        switchTab(hash);
    } else {
        switchTab("all");
    }
}

// ── Fetch status ─────────────────────────────────────────────────────────────

/**
 * Fetch structured JSON from status API and render card.
 * On error: shows error badge immediately. The ticker CSS guard (checks
 * status--success/caution class) prevents uptime counter from overwriting
 * the error badge. Next successful fetch restores the true state.
 * On initial load (skipLoading=false): shows Loading skeleton first.
 * @param {string} url - API URL
 * @param {string} id - service id
 * @param {boolean} [skipLoading] - true to skip initial Loading indicator
 */
function fetchStatus(url, id, skipLoading) {
    // Abort any previous in-flight request for this service (prevents race condition
    // where a stale success response arrives after a newer error, overwriting it)
    if (_inflightControllers[id]) {
        _inflightControllers[id].abort();
    }

    if (!skipLoading) {
        setStatus(id, "loading", "Loading...");
    }

    var controller = new AbortController();
    _inflightControllers[id] = controller;
    var timer = setTimeout(function() { controller.abort(); }, FETCH_TIMEOUT);

    fetch(url, { signal: controller.signal })
        .then(function(resp) {
            clearTimeout(timer);
            if (!resp.ok) throw new Error("HTTP " + resp.status);
            return resp.json();
        })
        .then(function(data) {
            if (!data) return;
            _inflightControllers[id] = null;

            // Handle "pending" response (Lua cache warming, no actual status data)
            if (data.status === "pending" && data.running === undefined) {
                // Backend doesn't know yet — keep showing previous state
                // Don't update badge, details, or toggle
                return;
            }

            // Structured JSON from status.sh --json
            if (data.running !== undefined) {
                // Store last good data for stale-while-revalidate
                _lastGoodData[id] = { data: data, timestamp: Date.now() };

                // Suppress transient "Failed" during toggle transition (service restarting)
                if (togglePoller.isPolling(id)) {
                    if (!data.running && typeof data.enabled === 'boolean' && data.enabled) {
                        // Would show "Failed" but service is still transitioning — skip
                        return;
                    }
                    // State settled (running or cleanly stopped) — stop fast-poller
                    togglePoller.stop(id);
                }

                // New structured format
                if (data.running && typeof data.enabled === 'boolean' && !data.enabled) {
                    // Process is running but user disabled the feature → grey "Disabled"
                    setStatus(id, "stopped", "Disabled");
                    updateCardAccent(id, "stopped");
                } else if (data.running) {
                    // Check if any detail field is false → caution badge
                    var hasFail = EW.hasFailField(data.details);
                    var badgeState = hasFail ? "caution" : "ok";
                    var uptimeSecs = data.details && data.details.uptime;
                    if (uptimeSecs) {
                        setStatus(id, badgeState, "Running " + EW.formatUptimeStock(uptimeSecs));
                    } else {
                        setStatus(id, badgeState, "Running");
                    }
                } else {
                    // Distinguish: user disabled vs service crashed
                    if (typeof data.enabled === 'boolean' && data.enabled) {
                        // Should be running but isn't → real failure
                        setStatus(id, "error", "Failed");
                        updateCardAccent(id, "error");
                    } else {
                        // Disabled by user or no enabled concept → neutral
                        setStatus(id, "stopped", "Stopped");
                        updateCardAccent(id, "stopped");
                    }
                }

                // Update toggle switch state
                var toggle = document.getElementById("toggle-" + id);
                if (toggle) {
                    toggle.checked = (typeof data.enabled === "boolean") ? data.enabled : data.running;
                    toggle.disabled = false;
                }
                setDetails(id, data);
                // Card accent: disabled/stopped/error branches already set it;
                // only override for running+enabled
                var isDisabled = (typeof data.enabled === 'boolean' && !data.enabled);
                if (!isDisabled && data.running) {
                    updateCardAccent(id, hasFail ? "caution" : "running");
                }
                // Update uptime baseline (store badge state for ticker)
                if (data.running && !isDisabled && data.details && data.details.uptime) {
                    ticker.setUptimeBaseline(id, data.details.uptime, { state: badgeState });
                } else {
                    ticker.removeUptimeBaseline(id);
                }
                // Update freshness baselines (timer keys)
                if (data.details) {
                    for (var tk in EW.TIMER_KEYS) {
                        if (data.details[tk]) {
                            ticker.setFreshnessBaseline(tk, data.details[tk]);
                        }
                    }
                }
                // Start ticker if not running and at least one service has baseline
                if (ticker.hasBaselines()) {
                    ticker.start();
                }
                // Check geo-split background for fast polling
                if (id === 'geo-split' && data.details) {
                    if (data.details.background === 'running') {
                        geoPoller.start();
                    } else if (geoPoller.isRunning()) {
                        geoPoller.stop();
                    }
                }
            } else if (data.output !== undefined) {
                // Legacy text format (webui/status.sh)
                setStatus(id, data.ok ? "ok" : "fail", data.ok ? "OK" : "Error");
                updateCardAccent(id, data.ok ? "running" : "error");
                var el = document.getElementById("details-" + id);
                if (el) {
                    el.innerHTML = '<pre class="ew-details-pre">' + EW.escapeHtml(data.output) + '</pre>';
                }
            } else if (data.error) {
                setStatus(id, "error", "Script error");
                updateCardAccent(id, "error");
                var el2 = document.getElementById("details-" + id);
                if (el2) {
                    el2.innerHTML = '<pre class="ew-details-pre ew-details-pre--error">' + EW.escapeHtml(data.error) + '</pre>';
                }
            } else {
                setStatus(id, "warn", "Unknown format");
                updateCardAccent(id, "caution");
            }
        })
        .catch(function(err) {
            clearTimeout(timer);
            // Ignore AbortError from superseded requests (new fetch replaced this one)
            if (err.name === "AbortError" && _inflightControllers[id] !== controller) return;
            _inflightControllers[id] = null;

            // Stale-while-revalidate: don't immediately show error if we have recent data
            var last = _lastGoodData[id];
            if (last && (Date.now() - last.timestamp) < STALE_MAX) {
                // Silent stale — keep showing previous badge, do nothing
                return;
            }
            // Stale expired or never had data — show neutral "stale" badge (not red error!)
            ticker.removeUptimeBaseline(id);
            setStatus(id, "stale", "No data");
            updateCardAccent(id, "stale");
        });
}

// ── Refresh all ──────────────────────────────────────────────────────────────

/**
 * Refresh all service cards + system info.
 * @param {boolean} [skipLoading] - if true, don't flash Loading on refresh (default: true)
 */
function refreshAll(skipLoading) {
    var skip = skipLoading !== false; // default true
    EW.SERVICE_APIS.forEach(function(svc) {
        fetchStatus(svc.api, svc.id, skip);
    });
    fetchSystemInfo();
}

// ── System info ──────────────────────────────────────────────────────────────

// Inline SVG icons for sysinfo bar (12x12, fill:currentColor)
var SYSINFO_ICONS = {
    host: '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" style="vertical-align:-1px"><path d="M20 18c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2H4c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2H1v2h22v-2h-3zM4 6h16v10H4V6z"/></svg>',
    up: '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" style="vertical-align:-1px"><path d="M12 2C6.5 2 2 6.5 2 12s4.5 10 10 10 10-4.5 10-10S17.5 2 12 2zm0 18c-4.4 0-8-3.6-8-8s3.6-8 8-8 8 3.6 8 8-3.6 8-8 8zm.5-13H11v6l5.2 3.2.8-1.3-4.5-2.7V7z"/></svg>',
    cpu: '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" style="vertical-align:-1px"><path d="M15 9H9v6h6V9zm-2 4h-2v-2h2v2zm8-2V9h-2V7c0-1.1-.9-2-2-2h-2V3h-2v2h-2V3H9v2H7c-1.1 0-2 .9-2 2v2H3v2h2v2H3v2h2v2c0 1.1.9 2 2 2h2v2h2v-2h2v2h2v-2h2c1.1 0 2-.9 2-2v-2h2v-2h-2v-2h2zm-4 6H7V7h10v10z"/></svg>',
    ram: '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" style="vertical-align:-1px"><path d="M2 7v10h20V7H2zm18 8H4V9h16v6zM6 11h2v2H6zm3 0h2v2H9zm3 0h2v2h-2zm3 0h2v2h-2z"/></svg>',
    disk: '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" style="vertical-align:-1px"><path d="M20 6H12L10 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm0 12H4V8h16v10z"/></svg>'
};

/**
 * Fetch system info (hostname, uptime, RAM, disk, CPU) and render header bar.
 */
function fetchSystemInfo() {
    fetch("/api/system/info")
        .then(function(r) { return r.json(); })
        .then(function(data) {
            if (!data || !data.ok) return;
            var el = document.getElementById("sysinfo");
            if (!el) return;

            // RAM: used = total - MemAvailable (kernel-estimated truly free memory).
            // More accurate than (total - free - buffers - cached) — accounts for
            // non-reclaimable slab/conntrack. May show ~15% higher than stock UI.
            var memPct = 0;
            if (data.memory && data.memory.total_kb > 0) {
                var used = data.memory.total_kb - data.memory.available_kb;
                memPct = Math.round((used / data.memory.total_kb) * 100);
            }

            var diskPct = 0;
            if (data.disk_opt && data.disk_opt.total_kb > 0) {
                diskPct = Math.ceil((data.disk_opt.used_kb / data.disk_opt.total_kb) * 100);
            }

            // CPU: normalize load1 to percentage (load1/cores * 100, capped at 100)
            var cpuCores = (data.cpu_load && data.cpu_load.cores) || 1;
            var cpuLoad1 = (data.cpu_load && data.cpu_load.load1) || 0;
            var cpuPct = Math.min(100, Math.round((cpuLoad1 / cpuCores) * 100));

            var cpuClass = cpuPct > 90 ? " ew-sysinfo__bar-fill--crit" : cpuPct > 75 ? " ew-sysinfo__bar-fill--warn" : "";
            var memClass = memPct > 90 ? " ew-sysinfo__bar-fill--crit" : memPct > 75 ? " ew-sysinfo__bar-fill--warn" : "";
            var diskClass = diskPct > 90 ? " ew-sysinfo__bar-fill--crit" : diskPct > 75 ? " ew-sysinfo__bar-fill--warn" : "";

            el.innerHTML =
                '<span class="ew-sysinfo__item">' +
                    '<span class="ew-sysinfo__icon">' + SYSINFO_ICONS.host + '</span>' +
                    '<span class="ew-sysinfo__value">' + EW.escapeHtml(data.hostname || "router") + '</span>' +
                '</span>' +
                '<span class="ew-sysinfo__item">' +
                    '<span class="ew-sysinfo__icon">' + SYSINFO_ICONS.up + '</span>' +
                    '<span class="ew-sysinfo__label">up</span>' +
                    '<span class="ew-sysinfo__value">' + EW.escapeHtml(data.uptime || "?") + '</span>' +
                '</span>' +
                '<span class="ew-sysinfo__item" data-tooltip="' +
                    'Load: ' + cpuLoad1.toFixed(2) + ' / ' + cpuCores + ' cores\n' +
                    'Based on 1-minute load average, not instantaneous CPU usage.\n' +
                    'Stock UI shows real-time utilization — this shows sustained load over time.\n' +
                    'Values may differ from stock UI — this is normal and not a cause for concern.' + '" data-tooltip-pos="below">' +
                    '<span class="ew-sysinfo__icon">' + SYSINFO_ICONS.cpu + '</span>' +
                    '<span class="ew-sysinfo__label">CPU</span>' +
                    '<span class="ew-sysinfo__value">' + cpuPct + '%</span>' +
                    '<span class="ew-sysinfo__bar"><span class="ew-sysinfo__bar-fill' + cpuClass + '" style="width:' + cpuPct + '%"></span></span>' +
                '</span>' +
                '<span class="ew-sysinfo__item" data-tooltip="' +
                    'Available: ' + Math.round(data.memory.available_kb / 1024) + ' MB / ' + Math.round(data.memory.total_kb / 1024) + ' MB\n' +
                    'Conservative estimate — accounts for memory locked by kernel (conntrack, routing tables, slab cache) that cannot be freed.\n' +
                    'May show ~15% higher usage than stock UI — this is normal and not a cause for concern.' + '" data-tooltip-pos="below">' +
                    '<span class="ew-sysinfo__icon">' + SYSINFO_ICONS.ram + '</span>' +
                    '<span class="ew-sysinfo__label">RAM</span>' +
                    '<span class="ew-sysinfo__value">' + memPct + '%</span>' +
                    '<span class="ew-sysinfo__bar"><span class="ew-sysinfo__bar-fill' + memClass + '" style="width:' + memPct + '%"></span></span>' +
                '</span>' +
                '<span class="ew-sysinfo__item">' +
                    '<span class="ew-sysinfo__icon">' + SYSINFO_ICONS.disk + '</span>' +
                    '<span class="ew-sysinfo__label">/opt</span>' +
                    '<span class="ew-sysinfo__value">' + diskPct + '%</span>' +
                    '<span class="ew-sysinfo__bar"><span class="ew-sysinfo__bar-fill' + diskClass + '" style="width:' + diskPct + '%"></span></span>' +
                '</span>';
        })
        .catch(function() { /* silent — sysinfo is non-critical */ });
}

// ── Auto-refresh ─────────────────────────────────────────────────────────────

/**
 * Start adaptive auto-refresh: 5s when visible, 60s when background.
 */
function startAutoRefresh() {
    var interval = document.hidden ? POLL_BACKGROUND : POLL_ACTIVE;
    if (autoRefreshTimer) clearInterval(autoRefreshTimer);
    autoRefreshTimer = setInterval(refreshAll, interval);
}

// ── Stock CSS discovery ──────────────────────────────────────────────────────

/**
 * Auto-discover the current styles-*.css URL and active theme from proxied
 * Keenetic main page. Updates <link href="styles-*.css"> if URL changed,
 * and syncs theme class (dark/light) on <html> so CSS variables resolve.
 * Stock CSS defines vars on :root .dark / :root .light selectors.
 */
function discoverStockCSS() {
    fetch("/")
        .then(function(r) { return r.text(); })
        .then(function(html) {
            // Update styles-*.css URL
            var m = html.match(/styles-[A-Za-z0-9]+\.css/);
            if (m) {
                var link = document.querySelector('link[href*="styles-"]');
                if (link && link.getAttribute("href") !== "/" + m[0]) {
                    link.href = "/" + m[0];
                }
            }

            // Sync theme class from parent page (dark or light)
            var themeMatch = html.match(/class="[^"]*\b(dark|light)\b/);
            if (themeMatch && themeMatch[1]) {
                var root = document.documentElement;
                root.classList.remove("dark", "light");
                root.classList.add(themeMatch[1]);
            }
        })
        .catch(function() { /* stock CSS URL stays as hardcoded fallback */ });
}

/**
 * Listen for CSS URL from inject.js (parent frame) via postMessage.
 * Allows the parent proxy page to push the correct styles-*.css URL
 * into the iframe after firmware updates change the hash.
 */
window.addEventListener("message", function(e) {
    if (e.data && e.data.type === "keenetic-css-url" && e.data.url) {
        var link = document.querySelector('link[href*="styles-"]');
        if (link) link.href = e.data.url;
    }
});

// ── UI generation ────────────────────────────────────────────────────────────

/**
 * Generate tabs and service cards from EW.SERVICE_APIS.
 * Called once at DOMContentLoaded — single source of truth for UI structure.
 */
function buildUI() {
    var tabList = document.getElementById("tab-list");
    var cardsContainer = document.getElementById("service-cards");
    if (!tabList || !cardsContainer) return;

    // "Summary" tab (all services overview)
    var allTab = document.createElement("div");
    allTab.tabIndex = 0;
    allTab.className = "ndw-tabs__tab ndw-tabs__tab--active";
    allTab.id = "tab-all";
    allTab.setAttribute("role", "tab");
    allTab.setAttribute("aria-selected", "true");
    allTab.innerHTML = '<div class="ndw-tabs__tab__label">Summary</div>';
    allTab.addEventListener("click", function() { switchTab("all"); });
    tabList.appendChild(allTab);

    // Service tabs + cards from registry
    EW.SERVICE_APIS.forEach(function(svc, idx) {
        // Tab
        var tab = document.createElement("div");
        tab.tabIndex = 0;
        tab.className = "ndw-tabs__tab";
        if (idx === EW.SERVICE_APIS.length - 1) tab.className += " ndw-tabs__tab--last";
        tab.id = "tab-" + svc.id;
        tab.setAttribute("role", "tab");
        tab.setAttribute("aria-selected", "false");
        tab.innerHTML = '<div class="ndw-tabs__tab__label">' + EW.escapeHtml(svc.label) + '</div>';
        tab.addEventListener("click", function() { switchTab(svc.id); });
        tabList.appendChild(tab);

        // Card — with toggle switch for start/stop (except webui itself)
        var card = document.createElement("div");
        card.className = "dashboard-card";
        card.id = "card-" + svc.id;
        card.dataset.service = svc.id;

        var toggleHtml = '';
        if (svc.id !== 'webui') {
            toggleHtml =
                '<label class="ew-toggle ew-card-toggle" title="Enable/Disable">' +
                    '<input type="checkbox" id="toggle-' + svc.id + '" disabled>' +
                    '<span class="ew-toggle__bar"></span>' +
                '</label>';
        }

        var editBtnHtml = '';
        if (CONFIG_SCHEMAS[svc.id]) {
            editBtnHtml =
                '<button class="ndw-button ndw-button--toggle ndw-button--toggle-enabled ndw-button--small ndw-button--no-text ew-edit-btn" data-tooltip="Edit Config" data-edit="' + svc.id + '">' +
                    '<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>' +
                '</button>';
        }

        var diagBtnHtml = '';
        if (svc.id === 'geo-split') {
            diagBtnHtml =
                '<button class="ndw-button ndw-button--toggle ndw-button--toggle-enabled ndw-button--small ndw-button--no-text ew-diag-btn" data-tooltip="Route Check" data-diag="route">' +
                    '<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><path d="M15.5 14h-.79l-.28-.27A6.47 6.47 0 0016 9.5 6.5 6.5 0 109.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z"/></svg>' +
                '</button>';
        } else if (svc.id === 'smartdns') {
            diagBtnHtml =
                '<button class="ndw-button ndw-button--toggle ndw-button--toggle-enabled ndw-button--small ndw-button--no-text ew-diag-btn" data-tooltip="DNS Check" data-diag="dns">' +
                    '<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><path d="M15.5 14h-.79l-.28-.27A6.47 6.47 0 0016 9.5 6.5 6.5 0 109.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z"/></svg>' +
                '</button>';
        }

        card.innerHTML =
            '<div class="dashboard-card__header">' +
                '<div class="dashboard-card__header-left">' +
                    toggleHtml +
                    '<span class="text-card-heading">' + EW.escapeHtml(svc.label.toUpperCase()) + '</span>' +
                '</div>' +
                '<div class="dashboard-card__header-buttons">' +
                    diagBtnHtml +
                    editBtnHtml +
                '</div>' +
            '</div>' +
            '<div class="dashboard-card__content" id="content-' + svc.id + '">' +
                '<div class="ew-service-row"><div class="ew-service-info">' +
                    '<div class="ndw-status ndw-status--chip" id="status-' + svc.id + '">' +
                        '<div class="ew-skeleton ew-skeleton--medium"></div>' +
                    '</div>' +
                '</div></div>' +
                '<div id="details-' + svc.id + '" class="ew-details-grid">' +
                    (function() {
                        var s='', n=getSkeletonCount(svc.id), highCount=(SUMMARY_KEYS[svc.id]||[]).length||3;
                        for(var j=0;j<n;j++) {
                            var pri = j < highCount ? 'high' : 'low';
                            s+='<div class="ew-detail-item" data-priority="'+pri+'"><div class="ew-skeleton ew-skeleton--short"></div><div class="ew-skeleton ew-skeleton--medium" style="margin-top:4px"></div></div>';
                        }
                        return s;
                    })() +
                '</div>' +
                '<div class="ew-card-more"><a href="#' + svc.id + '" data-tab="' + svc.id + '">View details \u2192</a></div>' +
            '</div>';
        cardsContainer.appendChild(card);
    });

    // Event delegation: click card in summary mode → switch to single service tab
    cardsContainer.addEventListener("click", function(evt) {
        if (activeTab !== "all") return;
        // Don't hijack clicks on toggles, buttons, or links inside cards
        if (evt.target.closest(".ew-toggle, .ndw-button, a, button")) return;
        var card = evt.target.closest(".dashboard-card");
        if (card && card.dataset.service) {
            switchTab(card.dataset.service);
        }
    });
}

// ── Toggle handling ──────────────────────────────────────────────────────────

var togglePoller = EW.createTogglePoller({ interval: 1000 });

/**
 * Start fast polling for a service after toggle until state settles.
 * @param {string} serviceId
 */
function startTogglePoller(serviceId) {
    togglePoller.start(serviceId, function(svc, done) {
        fetchStatus(svc.api, serviceId, true);
    });
}

/**
 * Handle toggle switch change: POST start/stop, then fast-poll.
 * @param {string} serviceId
 * @param {HTMLInputElement} checkbox
 */
function handleToggle(serviceId, checkbox) {
    var action = checkbox.checked ? "start" : "stop";
    checkbox.disabled = true;

    fetch("/api/" + serviceId + "/" + action, { method: "POST" })
        .then(function(r) { return r.json(); })
        .then(function(data) {
            checkbox.disabled = false;
            if (!data.ok) {
                // Revert toggle on failure
                checkbox.checked = !checkbox.checked;
            } else {
                startTogglePoller(serviceId);
            }
        })
        .catch(function() {
            checkbox.disabled = false;
            checkbox.checked = !checkbox.checked;
        });
}

// Config Editor → moved to config-editor.js

// ── Init ─────────────────────────────────────────────────────────────────────

document.addEventListener("DOMContentLoaded", function() {
    // Prevent number input scroll from changing values while scrolling modal
    document.addEventListener('wheel', function(e) {
        if (e.target && e.target.type === 'number' && document.activeElement === e.target) {
            e.target.blur();
        }
    }, { passive: true });

    // radio_text: enable/disable custom input on radio change
    document.addEventListener('change', function(e) {
        var radio = e.target;
        if (radio.type !== 'radio') return;
        var rtWrap = radio.closest('.ew-modal__radio-text');
        if (!rtWrap) return;
        var txtInput = rtWrap.querySelector('.ew-modal__radio-input');
        if (txtInput) {
            txtInput.disabled = (radio.value !== '__custom__');
            if (radio.value === '__custom__') txtInput.focus();
        }
    });

    // zone_selector: toggle panels on radio change
    document.addEventListener('change', function(e) {
        var radio = e.target;
        if (radio.type !== 'radio' || !radio.name || !radio.name.match(/^zs-mode-/)) return;
        var zsWrap = radio.closest('.ew-modal__zone-selector');
        if (!zsWrap) return;
        var panels = zsWrap.querySelectorAll('[data-zone-panel]');
        for (var i = 0; i < panels.length; i++) {
            panels[i].classList.toggle('ew-hidden', panels[i].getAttribute('data-zone-panel') !== radio.value);
        }
    });

    // iface_select: toggle dropdown panel on trigger click
    document.addEventListener('click', function(e) {
        var trigger = e.target.closest('.ew-modal__iface-select-trigger');
        if (trigger) {
            var wrap = trigger.closest('.ew-modal__iface-select');
            var panel = wrap && wrap.querySelector('.ew-modal__iface-select-panel');
            if (panel) {
                var isOpening = panel.classList.contains('ew-hidden');
                // Close all other open panels first
                var allOpen = document.querySelectorAll('.ew-modal__iface-select-panel:not(.ew-hidden)');
                for (var ap = 0; ap < allOpen.length; ap++) {
                    if (allOpen[ap] !== panel) allOpen[ap].classList.add('ew-hidden');
                }
                panel.classList.toggle('ew-hidden');
                // Position panel fixed to overlay modal
                if (isOpening) {
                    var rect = trigger.getBoundingClientRect();
                    var availHeight = window.innerHeight - rect.bottom - 12;
                    panel.style.position = 'fixed';
                    panel.style.top = rect.bottom + 4 + 'px';
                    panel.style.left = rect.left + 'px';
                    panel.style.right = 'auto';
                    panel.style.width = rect.width + 'px';
                    panel.style.maxHeight = Math.min(availHeight, window.innerHeight * 0.6) + 'px';
                    // Auto-focus filter input and reset filter
                    var filterInput = panel.querySelector('.ew-modal__iface-filter');
                    if (filterInput) {
                        filterInput.value = '';
                        var opts = panel.querySelectorAll('.ew-modal__iface-select-option');
                        for (var fi = 0; fi < opts.length; fi++) opts[fi].style.display = '';
                        var grps = panel.querySelectorAll('.ew-modal__iface-select-group');
                        for (var gi = 0; gi < grps.length; gi++) grps[gi].style.display = '';
                        var countEl = panel.querySelector('.ew-modal__iface-filter-count');
                        if (countEl) countEl.textContent = '';
                        setTimeout(function() { filterInput.focus(); }, 0);
                    }
                }
            }
            e.stopPropagation();
            return;
        }
        // Close all open iface_select panels on outside click
        if (!e.target.closest('.ew-modal__iface-select')) {
            var openPanels = document.querySelectorAll('.ew-modal__iface-select-panel:not(.ew-hidden)');
            for (var i = 0; i < openPanels.length; i++) openPanels[i].classList.add('ew-hidden');
        }
    });

    // iface_select: update display text on checkbox/radio change
    document.addEventListener('change', function(e) {
        var wrap = e.target.closest('.ew-modal__iface-select');
        if (!wrap) return;
        if (e.target.type === 'radio') {
            // Union single-select: update text and close panel
            var label = e.target.closest('.ew-modal__iface-select-option');
            var textEl = wrap.querySelector('.ew-modal__iface-select-text');
            if (textEl && label) {
                var spans = label.querySelectorAll('span');
                var spanText = spans.length > 0 ? spans[spans.length - 1] : null;
                textEl.textContent = spanText ? spanText.textContent : e.target.value;
            }
            var panel = wrap.querySelector('.ew-modal__iface-select-panel');
            if (panel) setTimeout(function() { panel.classList.add('ew-hidden'); }, 150);
        } else if (e.target.type === 'checkbox') {
            // Multi-select: preserve selection order (add to end / remove in place)
            var currentOrder = (wrap.dataset.selectionOrder || '').split(' ').filter(Boolean);
            var changedVal = e.target.value;
            if (e.target.checked) {
                if (currentOrder.indexOf(changedVal) === -1) currentOrder.push(changedVal);
            } else {
                var idx = currentOrder.indexOf(changedVal);
                if (idx !== -1) currentOrder.splice(idx, 1);
            }
            wrap.dataset.selectionOrder = currentOrder.join(' ');
            var textEl2 = wrap.querySelector('.ew-modal__iface-select-text');
            if (textEl2) textEl2.textContent = currentOrder.length ? currentOrder.map(function(n) { return EW.ifaceLabelFull(n); }).join(', ') : 'Default route';
        }
    });

    // iface_select/zone_selector: filter options by typing in search input
    document.addEventListener('input', function(e) {
        if (!e.target.classList.contains('ew-modal__iface-filter')) return;
        var query = e.target.value.toLowerCase();
        var panel = e.target.closest('.ew-modal__iface-select-panel');
        if (!panel) return;
        var options = panel.querySelectorAll('.ew-modal__iface-select-option');
        for (var i = 0; i < options.length; i++) {
            var text = options[i].textContent.toLowerCase();
            options[i].style.display = (!query || text.indexOf(query) !== -1) ? '' : 'none';
        }
        // Hide group headers that have no visible items below them
        var groups = panel.querySelectorAll('.ew-modal__iface-select-group');
        for (var g = 0; g < groups.length; g++) {
            var hasVisible = false;
            var next = groups[g].nextElementSibling;
            while (next && !next.classList.contains('ew-modal__iface-select-group')) {
                if (next.style.display !== 'none' && next.classList.contains('ew-modal__iface-select-option')) {
                    hasVisible = true;
                    break;
                }
                next = next.nextElementSibling;
            }
            groups[g].style.display = (!query || hasVisible) ? '' : 'none';
        }
        // Update count badge
        var countSpan = panel.querySelector('.ew-modal__iface-filter-count');
        if (countSpan) {
            if (query) {
                var visibleCount = 0;
                for (var vc = 0; vc < options.length; vc++) {
                    if (options[vc].style.display !== 'none') visibleCount++;
                }
                countSpan.textContent = visibleCount + '/' + options.length;
            } else {
                countSpan.textContent = options.length > 8 ? options.length : '';
            }
        }
    });

    // radio_text: clicking on disabled IP input passes through (CSS pointer-events:none)
    // to the <label>, which natively checks the __custom__ radio.
    // The 'change' handler above then enables + focuses the text input.

    // Eagerly load interface label map (shared by status cards, diagrams, config editor)
    EW.loadIfaceMap();

    // Discover correct stock CSS URL (styles-*.css may change after firmware update)
    discoverStockCSS();

    // Generate tabs + cards from SERVICE_APIS (single source of truth)
    buildUI();

    // Apply hash route (deep-link to specific tab)
    _skipHashPush = true;
    applyHashRoute();
    _skipHashPush = false;
    window.addEventListener("hashchange", function() {
        _skipHashPush = true;
        applyHashRoute();
        _skipHashPush = false;
    });
    window.addEventListener("popstate", function() {
        _skipHashPush = true;
        applyHashRoute();
        _skipHashPush = false;
    });

    // Fetch system info (hostname, uptime, RAM, disk)
    fetchSystemInfo();

    refreshAll(false); // first load: show Loading immediately
    startAutoRefresh();

    // Adaptive polling: switch interval on visibility change
    document.addEventListener("visibilitychange", function() {
        startAutoRefresh();
    });

    // Event delegation for edit + modal + update + toggle
    document.addEventListener('click', function(e) {
        // Modal close button
        var closeBtn = e.target.closest('[data-modal-close]');
        if (closeBtn) {
            closeConfigModal();
            return;
        }
        // Modal reset-to-default button (per field)
        var resetBtn = e.target.closest('[data-reset-key]');
        if (resetBtn) {
            handleResetField(resetBtn);
            return;
        }
        // Modal Reset All button
        var resetAllBtn = e.target.closest('[data-reset-all]');
        if (resetAllBtn) {
            var resetSvcId = resetAllBtn.getAttribute('data-reset-all');
            handleResetAll(resetSvcId);
            return;
        }
        // Per-card Diagnostic button → open Route/DNS Check modal
        var diagBtn = e.target.closest('[data-diag]');
        if (diagBtn) {
            var diagType = diagBtn.getAttribute('data-diag');
            if (diagType === 'route') openRouteCheckModal();
            else if (diagType === 'dns') openDnsCheckModal();
            return;
        }
        // Per-card Edit button → open config modal
        var editBtn = e.target.closest('[data-edit]');
        if (editBtn) {
            var svcId = editBtn.getAttribute('data-edit');
            toggleConfigEditor(svcId);
            return;
        }
        // Config modal Save button
        var saveBtn = e.target.closest('[data-save-config]');
        if (saveBtn) {
            var saveSvcId = saveBtn.getAttribute('data-save-config');
            saveConfig(saveSvcId);
            return;
        }
        // Force-reload / flush-cache button (geo-split zones or webui cache)
        var btn = e.target.closest('.ew-update-btn');
        if (!btn || btn.disabled) return;
        var actionUrl = btn.getAttribute('data-action');
        btn.classList.add('ew-update-btn--spinning');
        btn.disabled = true;
        fetch(actionUrl, { method: 'POST' })
            .then(function(r) { return r.json(); })
            .then(function() {
                if (actionUrl.indexOf('geo-split') !== -1) {
                    geoPoller.start();
                } else {
                    btn.classList.remove('ew-update-btn--spinning');
                    btn.disabled = false;
                    refreshAll();
                }
            })
            .catch(function() {
                btn.classList.remove('ew-update-btn--spinning');
                btn.disabled = false;
            });
    });

    // Toggle switch event delegation
    document.addEventListener('change', function(e) {
        var toggle = e.target.closest('.ew-card-toggle input[type="checkbox"]');
        if (!toggle) return;
        var cardEl = toggle.closest('.dashboard-card');
        if (!cardEl) return;
        var serviceId = cardEl.id.replace('card-', '');
        handleToggle(serviceId, toggle);
    });
});
