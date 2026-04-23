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

/**
 * Format a snake_case key as Title Case label.
 * Strips _ok and _listening suffixes (state shown in value).
 * @param {string} key
 * @returns {string}
 */
function formatKey(key) {
    return key.replace(/_/g, " ").replace(/\b\w/g, function(c) { return c.toUpperCase(); });
}

/**
 * Format a boolean value: true → "Ok", false → "Fail".
 * @param {boolean} val
 * @returns {string}
 */
function formatBool(val) {
    return val ? "Ok" : "Fail";
}

// Updatable detail keys → POST action URL (only for geo-split)
var GEO_UPDATE_ACTIONS = {
    'geo_zone':       '/api/geo-split/update-subnets',
    'domain_sources': '/api/geo-split/update-domains'
};

var geoFastPollTimer = null;
var GEO_FAST_POLL = 1000;  // 1s when background update is running
var uptimeBaselines = {};  // { 'geo-split': { seconds: 12345, timestamp: Date.now() } }
var freshnessBaselines = {};  // { 'subnet_freshness': {seconds, timestamp}, ... }
var uptimeTickTimer = null;
/** Detail keys whose numeric values are seconds — formatted via formatUptimeStock() and live-ticked. */
var TIMER_KEYS = { subnet_freshness: 1, domain_freshness: 1 };

/**
 * Set structured details for a service card.
 * Iterates data.details keys in JSON order (matches status.sh text output).
 * Booleans rendered via formatBool() with contextual labels.
 * @param {string} id - service id
 * @param {Object} data - full JSON response from API
 */
function setDetails(id, data) {
    var el = document.getElementById("details-" + id);
    if (!el) return;
    if (!data.details) { el.innerHTML = ""; return; }

    var keys = Object.keys(data.details);
    var html = "";
    for (var i = 0; i < keys.length; i++) {
        var key = keys[i];
        // Keys starting with "_" are grid spacers — skip in list view
        if (key.charAt(0) === '_') continue;
        if (key === 'uptime') continue;
        var val = data.details[key];
        if (val === "" || val === null || val === undefined) continue;
        var valColor = "var(--primary-text)";
        if (typeof val === "boolean") {
            if (!val) valColor = "var(--error, #f44336)";
            val = formatBool(val);
        }
        // Timer fields: numeric seconds → formatted string
        if (typeof val === 'number' && TIMER_KEYS[key]) {
            val = formatUptimeStock(val);
        }
        var valHtml;
        var strVal = String(val);
        // Multi-line values: split on \n, "!" prefix → red line
        if (strVal.indexOf('\n') !== -1) {
            valHtml = strVal.split('\n').map(function(line) {
                if (line.charAt(0) === '!') return '<span style="color:var(--error,#f44336)">' + escapeHtml(line.substring(1)) + '</span>';
                return escapeHtml(line);
            }).join('<br>');
        } else {
            valHtml = '<span style="color:' + valColor + '">' + escapeHtml(strVal) + '</span>';
        }
        // Add update button for updatable geo-split fields
        var updateBtn = '';
        if (id === 'geo-split' && GEO_UPDATE_ACTIONS[key]) {
            updateBtn = ' <button class="ew-update-btn" data-action="' + GEO_UPDATE_ACTIONS[key] + '" data-tooltip="Force Reload">' +
                '<svg class="ndw-svg-icon svg-restart-dims" style="width:14px;height:14px;fill:currentColor"><use href="/assets/sprite/sprite.svg#restart"></use></svg></button>';
        }
        // Add data-freshness-key for live ticker on freshness fields
        var dataAttr = '';
        if (TIMER_KEYS[key]) {
            dataAttr = ' data-freshness-key="' + key + '"';
        }
        html += '<div class="ew-service-row">' +
            '<div class="ew-service-info">' +
            '<span style="color:var(--text-gray)">' + escapeHtml(formatKey(key)) + '</span>' +
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

    var serviceIds = ["geo-split", "smartdns", "smartdns-redirect", "webui"];
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
                    var uptimeSecs = data.details && data.details.uptime;
                    if (uptimeSecs) {
                        setStatus(id, "ok", "Running " + formatUptimeStock(uptimeSecs));
                    } else {
                        setStatus(id, "ok", "Running");
                    }
                } else {
                    setStatus(id, "fail", "Stopped");
                }
                setDetails(id, data);
                // Update uptime baseline
                if (data.running && data.details && data.details.uptime) {
                    uptimeBaselines[id] = { seconds: data.details.uptime, timestamp: Date.now() };
                } else {
                    delete uptimeBaselines[id];
                }
                // Update freshness baselines (timer keys)
                if (data.details) {
                    for (var tk in TIMER_KEYS) {
                        if (data.details[tk]) {
                            freshnessBaselines[tk] = { seconds: data.details[tk], timestamp: Date.now() };
                        }
                    }
                }
                // Start ticker if not running and at least one service has baseline
                if (!uptimeTickTimer && Object.keys(uptimeBaselines).length > 0) {
                    startUptimeTicker();
                }
                // Check geo-split background for fast polling
                if (id === 'geo-split' && data.details) {
                    if (data.details.background === 'running') {
                        startGeoFastPolling();
                    } else if (geoFastPollTimer) {
                        stopGeoFastPolling();
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

// ── Live uptime ticker ───────────────────────────────────────────────────────

/**
 * Format seconds as stock Keenetic uptime: "N DAYS HH:MM:SS" or "HH:MM:SS"
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

/** Start 1s ticker that updates all running status badges with live uptime + freshness. */
function startUptimeTicker() {
    if (uptimeTickTimer) return;
    uptimeTickTimer = setInterval(function() {
        var now = Date.now();
        // Update uptime badges
        for (var id in uptimeBaselines) {
            var bl = uptimeBaselines[id];
            var elapsed = Math.floor((now - bl.timestamp) / 1000);
            var currentSeconds = bl.seconds + elapsed;
            setStatus(id, "ok", "Running " + formatUptimeStock(currentSeconds));
        }
        // Update freshness counters
        for (var fkey in freshnessBaselines) {
            var fbl = freshnessBaselines[fkey];
            var fcurrent = fbl.seconds + Math.floor((now - fbl.timestamp) / 1000);
            var fEl = document.querySelector('[data-freshness-key="' + fkey + '"]');
            if (fEl) {
                fEl.textContent = formatUptimeStock(fcurrent);
            }
        }
    }, 1000);
}

/** Stop uptime ticker and clear baselines. */
function stopUptimeTicker() {
    if (uptimeTickTimer) {
        clearInterval(uptimeTickTimer);
        uptimeTickTimer = null;
    }
    uptimeBaselines = {};
    freshnessBaselines = {};
}

// ── Geo-split fast polling during background updates ─────────────────────────

/**
 * Start fast polling for geo-split only (1s).
 * Activated when background update is running.
 */
function startGeoFastPolling() {
    if (geoFastPollTimer) return;
    geoFastPollTimer = setInterval(function() {
        fetchStatus("/api/geo-split/status", "geo-split");
    }, GEO_FAST_POLL);
}

/**
 * Stop fast polling and remove spinning indicators.
 */
function stopGeoFastPolling() {
    if (!geoFastPollTimer) return;
    clearInterval(geoFastPollTimer);
    geoFastPollTimer = null;
    document.querySelectorAll('.ew-update-btn--spinning').forEach(function(btn) {
        btn.classList.remove('ew-update-btn--spinning');
        btn.disabled = false;
    });
}

// ── Refresh all ──────────────────────────────────────────────────────────────

/**
 * Refresh all service cards.
 */
function refreshAll() {
    fetchStatus("/api/geo-split/status", "geo-split");
    fetchStatus("/api/smartdns/status", "smartdns");
    fetchStatus("/api/smartdns-redirect/status", "smartdns-redirect");
    fetchStatus("/api/webui/status", "webui");
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

// ── Init ─────────────────────────────────────────────────────────────────────

document.addEventListener("DOMContentLoaded", function() {
    // Discover correct stock CSS URL (styles-*.css may change after firmware update)
    discoverStockCSS();

    refreshAll();
    startAutoRefresh();

    // Adaptive polling: switch interval on visibility change
    document.addEventListener("visibilitychange", function() {
        startAutoRefresh();
    });

    // Event delegation for update buttons
    document.addEventListener('click', function(e) {
        var btn = e.target.closest('.ew-update-btn');
        if (!btn || btn.disabled) return;
        var actionUrl = btn.getAttribute('data-action');
        btn.classList.add('ew-update-btn--spinning');
        btn.disabled = true;
        fetch(actionUrl, { method: 'POST' })
            .then(function(r) { return r.json(); })
            .then(function() {
                startGeoFastPolling();
            })
            .catch(function() {
                btn.classList.remove('ew-update-btn--spinning');
                btn.disabled = false;
            });
    });
});
