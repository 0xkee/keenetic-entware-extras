// Entware Extras Dashboard — vanilla JS frontend.
// Uses stock Keenetic DOM classes for native look.
// Renders structured JSON from status.sh --json.

"use strict";

var POLL_ACTIVE = 5000;       // 5s when page is visible
var POLL_BACKGROUND = 60000;  // 60s when hidden (background tab)
var FETCH_TIMEOUT = 15000;    // 15 seconds (allows for queued io.popen in nginx)

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
                    // Check badges: prefer checks map, fallback to detail boolean scan
                    var cs = EW.checksSummary(data.checks);
                    var hasFail = cs.hasFail || cs.hasWarn || EW.hasFailField(data.details);
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

// System info → moved to app-sysinfo.js (SYSINFO_ICONS, fetchSystemInfo)

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

    // Config editor event delegation → moved to config-editor.js
    initConfigEditorEvents();

    // Load interface label map before first status fetch to avoid
    // rendering raw Linux device names (race condition fix).
    // UI skeleton (buildUI) is shown immediately; status data waits for map.
    EW.loadIfaceMap().then(function() {
        refreshAll(false); // first load: show Loading immediately
        startAutoRefresh();
    });

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
        // Force-reload / flush-cache button (geo-split zones, cache flush)
        var btn = e.target.closest('.ew-update-btn');
        if (!btn || btn.disabled) return;
        var actionUrl = btn.getAttribute('data-action');
        btn.classList.add('ew-update-btn--spinning');
        btn.disabled = true;
        fetch(actionUrl, { method: 'POST' })
            .then(function(r) { return r.json(); })
            .then(function() {
                btn.classList.remove('ew-update-btn--spinning');
                btn.disabled = false;
                // Immediate feedback in field value
                var _label = actionUrl.indexOf('flush') !== -1 ? '\u2713 Flushed ' : '\u2713 Updating\u2026 ';
                var _p = btn.parentNode;
                if (_p) { for (var _n = _p.firstChild; _n; _n = _n.nextSibling) {
                    if (_n !== btn && (_n.nodeType === 3 || _n.nodeType === 1)) { _n.textContent = _label; break; }
                }}
                if (actionUrl.indexOf('geo-split') !== -1) {
                    geoPoller.start();
                } else {
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
