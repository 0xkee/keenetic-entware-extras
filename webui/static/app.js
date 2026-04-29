// Entware Extras Dashboard — vanilla JS frontend.
// Uses stock Keenetic DOM classes for native look.
// Renders structured JSON from status.sh --json.

"use strict";

var POLL_ACTIVE = 5000;       // 5s when page is visible
var POLL_BACKGROUND = 60000;  // 60s when hidden (background tab)
var FETCH_TIMEOUT = 10000;    // 10 seconds

var autoRefreshTimer = null;
var activeTab = "all";

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
    return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
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

    if (state === "ok") {
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

/** Ticker for live uptime/freshness counters — updates status badges. */
var ticker = EW.createTicker(function(id, currentSeconds, extra) {
    setStatus(id, (extra && extra.state) || "ok", "Running " + EW.formatUptimeStock(currentSeconds));
});

/** Fast poller for geo-split during background updates. */
var geoPoller = EW.createPoller(
    function() { fetchStatus("/api/geo-split/status", "geo-split"); },
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
    for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        if (e.isSpacer) continue;
        var valColor = e.isError ? "var(--error, #f44336)" : "var(--primary-text)";
        var valHtml;
        if (e.lines) {
            valHtml = e.lines.map(function(l) {
                return l.isError ? '<span style="color:var(--error,#f44336)">' + escapeHtml(l.text) + '</span>' : escapeHtml(l.text);
            }).join('<br>');
        } else {
            valHtml = '<span style="color:' + valColor + '">' + escapeHtml(e.value) + '</span>';
        }
        var updateBtn = '';
        if (e.updateAction) {
            updateBtn = ' <button class="ew-update-btn" data-action="' + e.updateAction + '" data-tooltip="Force Reload">' +
                '<svg class="ndw-svg-icon svg-restart-dims" style="width:14px;height:14px;fill:currentColor"><use href="/assets/sprite/sprite.svg#restart"></use></svg></button>';
        }
        var dataAttr = e.freshnessKey ? ' data-freshness-key="' + e.freshnessKey + '"' : '';
        html += '<div class="ew-service-row">' +
            '<div class="ew-service-info">' +
            '<span style="color:var(--text-gray)">' + escapeHtml(e.label) + '</span>' +
            '</div>' +
            '<span' + dataAttr + '>' + valHtml + '</span>' + updateBtn +
            '</div>';
    }
    el.innerHTML = html;
}

// ── Tab switching ────────────────────────────────────────────────────────────

/**
 * Switch active tab and show/hide service cards accordingly.
 * @param {string} tabId - "all", "geo-split", "smartdns", "smartdns-redirect"
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
}

// ── Fetch status ─────────────────────────────────────────────────────────────

/**
 * Fetch structured JSON from status API and render card.
 * @param {string} url - API URL
 * @param {string} id - service id
 */
function fetchStatus(url, id) {
    setStatus(id, "loading", "Loading...");

    var controller = new AbortController();
    var timer = setTimeout(function() { controller.abort(); }, FETCH_TIMEOUT);

    fetch(url, { signal: controller.signal })
        .then(function(resp) {
            clearTimeout(timer);
            if (!resp.ok) {
                setStatus(id, "error", "HTTP " + resp.status);
                return;
            }
            return resp.json();
        })
        .then(function(data) {
            if (!data) return;

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
                }
                setDetails(id, data);
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
            } else {
                setStatus(id, "warn", "Unknown format");
            }
        })
        .catch(function(err) {
            clearTimeout(timer);
            if (err.name === "AbortError") {
                setStatus(id, "error", "Timeout (" + (FETCH_TIMEOUT / 1000) + "s)");
            } else {
                setStatus(id, "error", "Error: " + err.message);
            }
        });
}

// ── Refresh all ──────────────────────────────────────────────────────────────

/**
 * Refresh all service cards.
 */
function refreshAll() {
    EW.SERVICE_APIS.forEach(function(svc) {
        fetchStatus(svc.api, svc.id);
    });
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

    // "All Services" tab
    var allTab = document.createElement("div");
    allTab.tabIndex = 0;
    allTab.className = "ndw-tabs__tab ndw-tabs__tab--active";
    allTab.id = "tab-all";
    allTab.setAttribute("role", "tab");
    allTab.setAttribute("aria-selected", "true");
    allTab.innerHTML = '<div class="ndw-tabs__tab__label">All Services</div>';
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

        // Card
        var card = document.createElement("div");
        card.className = "dashboard-card";
        card.id = "card-" + svc.id;
        card.innerHTML =
            '<div class="dashboard-card__header">' +
                '<span class="text-card-heading">' + escapeHtml(svc.label.toUpperCase()) + '</span>' +
                '<div class="dashboard-card__header-buttons">' +
                    '<button class="ndw-button ndw-button--toggle ndw-button--toggle-enabled ndw-button--small ndw-button--no-text" title="Refresh" data-refresh="' + svc.id + '">\u27F3</button>' +
                '</div>' +
            '</div>' +
            '<div class="dashboard-card__content" id="content-' + svc.id + '">' +
                '<div class="ew-service-row"><div class="ew-service-info">' +
                    '<div class="ndw-status ndw-status--chip" id="status-' + svc.id + '">' +
                        '<div class="status"><div class="status__text">Loading...</div></div>' +
                    '</div>' +
                '</div></div>' +
                '<div id="details-' + svc.id + '"></div>' +
            '</div>';
        cardsContainer.appendChild(card);
    });
}

// ── Init ─────────────────────────────────────────────────────────────────────

document.addEventListener("DOMContentLoaded", function() {
    // Discover correct stock CSS URL (styles-*.css may change after firmware update)
    discoverStockCSS();

    // Generate tabs + cards from SERVICE_APIS (single source of truth)
    buildUI();

    refreshAll();
    startAutoRefresh();

    // Adaptive polling: switch interval on visibility change
    document.addEventListener("visibilitychange", function() {
        startAutoRefresh();
    });

    // Event delegation for refresh + update buttons
    document.addEventListener('click', function(e) {
        // Per-card refresh button
        var refreshBtn = e.target.closest('[data-refresh]');
        if (refreshBtn) {
            var svcId = refreshBtn.getAttribute('data-refresh');
            for (var i = 0; i < EW.SERVICE_APIS.length; i++) {
                if (EW.SERVICE_APIS[i].id === svcId) {
                    fetchStatus(EW.SERVICE_APIS[i].api, svcId);
                    break;
                }
            }
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
});
