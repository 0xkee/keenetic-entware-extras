// Entware Extras Dashboard — vanilla JS frontend.
// Uses stock Keenetic DOM classes for native look.
// Renders structured JSON from status.sh --json.

"use strict";

var POLL_ACTIVE = 5000;       // 5s when page is visible
var POLL_BACKGROUND = 60000;  // 60s when hidden (background tab)
var FETCH_TIMEOUT = 15000;    // 15 seconds (allows for queued io.popen in nginx)

/** Key detail labels shown in Summary mode per service. Others are hidden via CSS. */
var SUMMARY_KEYS = {
    'geo-split':         ['geo_zone', 'active_zones', 'subnets', 'domains', 'route_out', 'gateway'],
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

// ── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Format a timestamp as HH:MM:SS.
 * @param {Date} date
 * @returns {string}
 */
function formatTime(date) {
    return date.toLocaleTimeString("ru-RU", { hour12: false });
}

/**
 * Escape HTML special characters.
 * @param {string} str
 * @returns {string}
 */
function escapeHtml(str) {
    return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// ── Status badge rendering ───────────────────────────────────────────────────

/**
 * Set status badge for a service card using stock ndw-status classes.
 * @param {string} id - service id
 * @param {"ok"|"warn"|"fail"|"error"|"loading"} state
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
    }

    el.innerHTML = '<div class="' + statusClass + '">' +
        iconHtml +
        '<div class="status__text">' + escapeHtml(text || "") + '</div>' +
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

    var entries = EW.parseDetails(data.details, { isRunning: data.running });
    var html = "";
    var summaryKeys = SUMMARY_KEYS[id] || [];
    for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        if (e.isSpacer) { html += '<div class="ew-detail-item"></div>'; continue; }
        var valStyle = e.isError ? ' style="color:var(--error,#f44336)"'
            : e.isWarning ? ' style="color:var(--status-caution-text,#ffbb57)"' : '';
        var valHtml;
        if (e.value === 'Ok') {
            valHtml = '<span class="ew-bool-icon ew-bool-icon--ok">\u2713</span>';
        } else if (e.value === 'Fail') {
            valHtml = '<span class="ew-bool-icon ew-bool-icon--fail">\u2717</span>';
        } else if (e.lines) {
            valHtml = e.lines.map(function(l) {
                return l.isError ? '<span style="color:var(--error,#f44336)">' + escapeHtml(l.text) + '</span>' : escapeHtml(l.text);
            }).join('<br>');
        } else if (/_provider$/.test(e.key) && data.dns_server_checks && data.dns_server_checks.length) {
            // Enrich DNS provider names with ✓/✗ reachability + clickable host link
            var provLines = e.value.split(' ').map(function(prov) {
                var chk = null;
                for (var ci = 0; ci < data.dns_server_checks.length; ci++) {
                    if (data.dns_server_checks[ci].provider === prov) { chk = data.dns_server_checks[ci]; break; }
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
            valHtml = '<div class="ew-dns-line">' + provLines.join('</div><div class="ew-dns-line">') + '</div>';
        } else if (e.value.indexOf(' ') !== -1 && !e.isTimer && (e.value.indexOf(':') !== -1 || /_provider$/.test(e.key))) {
            // Break long values with spaces+colons (ports, addresses) or DNS providers into lines
            valHtml = e.value.split(' ').map(function(s) { return escapeHtml(s); }).join('<br>');
        } else {
            valHtml = escapeHtml(e.value);
        }
        var isVersion = (e.label.toLowerCase() === 'version');
        if (isVersion) {
            valHtml = '<span class="ew-version-badge">' + escapeHtml(e.value) + '</span>';
        }
        var isNumericOnly = /^\d[\d,.]*[KMG]?[Bb]?$/.test(e.value.trim());
        var numClass = isNumericOnly ? ' ew-detail-value--numeric' : '';
        var updateBtn = '';
        if (e.updateAction) {
            updateBtn = ' <button class="ew-update-btn" data-action="' + e.updateAction + '" data-tooltip="Force Reload">' +
                '<svg class="ndw-svg-icon svg-restart-dims" style="width:14px;height:14px;fill:currentColor"><use href="/assets/sprite/sprite.svg#restart"></use></svg></button>';
        }
        var dataAttr = e.freshnessKey ? ' data-freshness-key="' + e.freshnessKey + '"' : '';
        // Determine priority for summary condensed mode
        var priority = (summaryKeys.indexOf(e.key) !== -1) ? 'high' : 'low';
        html += '<div class="ew-detail-item" data-priority="' + priority + '">' +
            '<div class="ew-detail-label">' + escapeHtml(e.label) + '</div>' +
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
                '<a class="ew-dns-link" href="https://' + escapeHtml(t.domain) + '" target="_blank" rel="noopener">' +
                escapeHtml(t.domain) + '</a> \u2192 ' + escapeHtml(t.result || 'FAILED'));
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
 * @param {boolean} running
 * @param {boolean} hasError
 */
function updateCardAccent(id, running, hasError) {
    var card = document.getElementById("card-" + id);
    if (!card) return;
    card.classList.remove("dashboard-card--running", "dashboard-card--stopped", "dashboard-card--error");
    if (hasError) card.classList.add("dashboard-card--error");
    else if (running) card.classList.add("dashboard-card--running");
    else card.classList.add("dashboard-card--stopped");
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

            // Structured JSON from status.sh --json
            if (data.running !== undefined) {
                // New structured format
                if (data.running) {
                    // Check if any detail field is false → caution badge
                    var hasFail = false;
                    if (data.details) {
                        var dkeys = Object.keys(data.details);
                        for (var di = 0; di < dkeys.length; di++) {
                            if (data.details[dkeys[di]] === false) { hasFail = true; break; }
                        }
                    }
                    var badgeState = hasFail ? "caution" : "ok";
                    var uptimeSecs = data.details && data.details.uptime;
                    if (uptimeSecs) {
                        setStatus(id, badgeState, "Running " + EW.formatUptimeStock(uptimeSecs));
                    } else {
                        setStatus(id, badgeState, "Running");
                    }
                } else {
                    setStatus(id, "fail", "Stopped");
                    updateCardAccent(id, false, false);
                }

                // Update toggle switch state
                var toggle = document.getElementById("toggle-" + id);
                if (toggle) {
                    toggle.checked = (typeof data.enabled === "boolean") ? data.enabled : data.running;
                    toggle.disabled = false;
                    // Stop fast-poller if state settled
                    if (togglePollers[id]) {
                        var expected = toggle.checked;
                        var actual = (typeof data.enabled === "boolean") ? data.enabled : data.running;
                        if (actual === expected) {
                            stopTogglePoller(id);
                        }
                    }
                }
                setDetails(id, data);
                updateCardAccent(id, data.running, hasFail);
                // Update uptime baseline (store badge state for ticker)
                if (data.running && data.details && data.details.uptime) {
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
                var el = document.getElementById("details-" + id);
                if (el) {
                    el.innerHTML = '<pre class="ew-details-pre">' + escapeHtml(data.output) + '</pre>';
                }
            } else if (data.error) {
                setStatus(id, "error", "Script error");
                var el2 = document.getElementById("details-" + id);
                if (el2) {
                    el2.innerHTML = '<pre class="ew-details-pre ew-details-pre--error">' + escapeHtml(data.error) + '</pre>';
                }
            } else {
                setStatus(id, "warn", "Unknown format");
            }
        })
        .catch(function(err) {
            clearTimeout(timer);
            // Ignore AbortError from superseded requests (new fetch replaced this one)
            if (err.name === "AbortError" && _inflightControllers[id] !== controller) return;
            _inflightControllers[id] = null;
            // Show error immediately — ticker CSS guard prevents overwrite
            ticker.removeUptimeBaseline(id);
            if (err.name === "AbortError") {
                setStatus(id, "error", "Timeout (" + (FETCH_TIMEOUT / 1000) + "s)");
            } else {
                setStatus(id, "error", escapeHtml(err.message));
            }
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
                    '<span class="ew-sysinfo__value">' + escapeHtml(data.hostname || "router") + '</span>' +
                '</span>' +
                '<span class="ew-sysinfo__item">' +
                    '<span class="ew-sysinfo__icon">' + SYSINFO_ICONS.up + '</span>' +
                    '<span class="ew-sysinfo__label">up</span>' +
                    '<span class="ew-sysinfo__value">' + escapeHtml(data.uptime || "?") + '</span>' +
                '</span>' +
                '<span class="ew-sysinfo__item">' +
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
        tab.innerHTML = '<div class="ndw-tabs__tab__label">' + escapeHtml(svc.label) + '</div>';
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
                '<button class="ndw-button ndw-button--toggle ndw-button--toggle-enabled ndw-button--small ndw-button--no-text ew-edit-btn" title="Edit Config" data-edit="' + svc.id + '">' +
                    '<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>' +
                '</button>';
        }

        card.innerHTML =
            '<div class="dashboard-card__header">' +
                '<div class="dashboard-card__header-left">' +
                    toggleHtml +
                    '<span class="text-card-heading">' + escapeHtml(svc.label.toUpperCase()) + '</span>' +
                '</div>' +
                '<div class="dashboard-card__header-buttons">' +
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

var TOGGLE_FAST_POLL = 1000;
var TOGGLE_POLL_TIMEOUT = 10000;
var togglePollers = {};

/**
 * Start fast polling for a service after toggle until state settles.
 * @param {string} serviceId
 * @param {boolean} targetRunning - expected state after toggle
 */
function startTogglePoller(serviceId, targetRunning) {
    stopTogglePoller(serviceId);
    var svc = null;
    for (var i = 0; i < EW.SERVICE_APIS.length; i++) {
        if (EW.SERVICE_APIS[i].id === serviceId) { svc = EW.SERVICE_APIS[i]; break; }
    }
    if (!svc) return;

    var startTime = Date.now();
    togglePollers[serviceId] = setInterval(function() {
        if (Date.now() - startTime > TOGGLE_POLL_TIMEOUT) {
            stopTogglePoller(serviceId);
            return;
        }
        fetchStatus(svc.api, serviceId, true);
    }, TOGGLE_FAST_POLL);
}

/**
 * Stop fast polling for a specific service.
 * @param {string} serviceId
 */
function stopTogglePoller(serviceId) {
    if (togglePollers[serviceId]) {
        clearInterval(togglePollers[serviceId]);
        delete togglePollers[serviceId];
    }
}

/**
 * Handle toggle switch change: POST start/stop, then fast-poll.
 * @param {string} serviceId
 * @param {HTMLInputElement} checkbox
 */
function handleToggle(serviceId, checkbox) {
    var action = checkbox.checked ? "start" : "stop";
    var targetRunning = checkbox.checked;
    checkbox.disabled = true;

    fetch("/api/" + serviceId + "/" + action, { method: "POST" })
        .then(function(r) { return r.json(); })
        .then(function(data) {
            checkbox.disabled = false;
            if (!data.ok) {
                // Revert toggle on failure
                checkbox.checked = !checkbox.checked;
            } else {
                startTogglePoller(serviceId, targetRunning);
            }
        })
        .catch(function() {
            checkbox.disabled = false;
            checkbox.checked = !checkbox.checked;
        });
}

// ── Config Editor (Modal Dialog) ─────────────────────────────────────────────

/** Config field definitions per service (schema for form rendering). */
var CONFIG_SCHEMAS = {
    'geo-split': [
        { key: 'GEO_ZONE', label: 'GeoIP Zone', type: 'zone_selector',
          desc: 'GeoIP zone for subnet routing: select countries or a geopolitical union (expands to multiple countries). All 240 country zones pre-packaged.' },
        { key: 'ROUTE_IN', label: 'Source Interfaces', type: 'iface_select', hint: 'LAN/tunnel interfaces for policy rules',
          desc: 'Source LAN/tunnel interfaces for ip rule iif (space-separated). Each interface gets its own ip rule \u2192 custom route table.' },
        { key: 'ROUTE_OUT', label: 'Outgoing Interface', type: 'iface_select', hint: 'Target outgoing interface for matched GEO traffic',
          preItems: [{ value: 'auto', label: 'Auto (ISP detect)' }],
          desc: '"auto" or empty = detect ISP automatically from default route. Explicit: "lte_br1" (ISP), "nwg0" (VPN), "ppp0", etc.' },
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
          preItems: [{ value: 'default', label: 'Default route' }, { value: '*', label: 'All VPNs (*)' }],
          desc: 'Outgoing interfaces to try for downloads (in order). "default" = system default route. "*" = auto-detect all active VPN interfaces.' },
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
        { key: 'ZONE_DNS_INTERFACE', label: 'Zone VPN Interface', type: 'iface_select', hint: 'Default = ISP direct',
          desc: 'Outgoing interface for zone DNS (Yandex/AdGuard). Default = ISP direct. Usually unchanged — MITM does not block.' },
        { key: 'OTHER_DNS_INTERFACES', label: 'International VPN Interfaces', type: 'iface_select', hint: 'Default = ISP direct',
          desc: 'Outgoing interfaces for international DNS. When set, DNS goes through VPN tunnel, bypassing TSPU/DPI.' },
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
                '<h2 class="ew-modal__title">' + escapeHtml(label) + ' \u2014 Settings</h2>' +
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
                body.innerHTML = '<div class="ew-editor-msg ew-editor-msg--error">Failed: ' + escapeHtml(configData.error || 'unknown') + '</div>';
                return;
            }

            // Cache defaults for reset and diff-save
            configDefaults[svcId] = configData.defaults || {};

            renderModalForm(body, svcId, schema, configData.config, configData.defaults || {}, ifacesData.interfaces || [], zonesData, providersData);
            if (footer) footer.style.display = '';
        })
        .catch(function(err) {
            body.innerHTML = '<div class="ew-editor-msg ew-editor-msg--error">Error: ' + escapeHtml(err.message) + '</div>';
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
    var keyAttr = opts.configKey ? ' data-config-key="' + escapeHtml(opts.configKey) + '"' : '';
    if (isMulti) {
        html += '<div class="ew-modal__iface-select"' + keyAttr + ' data-selection-order="' + escapeHtml(selArray.join(' ')) + '">';
    } else {
        html += '<div class="ew-modal__iface-select"' + keyAttr + '>';
    }
    // Trigger button
    html += '<button type="button" class="ew-modal__iface-select-trigger">' +
        '<span class="ew-modal__iface-select-text">' + escapeHtml(displayText) + '</span>' +
        '<svg class="ew-modal__select-arrow" width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M7 10l5 5 5-5z"/></svg></button>';
    // Panel
    html += '<div class="ew-modal__iface-select-panel ew-hidden">';
    // Search bar (always present)
    html += '<div class="ew-modal__iface-filter-wrap"><input type="text" class="ew-modal__iface-filter" placeholder="Search..." autocomplete="off"><span class="ew-modal__iface-filter-count"></span></div>';

    // Pre-items (special options with dot indicators, e.g. "Default route", "All VPNs")
    if (opts.preItems) {
        for (var pi = 0; pi < opts.preItems.length; pi++) {
            var pre = opts.preItems[pi];
            var preChk = selArray.indexOf(pre.value) !== -1;
            html += '<label class="ew-modal__iface-select-option">' +
                '<input type="checkbox" value="' + escapeHtml(pre.value) + '"' + (preChk ? ' checked' : '') + '>' +
                '<span class="ew-modal__iface-dot ew-modal__iface-dot--up"></span>' +
                '<span>' + escapeHtml(pre.label) + '</span></label>';
        }
    }

    // Grouped options (for unions)
    if (opts.groups) {
        for (var gi = 0; gi < opts.groups.length; gi++) {
            var grp = opts.groups[gi];
            html += '<div class="ew-modal__iface-select-group">' + escapeHtml(grp.group) + '</div>';
            var items = grp.items || [];
            for (var ui = 0; ui < items.length; ui++) {
                var u = items[ui];
                var uChk = (u.value === selVal);
                html += '<label class="ew-modal__iface-select-option">' +
                    '<input type="radio" name="' + escapeHtml(opts.radioName || '') + '" value="' + escapeHtml(u.value) + '"' + (uChk ? ' checked' : '') + '>' +
                    '<span>' + escapeHtml(u.label) + (u.desc ? ' (' + escapeHtml(u.desc) + ')' : '') + '</span></label>';
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
                html += '<input type="checkbox" value="' + escapeHtml(opt.value) + '"' + (mChk ? ' checked' : '') + '>';
                if (opts.dots && opts.ifaces) {
                    var ifc = null;
                    for (var ii = 0; ii < opts.ifaces.length; ii++) {
                        if (opts.ifaces[ii].name === opt.value) { ifc = opts.ifaces[ii]; break; }
                    }
                    var dotState = (ifc && ifc.up) ? 'up' : 'down';
                    html += '<span class="ew-modal__iface-dot ew-modal__iface-dot--' + dotState + '"></span>';
                }
                html += '<span>' + escapeHtml(opt.label) + (opt.desc ? ' \u2014 ' + escapeHtml(opt.desc) : '') + '</span></label>';
            } else {
                var sChk = (opt.value === selVal);
                html += '<label class="ew-modal__iface-select-option">' +
                    '<input type="radio" name="' + escapeHtml(opts.radioName || '') + '" value="' + escapeHtml(opt.value) + '"' + (sChk ? ' checked' : '') + '>' +
                    '<span>' + escapeHtml(opt.label) + (opt.desc ? ' \u2014 ' + escapeHtml(opt.desc) : '') + '</span></label>';
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
            helpHtml = '<span class="ew-modal__help" data-tooltip="' + escapeHtml(field.desc) + '">?</span>';
        }

        if (field.type === 'toggle') {
            // Toggle: row=[switch, label, help, reset], hint below
            var onVal = field.on || 'yes';
            var checked = (val === onVal || val === true) ? ' checked' : '';
            var toggleId = 'cfg-' + field.key;
            html += '<div class="ew-modal__toggle-row">';
            html += '<label class="ew-toggle ew-modal__toggle">' +
                '<input type="checkbox" id="' + toggleId + '" data-config-key="' + field.key + '" data-on-val="' + escapeHtml(field.on || 'yes') + '"' + checked + '>' +
                '<span class="ew-toggle__bar"></span></label>';
            html += '<label class="ew-modal__label ew-modal__label--clickable" for="' + toggleId + '">' + escapeHtml(field.label) + '</label>';
            html += helpHtml;
            html += '<button class="ew-modal__reset' + (isDefault ? ' ew-modal__reset--default' : '') + '" data-reset-key="' + field.key + '" data-reset-val="' + escapeHtml(String(defVal)) + '" data-tooltip="Reset to default:\n' + escapeHtml(String(defVal)) + '">' +
                '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M12.5 8c-2.65 0-5.05 1.04-6.83 2.73L3 8v8h8l-2.81-2.81C9.59 11.82 10.96 11 12.5 11c2.76 0 5.07 1.75 5.94 4.2l2.37-.78C19.63 10.96 16.35 8 12.5 8z"/></svg>' +
                '</button>';
            html += '</div>';
        } else {
            // Other fields: [header with label + help + reset] then input below
            html += '<div class="ew-modal__field-header">';
            html += '<label class="ew-modal__label">' + escapeHtml(field.label) + '</label>';
            html += helpHtml;
            html += '<button class="ew-modal__reset' + (isDefault ? ' ew-modal__reset--default' : '') + '" data-reset-key="' + field.key + '" data-reset-val="' + escapeHtml(String(defVal)) + '" data-tooltip="Reset to default:\n' + escapeHtml(String(defVal)) + '">' +
                '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M12.5 8c-2.65 0-5.05 1.04-6.83 2.73L3 8v8h8l-2.81-2.81C9.59 11.82 10.96 11 12.5 11c2.76 0 5.07 1.75 5.94 4.2l2.37-.78C19.63 10.96 16.35 8 12.5 8z"/></svg>' +
                '</button>';
            html += '</div>';
        }

        if (field.type === 'number') {
            html += '<input type="number" class="ew-modal__input" ' +
                'data-config-key="' + field.key + '" ' +
                'value="' + escapeHtml(String(val)) + '" ' +
                (field.min !== undefined ? 'min="' + field.min + '" ' : '') +
                (field.max !== undefined ? 'max="' + field.max + '" ' : '') + '>';
        } else if (field.type === 'text') {
            html += '<input type="text" class="ew-modal__input" ' +
                'data-config-key="' + field.key + '" ' +
                'value="' + escapeHtml(String(val)) + '">';
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
                    '<input type="radio" name="rt-' + field.key + '" value="' + escapeHtml(pr.value) + '"' + prChecked + '>' +
                    '<span class="ew-modal__radio-label">' + escapeHtml(pr.label) + '</span>' +
                    '</label>';
            }
            var customChecked = !isPreset ? ' checked' : '';
            var customVal = !isPreset ? escapeHtml(String(val)) : '';
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
            // Interface multi-select (sorted: up first, then down, alphabetically)
            var sortedIfaces = interfaces.slice().sort(function(a, b) {
                if (a.up !== b.up) return a.up ? -1 : 1;
                return (a.name || '').localeCompare(b.name || '');
            });
            var selectedIfs = String(val).split(/\s+/).filter(function(s) { return s; });
            var ifDisplayText = selectedIfs.length ? selectedIfs.join(', ') : (field.preItems ? field.preItems[0].label : 'Default');
            var ifaceOpts = [];
            for (var si = 0; si < sortedIfaces.length; si++) {
                ifaceOpts.push({ value: sortedIfaces[si].name, label: sortedIfaces[si].label || sortedIfaces[si].name });
            }
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
        }

        if (field.hint) {
            html += '<span class="ew-modal__hint">' + escapeHtml(field.hint) + '</span>';
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
            val = isContainer ? (isContainer.dataset.selectionOrder || '') : '';
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
                var spanEl = labelEl ? labelEl.querySelector('span') : null;
                trigger.textContent = spanEl ? spanEl.textContent : (defVal || 'Default');
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
            if (trigger2) trigger2.textContent = defIfs.length ? defIfs.join(', ') : 'Default';
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
                var spanText = label.querySelector('span');
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
            if (textEl2) textEl2.textContent = currentOrder.length ? currentOrder.join(', ') : 'Default';
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
        // Geo-split force-reload button
        var btn = e.target.closest('.ew-update-btn');
        if (!btn || btn.disabled) return;
        var actionUrl = btn.getAttribute('data-action');
        btn.classList.add('ew-update-btn--spinning');
        btn.disabled = true;
        fetch(actionUrl, { method: 'POST' })
            .then(function(r) { return r.json(); })
            .then(function() {
                geoPoller.start();
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
