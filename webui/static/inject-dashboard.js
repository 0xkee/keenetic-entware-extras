// inject-dashboard.js — Dashboard card service rows, status parsing, and polling
// for stock Keenetic pages. Attached to EW._dash namespace.
// Depends on: shared.js (EW), detail-render.js (EW.renderRulesDetail, EW.renderDnsTests)
(function() {
    'use strict';
    try {

    // ═══════════════════════════════════════════════════════════════════
    // §1. CONSTANTS
    // ═══════════════════════════════════════════════════════════════════

    /** Keys excluded from dashboard detail grid (shown elsewhere or irrelevant). */
    var DETAILS_SKIP_KEYS = { uptime: 1, version: 1, pid: 1, background: 1 };

    /** Expected detail cell counts per service (skeleton placeholder sizing). */
    var DASH_SKELETON_COUNTS = { 'geo-split': 16, 'smartdns': 10, 'smartdns-redirect': 8, 'webui': 9 };

    /** Fast polling interval after toggle / background update (ms). */
    var TOGGLE_FAST_POLL = 1000;

    // ═══════════════════════════════════════════════════════════════════
    // §2. MUTABLE STATE — set by init()
    // ═══════════════════════════════════════════════════════════════════

    var _ticker = null;
    var _geoPoller = null;
    var _togglePoller = null;
    var _showInContent = null;
    var _dashboardTimer = null;
    var _dashboardInjected = false;
    var _pollInterval = 30000;

    /**
     * Initialize dashboard module with references to shared pollers and callbacks.
     * Must be called once from inject.js after poller creation.
     * @param {Object} opts
     * @param {Object} opts.ticker - EW.createTicker() instance
     * @param {Object} opts.geoPoller - EW.createPoller() instance for geo-split
     * @param {Object} opts.togglePoller - EW.createTogglePoller() instance
     * @param {Function} opts.showInContent - callback to show custom page in iframe
     * @param {number} [opts.pollInterval=30000] - dashboard status poll interval (ms)
     */
    function init(opts) {
        _ticker = opts.ticker;
        _geoPoller = opts.geoPoller;
        _togglePoller = opts.togglePoller;
        _showInContent = opts.showInContent;
        _pollInterval = opts.pollInterval || 30000;
    }

    // ═══════════════════════════════════════════════════════════════════
    // §3. SERVICE ROW DOM
    // ═══════════════════════════════════════════════════════════════════

    /**
     * Build a single service row for the dashboard card.
     * Layout matches stock: [toggle] [title + description + status chip].
     * @param {{id: string, label: string, desc: string, url: string}} svc
     * @returns {DocumentFragment}
     */
    function buildServiceRow(svc) {
        // Wrapper fragment (row + details live together)
        var frag = document.createDocumentFragment();

        var row = document.createElement('div');
        row.className = 'ew-dash-row';
        row.id = 'ew-dash-' + svc.id;

        // Toggle switch — connected to start/stop API
        var toggle = document.createElement('label');
        toggle.className = 'ew-toggle';
        var cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.checked = true;
        cb.setAttribute('aria-label', svc.label);
        var bar = document.createElement('div');
        bar.className = 'ew-toggle__bar';
        toggle.appendChild(cb);
        toggle.appendChild(bar);

        // Wire toggle to POST /api/{service}/start|stop (skip webui — can't stop own server)
        if (svc.id !== 'webui') {
            cb.addEventListener('change', function() {
                var action = cb.checked ? 'start' : 'stop';
                var targetRunning = cb.checked;
                cb.disabled = true;
                bar.style.opacity = '0.5';
                fetch('/api/' + svc.id + '/' + action, { method: 'POST' })
                    .then(function(r) { return r.json(); })
                    .then(function(data) {
                        cb.disabled = false;
                        bar.style.opacity = '';
                        if (!data.ok) {
                            cb.checked = !cb.checked;
                        } else {
                            startTogglePoller(svc.id, targetRunning);
                        }
                    })
                    .catch(function() {
                        cb.disabled = false;
                        bar.style.opacity = '';
                        cb.checked = !cb.checked;
                    });
            });
        } else {
            cb.disabled = true;  // webui toggle always locked
        }

        // Info block: title + description + status chip
        var info = document.createElement('div');
        info.className = 'ew-dash-info';

        var title = document.createElement('span');
        title.className = 'ew-dash-title';
        title.textContent = svc.label;
        title.addEventListener('click', function(e) {
            e.preventDefault();
            if (_showInContent) _showInContent({ id: svc.id, url: svc.url });
        });

        var desc = document.createElement('div');
        desc.className = 'ew-dash-desc';
        desc.textContent = svc.desc || '';

        var chip = document.createElement('div');
        chip.className = 'ew-chip ew-chip--stopped';
        chip.innerHTML = '<span class="ew-chip__dot"></span> LOADING\u2026';

        info.appendChild(title);
        info.appendChild(desc);
        info.appendChild(chip);

        // Expand button (4-square grid icon)
        var expandBtn = document.createElement('button');
        expandBtn.className = 'ew-expand-btn';
        expandBtn.title = 'Details';
        expandBtn.innerHTML =
            '<svg viewBox="0 0 20 20">' +
            '<rect x="2" y="2" width="6" height="6" rx="1" stroke-width="1.5"/>' +
            '<rect x="12" y="2" width="6" height="6" rx="1" stroke-width="1.5"/>' +
            '<rect x="2" y="12" width="6" height="6" rx="1" stroke-width="1.5"/>' +
            '<rect x="12" y="12" width="6" height="6" rx="1" stroke-width="1.5"/></svg>';

        // Details grid (hidden by default)
        var details = document.createElement('div');
        details.className = 'ew-details';
        details.id = 'ew-details-' + svc.id;

        // Pre-fill skeleton placeholders (replaced on first fetch)
        var skelCount = DASH_SKELETON_COUNTS[svc.id] || 9;
        var skelHtml = '';
        for (var si = 0; si < skelCount; si++) {
            skelHtml += '<div class="ew-detail-item"><div class="ew-skeleton ew-skeleton--short"></div><div class="ew-skeleton ew-skeleton--medium" style="margin-top:4px"></div></div>';
        }
        details.innerHTML = skelHtml;

        // Restore expand state from localStorage
        var storageKey = 'ew-expand-' + svc.id;
        if (localStorage.getItem(storageKey) === '1') {
            details.classList.add('ew-details--open');
            expandBtn.classList.add('ew-expand-btn--active');
        }

        expandBtn.addEventListener('click', function() {
            var isOpen = details.classList.toggle('ew-details--open');
            expandBtn.classList.toggle('ew-expand-btn--active', isOpen);
            localStorage.setItem(storageKey, isOpen ? '1' : '0');
        });

        row.appendChild(toggle);
        row.appendChild(info);
        row.appendChild(expandBtn);

        frag.appendChild(row);
        frag.appendChild(details);

        return frag;
    }

    /**
     * Build only the dashboard content — service rows in a wrapper div.
     * Does NOT create the full card/header structure.
     * @returns {HTMLDivElement} #entware-dash-content wrapper
     */
    function buildEntwareDashboardContent() {
        var wrapper = document.createElement('div');
        wrapper.id = 'entware-dash-content';
        wrapper.className = 'ew-dash-content ew-loading';
        EW.SERVICE_APIS.forEach(function(svc) {
            wrapper.appendChild(buildServiceRow(svc));
        });
        return wrapper;
    }

    // ═══════════════════════════════════════════════════════════════════
    // §4. STATUS PARSING & DATA APPLICATION
    // ═══════════════════════════════════════════════════════════════════

    /**
     * Build status chip text from structured data.
     * Returns "caution" state if running but any check is fail/warn.
     * Uses data.checks if available, falls back to detail field === false.
     * @param {Object} data - full API response
     * @returns {{state: string, text: string}}
     */
    function parseServiceStatus(data) {
        // Pending response (cache warming) — signal to not update chip
        if (data.status === "pending" && data.running === undefined) {
            return { state: 'pending', text: '' };
        }
        var state = data.running ? 'running' : 'stopped';
        // Distinguish: service crashed (enabled but not running) vs user disabled
        if (!data.running && !data.error) {
            if (typeof data.enabled === 'boolean' && data.enabled) {
                state = 'error';  // Should be running but isn't → red
            }
            // else: stopped (gray) — default from line above
        }
        // Handle error/unknown response from api-router
        if (!data.running && data.error) {
            state = 'stale';  // Unknown state, not a real "error"
        }
        // Determine chip state from checks or fallback
        if (data.running) {
            if (data.checks) {
                var cs = EW.checksSummary(data.checks);
                if (cs.hasFail || cs.hasWarn) {
                    state = 'caution';
                }
            } else if (EW.hasFailField(data.details)) {
                state = 'caution';
            }
        }
        // Services with "enabled" field: running but disabled → grey "Disabled"
        if (data.running && typeof data.enabled === 'boolean' && !data.enabled) {
            state = 'stopped';
        }
        var text = data.running ? 'RUNNING' : 'STOPPED';
        if (data.running && typeof data.enabled === 'boolean' && !data.enabled) {
            text = 'DISABLED';
        }
        if (data.running && !(typeof data.enabled === 'boolean' && !data.enabled) && data.details && data.details.uptime) {
            text += ' ' + EW.formatUptimeStock(data.details.uptime);
        }
        return { state: state, text: text };
    }

    /**
     * Render details grid HTML from data.details object.
     * Uses EW.parseDetails() for parsing, wraps entries in grid cells.
     * @param {Object} details - data.details from status API
     * @param {boolean} isRunning - whether the service is running
     * @param {Object} [checks] - checks map from backend (ok/warn/fail per key)
     * @param {Object} [dnsServerChecks] - DNS server check results
     * @param {string} [svcId] - service identifier
     * @returns {string}
     */
    function renderDetailsGrid(details, isRunning, checks, dnsServerChecks, svcId) {
        if (!details) return '';
        var entries = EW.parseDetails(details, { skipKeys: DETAILS_SKIP_KEYS, isRunning: isRunning, showDev: false, checks: checks, serviceId: svcId });
        var html = '';
        for (var i = 0; i < entries.length; i++) {
            var e = entries[i];
            if (e.isSpacer) { html += '<div class="ew-detail-item"></div>'; continue; }
            var valHtml = EW.renderDetailValue(e, { dnsServerChecks: dnsServerChecks });
            var valStyle = EW.detailValueStyle(e);
            var updateBtn = EW.renderUpdateBtn(e);
            var dataAttr = e.freshnessKey ? ' data-freshness-key="' + e.freshnessKey + '"' : '';
            html += '<div class="ew-detail-item">' +
                '<div class="ew-detail-label">' + EW.escapeHtml(e.label) + '</div>' +
                '<div class="ew-detail-value"' + valStyle + dataAttr + '>' + valHtml + updateBtn + '</div></div>';
        }
        return html;
    }

    /**
     * Apply fetched status data to a single service row in the dashboard card.
     * Updates toggle, chip, details grid, uptime/freshness baselines,
     * and geo-split fast polling state.
     * @param {Object} svc - SERVICE_APIS entry
     * @param {Object} data - parsed API response
     */
    function applyServiceData(svc, data) {
        var row = document.getElementById('ew-dash-' + svc.id);
        if (!row) return;
        var toggle = row.querySelector('.ew-toggle input');
        var chip = row.querySelector('.ew-chip');
        var detailsEl = document.getElementById('ew-details-' + svc.id);
        var s = parseServiceStatus(data);
        // Pending: don't update chip (data is not real yet)
        if (s.state === 'pending') return;

        // Update toggle: services with "enabled" field use it; others use "running"
        if (toggle) {
            toggle.checked = (typeof data.enabled === 'boolean') ? data.enabled : data.running;
        }

        // Update chip
        if (chip) {
            chip.className = 'ew-chip ew-chip--' + s.state;
            chip.innerHTML = '<span class="ew-chip__dot"></span> ' + s.text;
        }

        // Update expandable details grid
        if (detailsEl) {
            var detailsHtml = renderDetailsGrid(data.details, data.running, data.checks, data.dns_server_checks, svc.id);
            // Shared: rules_detail and dns_tests rendering
            detailsHtml = EW.renderRulesDetail(data.rules_detail, detailsHtml);
            detailsHtml = EW.renderDnsTests(data.dns_tests, detailsHtml);
            detailsEl.innerHTML = detailsHtml;
        }

        // Update uptime baseline
        if (data.running && data.details && data.details.uptime) {
            _ticker.setUptimeBaseline(svc.id, data.details.uptime);
        } else {
            _ticker.removeUptimeBaseline(svc.id);
        }

        // Update freshness baselines (timer keys)
        if (data.details) {
            for (var tk in EW.TIMER_KEYS) {
                if (data.details[tk]) {
                    _ticker.setFreshnessBaseline(tk, data.details[tk]);
                }
            }
        }

        // Check geo-split background for fast polling
        if (svc.id === 'geo-split' && data.details) {
            if (data.details.background === 'running') {
                _geoPoller.start();
            } else if (_geoPoller.isRunning()) {
                _geoPoller.stop();
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // §5. FETCH & POLLING
    // ═══════════════════════════════════════════════════════════════════

    /**
     * Fetch status for a single service and update its row.
     * Used by fast polling (geo-split background updates, toggle polling).
     * @param {string} serviceId - SERVICE_APIS entry id
     */
    function fetchSingleServiceStatus(serviceId) {
        var svc = EW.getService(serviceId);
        if (!svc) return;
        fetch(svc.api, { cache: 'no-store' })
            .then(function(r) { return r.json(); })
            .then(function(data) { applyServiceData(svc, data); })
            .catch(function() {});
    }

    /**
     * Fetch service statuses in parallel and update dashboard card rows.
     * Each service is fetched independently for maximum parallelism.
     */
    function fetchDashboardStatuses() {
        EW.SERVICE_APIS.forEach(function(svc) {
            fetch(svc.api, { cache: 'no-store' })
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    applyServiceData(svc, data);
                    // Remove skeleton shimmer after first successful fetch
                    var content = document.getElementById('entware-dash-content');
                    if (content && content.classList.contains('ew-loading')) {
                        content.classList.remove('ew-loading');
                    }
                })
                .catch(function() {
                    // Stale-while-revalidate: don't overwrite chip if it already has real data.
                    // Only show "stale" if chip is still in initial LOADING state.
                    var chip = document.querySelector('#ew-dash-' + svc.id + ' .ew-chip');
                    if (chip && chip.textContent.indexOf('LOADING') !== -1) {
                        chip.className = 'ew-chip ew-chip--stale';
                        chip.innerHTML = '<span class="ew-chip__dot"></span> NO DATA';
                    }
                    // Remove shimmer on error (first load failed)
                    var content = document.getElementById('entware-dash-content');
                    if (content && content.classList.contains('ew-loading')) {
                        content.classList.remove('ew-loading');
                    }
                });
        });
    }

    /**
     * Start fast polling for a service after toggle until state settles.
     * @param {string} serviceId - SERVICE_APIS entry id
     * @param {boolean} targetRunning - expected state after toggle
     */
    function startTogglePoller(serviceId, targetRunning) {
        _togglePoller.start(serviceId, function(svc, done) {
            fetch(svc.api, { cache: 'no-store' })
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    applyServiceData(svc, data);
                    if (data.running === targetRunning) done();
                })
                .catch(function() { done(); });
        });
    }

    /**
     * Stop all dashboard polling (status, geo fast-poll, uptime ticker).
     * Called when the card is hidden via Cards Position toggle or on route change.
     * Resets dashboardInjected so polling restarts if card becomes visible again.
     */
    function ewStopDashboardPolling() {
        _dashboardInjected = false;
        if (_dashboardTimer) {
            clearInterval(_dashboardTimer);
            _dashboardTimer = null;
        }
        _geoPoller.stop();
        _togglePoller.stopAll();
        _ticker.stop();
    }

    // ═══════════════════════════════════════════════════════════════════
    // §6. PUBLIC API — EW._dash namespace
    // ═══════════════════════════════════════════════════════════════════

    EW._dash = {
        init: init,
        TOGGLE_FAST_POLL: TOGGLE_FAST_POLL,
        buildServiceRow: buildServiceRow,
        buildEntwareDashboardContent: buildEntwareDashboardContent,
        renderDetailsGrid: renderDetailsGrid,
        parseServiceStatus: parseServiceStatus,
        applyServiceData: applyServiceData,
        fetchSingleServiceStatus: fetchSingleServiceStatus,
        fetchDashboardStatuses: fetchDashboardStatuses,
        startTogglePoller: startTogglePoller,
        stopPolling: ewStopDashboardPolling,
        getDashboardTimer: function() { return _dashboardTimer; },
        setDashboardTimer: function(t) { _dashboardTimer = t; },
        getDashboardInjected: function() { return _dashboardInjected; },
        setDashboardInjected: function(v) { _dashboardInjected = v; }
    };

    } catch (e) {
        // Error boundary: never break stock Keenetic UI
        console.error('[Entware Extras] inject-dashboard.js failed:', e);
    }
})();
