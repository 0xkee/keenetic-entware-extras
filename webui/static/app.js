// Entware Extras Dashboard — vanilla JS frontend.
// Uses stock Keenetic DOM classes for native look.
// Renders structured JSON from status.sh --json.

"use strict";

var POLL_ACTIVE = 5000;       // 5s when page is visible
var POLL_BACKGROUND = 60000;  // 60s when hidden (background tab)
var FETCH_TIMEOUT = 15000;    // 15 seconds (allows for queued io.popen in nginx)

/** Key detail labels shown in Summary mode per service. Others are hidden via CSS. */
var SUMMARY_KEYS = {
    'geo-split':         ['geo_zone', 'subnets', 'domains', 'route_out', 'gateway'],
    'smartdns':          ['ports', 'rules'],
    'smartdns-redirect': ['interfaces', 'upstream'],
    'webui':             ['ports', 'http']
};

/** Get skeleton count for a service: cached from last API response, or default 6. */
function getSkeletonCount(id) {
    try {
        var cached = JSON.parse(localStorage.getItem('ew-skel-counts') || '{}');
        return cached[id] || 6;
    } catch (e) { return 6; }
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
        } else if (e.value.indexOf(' ') !== -1 && e.value.indexOf(':') !== -1 && !e.isTimer) {
            // Break long values with spaces+colons (ports, addresses) into lines
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
    // Cache real field count for next page load skeleton rendering
    var realCount = entries.filter(function(e) { return !e.isSpacer; }).length;
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

    // Update URL hash (without triggering hashchange re-entry)
    var newHash = (tabId === "all") ? "" : "#" + tabId;
    if (window.location.hash !== newHash) {
        history.replaceState(null, "", newHash || window.location.pathname);
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
                diskPct = Math.round((data.disk_opt.used_kb / data.disk_opt.total_kb) * 100);
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
                '<span class="ew-sysinfo__item" title="' +
                    'Available: ' + Math.round(data.memory.available_kb / 1024) + ' MB / ' + Math.round(data.memory.total_kb / 1024) + ' MB\n' +
                    'Conservative estimate — accounts for memory locked by kernel (conntrack, routing tables, slab cache) that cannot be freed.\n' +
                    'May show ~15% higher usage than stock UI — this is normal and not a cause for concern.' + '">' +
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
        { key: 'ROUTE_IN', label: 'Source Interfaces', type: 'interfaces', hint: 'LAN/tunnel interfaces for policy rules',
          desc: 'Source LAN/tunnel interfaces for ip rule iif (space-separated). Each interface gets its own ip rule \u2192 custom route table.' },
        { key: 'ROUTE_OUT', label: 'Outgoing Interface', type: 'interface', hint: 'Target outgoing interface for matched GEO traffic',
          desc: '"auto" or empty = detect ISP automatically from default route. Explicit: "lte_br1" (ISP), "nwg0" (VPN), "ppp0", etc.' },
        { key: 'ROUTE_GW', label: 'Gateway', type: 'radio_text', hint: 'Gateway (nexthop) for routes in geo-split tables',
          presets: [{ value: 'auto', label: 'Auto (from route)' }, { value: 'none', label: 'None (dev-only)' }],
          desc: '"auto" = detect from default route of ROUTE_OUT interface. On point-to-point interfaces (LTE/PPP) auto returns empty \u2192 routes without gateway (correct for those types).' },
        { key: 'SUBNET_LOADER', label: 'Subnet Loader', type: 'select',
          options: [{ value: 'cidr-plain', label: 'CIDR Plain' }, { value: 'ripe-json', label: 'RIPE JSON (requires jq)' }],
          hint: 'Format parser for downloaded list',
          desc: 'Available loaders: cidr-plain (default, one CIDR per line), ripe-json (RIPE stat JSON, requires jq).' },
        { key: 'SUBNET_URL', label: 'Subnet List URL', type: 'text', hint: 'GeoIP CIDR list URL',
          desc: 'URL to fetch GEO IP subnets (plain CIDR list). Default: ipdeny.com RU zone (based on RIR allocations).' },
        { key: 'SUBNET_AGGREGATE', label: 'Aggregate CIDRs', type: 'toggle', on: '1', off: '0', hint: 'Merge adjacent subnets \u2192 fewer routes',
          desc: 'Aggregate (merge) adjacent/overlapping CIDR subnets after download. Reduces route entries count.' },
        { key: 'DOWNLOAD_INTERFACES', label: 'Download Interfaces', type: 'interfaces', hint: 'Interfaces for subnet/zone downloads',
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
        { key: 'SMARTDNS_PORT', label: 'SmartDNS Port', type: 'number', min: 1, max: 65535, hint: 'Listen port (default 6053)',
          desc: 'SmartDNS listen port (main, used for DNS tests).' }
    ],
    'smartdns-redirect': [
        { key: 'UPSTREAM_PORT', label: 'Upstream Port', type: 'number', min: 1, max: 65535, hint: 'SmartDNS=6053, AGH=5353, Unbound=5335',
          desc: 'Port to redirect DNS traffic to (local DNS on router).' },
        { key: 'INTERFACES', label: 'Interfaces', type: 'interfaces', hint: 'LAN interfaces to intercept DNS on',
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
    'smartdns': 'SmartDNS Config',
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
    if (e.key === 'Escape') closeConfigModal();
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

    Promise.all([configPromise, ifacesPromise])
        .then(function(results) {
            var configData = results[0];
            var ifacesData = results[1];

            if (!configData.ok) {
                body.innerHTML = '<div class="ew-editor-msg ew-editor-msg--error">Failed: ' + escapeHtml(configData.error || 'unknown') + '</div>';
                return;
            }

            // Cache defaults for reset and diff-save
            configDefaults[svcId] = configData.defaults || {};

            renderModalForm(body, svcId, schema, configData.config, configData.defaults || {}, ifacesData.interfaces || []);
            if (footer) footer.style.display = '';
        })
        .catch(function(err) {
            body.innerHTML = '<div class="ew-editor-msg ew-editor-msg--error">Error: ' + escapeHtml(err.message) + '</div>';
        });
}

/**
 * Render form fields inside modal body.
 * @param {HTMLElement} body
 * @param {string} svcId
 * @param {Array} schema
 * @param {Object} config - current merged values
 * @param {Object} defaults - default values
 * @param {Array} interfaces
 */
function renderModalForm(body, svcId, schema, config, defaults, interfaces) {
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
            html += '<button class="ew-modal__reset' + (isDefault ? ' ew-modal__reset--default' : '') + '" data-reset-key="' + field.key + '" data-reset-val="' + escapeHtml(String(defVal)) + '" title="Reset to default: ' + escapeHtml(String(defVal)) + '">' +
                '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M12.5 8c-2.65 0-5.05 1.04-6.83 2.73L3 8v8h8l-2.81-2.81C9.59 11.82 10.96 11 12.5 11c2.76 0 5.07 1.75 5.94 4.2l2.37-.78C19.63 10.96 16.35 8 12.5 8z"/></svg>' +
                '</button>';
            html += '</div>';
        } else {
            // Other fields: [header with label + help + reset] then input below
            html += '<div class="ew-modal__field-header">';
            html += '<label class="ew-modal__label">' + escapeHtml(field.label) + '</label>';
            html += helpHtml;
            html += '<button class="ew-modal__reset' + (isDefault ? ' ew-modal__reset--default' : '') + '" data-reset-key="' + field.key + '" data-reset-val="' + escapeHtml(String(defVal)) + '" title="Reset to default: ' + escapeHtml(String(defVal)) + '">' +
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
        } else if (field.type === 'interfaces') {
            var selectedIfaces = String(val).split(/\s+/).filter(function(s) { return s; });
            html += '<div class="ew-modal__ifaces" data-config-key="' + field.key + '">';
            // Pre-items (static options like "default", "*")
            if (field.preItems) {
                for (var pi = 0; pi < field.preItems.length; pi++) {
                    var pre = field.preItems[pi];
                    var preChecked = selectedIfaces.indexOf(pre.value) !== -1;
                    html += '<label class="ew-modal__iface-item">' +
                        '<input type="checkbox" value="' + escapeHtml(pre.value) + '"' + (preChecked ? ' checked' : '') + '>' +
                        '<span class="ew-modal__iface-dot ew-modal__iface-dot--up"></span>' +
                        '<span class="ew-modal__iface-name">' + escapeHtml(pre.label) + '</span>' +
                        '</label>';
                }
            }
            for (var j = 0; j < interfaces.length; j++) {
                var iface = interfaces[j];
                var isChecked = selectedIfaces.indexOf(iface.name) !== -1;
                var stateClass = iface.up ? 'up' : 'down';
                html += '<label class="ew-modal__iface-item">' +
                    '<input type="checkbox" value="' + escapeHtml(iface.name) + '"' + (isChecked ? ' checked' : '') + '>' +
                    '<span class="ew-modal__iface-dot ew-modal__iface-dot--' + stateClass + '"></span>' +
                    '<span class="ew-modal__iface-name">' + escapeHtml(iface.label || iface.name) + '</span>' +
                    '</label>';
            }
            html += '</div>';
        } else if (field.type === 'interface') {
            // Single-select interface: radio pills (auto + interfaces)
            html += '<div class="ew-modal__ifaces ew-modal__ifaces--radio" data-config-key="' + field.key + '">';
            var radioName = 'radio-' + field.key;
            var isAutoSelected = (val === 'auto' || val === '');
            html += '<label class="ew-modal__iface-item">' +
                '<input type="radio" name="' + radioName + '" value="auto"' + (isAutoSelected ? ' checked' : '') + '>' +
                '<span class="ew-modal__iface-dot ew-modal__iface-dot--up"></span>' +
                '<span class="ew-modal__iface-name">Auto (ISP detect)</span>' +
                '</label>';
            for (var m = 0; m < interfaces.length; m++) {
                var ri = interfaces[m];
                var riChecked = (ri.name === val) ? ' checked' : '';
                var riState = ri.up ? 'up' : 'down';
                html += '<label class="ew-modal__iface-item">' +
                    '<input type="radio" name="' + radioName + '" value="' + escapeHtml(ri.name) + '"' + riChecked + '>' +
                    '<span class="ew-modal__iface-dot ew-modal__iface-dot--' + riState + '"></span>' +
                    '<span class="ew-modal__iface-name">' + escapeHtml(ri.label || ri.name) + '</span>' +
                    '</label>';
            }
            html += '</div>';
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
            html += '<div class="ew-modal__select-wrap">';
            html += '<select class="ew-modal__select" data-config-key="' + field.key + '">';
            for (var k = 0; k < field.options.length; k++) {
                var opt = field.options[k];
                var selected = (opt.value === String(val)) ? ' selected' : '';
                html += '<option value="' + escapeHtml(opt.value) + '"' + selected + '>' + escapeHtml(opt.label) + '</option>';
            }
            html += '</select>';
            html += '<svg class="ew-modal__select-arrow" width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M7 10l5 5 5-5z"/></svg>';
            html += '</div>';
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
        } else if (field.type === 'interfaces') {
            var container = modal.querySelector('[data-config-key="' + field.key + '"]');
            var checkedBoxes = container ? container.querySelectorAll('input[type="checkbox"]:checked') : [];
            var ifaces = [];
            for (var j = 0; j < checkedBoxes.length; j++) {
                ifaces.push(checkedBoxes[j].value);
            }
            val = ifaces.join(' ');
        } else if (field.type === 'interface') {
            var radioContainer = modal.querySelector('[data-config-key="' + field.key + '"]');
            var selectedRadio = radioContainer ? radioContainer.querySelector('input[type="radio"]:checked') : null;
            val = selectedRadio ? selectedRadio.value : 'auto';
        } else if (field.type === 'radio_text') {
            var rtContainer = modal.querySelector('[data-config-key="' + field.key + '"]');
            var selRadio = rtContainer ? rtContainer.querySelector('input[type="radio"]:checked') : null;
            if (selRadio && selRadio.value === '__custom__') {
                var txtInput = rtContainer.querySelector('.ew-modal__radio-input');
                val = txtInput ? txtInput.value : '';
            } else {
                val = selRadio ? selRadio.value : '';
            }
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
    } else if (el.tagName === 'DIV' && el.classList.contains('ew-modal__ifaces--radio')) {
        // Single-select interface (radio pills)
        var radios = el.querySelectorAll('input[type="radio"]');
        for (var i = 0; i < radios.length; i++) {
            radios[i].checked = (radios[i].value === defVal);
        }
    } else if (el.tagName === 'DIV' && el.classList.contains('ew-modal__ifaces')) {
        // Multi-select interfaces (checkbox pills)
        var defIfaces = defVal.split(/\s+/);
        var boxes = el.querySelectorAll('input[type="checkbox"]');
        for (var i = 0; i < boxes.length; i++) {
            boxes[i].checked = defIfaces.indexOf(boxes[i].value) !== -1;
        }
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

    // radio_text: clicking on IP text input auto-selects custom radio
    document.addEventListener('focus', function(e) {
        if (!e.target.classList || !e.target.classList.contains('ew-modal__radio-input')) return;
        var rtWrap = e.target.closest('.ew-modal__radio-text');
        if (!rtWrap) return;
        var customRadio = rtWrap.querySelector('input[value="__custom__"]');
        if (customRadio && !customRadio.checked) {
            customRadio.checked = true;
            e.target.disabled = false;
        }
    }, true);

    // Discover correct stock CSS URL (styles-*.css may change after firmware update)
    discoverStockCSS();

    // Generate tabs + cards from SERVICE_APIS (single source of truth)
    buildUI();

    // Apply hash route (deep-link to specific tab)
    applyHashRoute();
    window.addEventListener("hashchange", applyHashRoute);

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
