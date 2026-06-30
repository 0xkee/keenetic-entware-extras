

// route-check.js — Route Check & DNS Check modal UI module.
// Vanilla JS (ES5), no dependencies beyond route-diagram.js (renderRouteDiagram, renderDnsDiagram).
// Public API: openRouteCheckModal(), openDnsCheckModal()

"use strict";

// ── Constants ────────────────────────────────────────────────────────────────

var ROUTE_HISTORY_KEY = 'ew-route-check-history';
var DNS_HISTORY_KEY = 'ew-dns-check-history';
var HISTORY_MAX = 20;
var BATCH_THRESHOLD = 5;
var CHECK_TIMEOUT = 20000;
var RETRY_MAX = 3;
var RETRY_BASE_DELAY = 1000; // ms

/** Cached WAN paths (fetched once per modal open, TTL=60s on server). */
var _cachedWanPaths = null;
/** Promise for WAN paths fetch (awaited before rendering diagram). */
var _wanPathsReady = null;

/**
 * Fetch with retry on 429 (rate limit).
 * Waits with exponential backoff: 1s, 2s, 3s...
 * @param {string} url - URL to fetch
 * @param {number} [retries] - max retries (default RETRY_MAX)
 * @returns {Promise<Response>}
 */
function _fetchWithRetry(url, retries) {
    if (retries === undefined) retries = RETRY_MAX;
    return fetch(url).then(function(resp) {
        if (resp.status === 429 && retries > 0) {
            var delay = RETRY_BASE_DELAY * (RETRY_MAX - retries + 1);
            return new Promise(function(resolve) {
                setTimeout(resolve, delay);
            }).then(function() {
                return _fetchWithRetry(url, retries - 1);
            });
        }
        return resp;
    });
}

var ROUTE_EXAMPLES = ['ozon.ru', 'github.com', 'kaspi.kz', '8.8.8.8'];
var DNS_EXAMPLES = ['ozon.ru', 'github.com', 'kaspi.kz', 'bbc.co.uk'];

// ── localStorage History ─────────────────────────────────────────────────────

/**
 * Normalize a history entry (backward-compat: string → {d, v}).
 * @param {string|Object} item - raw history entry
 * @returns {{d: string, v: string|null}}
 */
function _normalizeHistoryItem(item) {
    if (typeof item === 'string') return { d: item, v: null };
    return { d: item.d || '', v: item.v || null };
}

/**
 * Get history array from localStorage (normalized objects).
 * @param {string} key - localStorage key
 * @returns {Array<{d: string, v: string|null}>}
 */
function getHistory(key) {
    try {
        var raw = JSON.parse(localStorage.getItem(key) || '[]');
        return raw.map(_normalizeHistoryItem);
    } catch (e) { return []; }
}

/**
 * Get flat domain list from history (for batch operations).
 * @param {string} key - localStorage key
 * @returns {Array<string>}
 */
function getHistoryDomains(key) {
    return getHistory(key).map(function(h) { return h.d; });
}

/**
 * Save domain to history with verdict (dedup, newest first, max HISTORY_MAX).
 * @param {string} key - localStorage key
 * @param {string} domain - domain or IP to save
 * @param {string|null} [verdict] - route verdict (geo-split, tunnel, mixed, default)
 */
function saveToHistory(key, domain, verdict) {
    var d = domain.trim().toLowerCase();
    if (!d) return;
    var history = getHistory(key);
    history = history.filter(function(item) { return item.d !== d; });
    history.unshift({ d: d, v: verdict || null });
    if (history.length > HISTORY_MAX) history = history.slice(0, HISTORY_MAX);
    try { localStorage.setItem(key, JSON.stringify(history)); } catch (e) { /* quota */ }
}

/**
 * Remove a single domain from history.
 * @param {string} key - localStorage key
 * @param {string} domain - domain to remove
 */
function removeFromHistory(key, domain) {
    var history = getHistory(key);
    history = history.filter(function(item) { return item.d !== domain; });
    try { localStorage.setItem(key, JSON.stringify(history)); } catch (e) { /* ignore */ }
}

/**
 * Render history pills into a container (colored by verdict).
 * @param {HTMLElement} container - DOM element to render pills into
 * @param {string} key - localStorage key
 * @param {Function} onCheck - callback(domain) when pill is clicked
 */
function renderHistoryPills(container, key, onCheck) {
    var history = getHistory(key);
    container.innerHTML = '';
    if (history.length === 0) {
        container.style.display = 'none';
        return;
    }
    container.style.display = '';

    var label = document.createElement('span');
    label.className = 'rc-history__label';
    label.textContent = 'History:';
    container.appendChild(label);

    for (var i = 0; i < history.length; i++) {
        (function(entry) {
            var pill = document.createElement('span');
            var pillCls = 'rc-pill';
            if (entry.v) pillCls += ' rc-pill--' + entry.v;
            pill.className = pillCls;
            pill.innerHTML = '<span class="rc-pill__text"></span><button class="rc-pill__x" type="button">\u00d7</button>';
            pill.querySelector('.rc-pill__text').textContent = entry.d;
            pill.querySelector('.rc-pill__text').addEventListener('click', function() {
                onCheck(entry.d);
            });
            pill.querySelector('.rc-pill__x').addEventListener('click', function(e) {
                e.stopPropagation();
                removeFromHistory(key, entry.d);
                renderHistoryPills(container, key, onCheck);
            });
            container.appendChild(pill);
        })(history[i]);
    }
}

// ── Lightweight Modal ────────────────────────────────────────────────────────

/**
 * Create and show a diagnostic modal.
 * @param {string} title - modal title
 * @param {Function} buildBody - function(bodyEl) to populate body content
 * @returns {{backdrop: HTMLElement, close: Function}}
 */
function _createDiagModal(title, buildBody) {
    // Remove any existing diagnostic modal
    var existing = document.getElementById('rc-modal');
    if (existing) existing.remove();

    var backdrop = document.createElement('div');
    backdrop.className = 'ew-modal-backdrop';
    backdrop.id = 'rc-modal';

    var modal = document.createElement('div');
    modal.className = 'ew-modal rc-modal';

    var header = document.createElement('div');
    header.className = 'ew-modal__header';
    header.innerHTML = '<h2 class="ew-modal__title"></h2>' +
        '<button class="ew-modal__close" type="button">\u00d7</button>';
    header.querySelector('.ew-modal__title').textContent = title;

    var body = document.createElement('div');
    body.className = 'ew-modal__body rc-modal__body';

    modal.appendChild(header);
    modal.appendChild(body);
    backdrop.appendChild(modal);
    document.body.appendChild(backdrop);

    function close() {
        backdrop.remove();
        document.removeEventListener('keydown', escHandler);
    }

    function escHandler(e) {
        if (e.key === 'Escape') close();
    }

    // Close handlers
    header.querySelector('.ew-modal__close').addEventListener('click', close);
    backdrop.addEventListener('click', function(e) {
        if (e.target === backdrop) close();
    });
    document.addEventListener('keydown', escHandler);

    buildBody(body);

    return { backdrop: backdrop, close: close };
}

// ── Result Rendering ─────────────────────────────────────────────────────────

/**
 * Determine verdict class for color-coded border.
 * @param {Object} data - API response
 * @returns {string} CSS modifier class
 */
function _getVerdictClass(data) {
    if (!data || data.ok === false) return 'rc-result--error';
    if (data.verdict === 'mixed') return 'rc-result--mixed';
    if (data.verdict === 'geo-split') return 'rc-result--geosplit';
    if (data.verdict === 'tunnel') return 'rc-result--tunnel';
    return 'rc-result--default';
}

/**
 * Build one-line text summary for a route check result.
 * @param {Object} data - API response from route-check
 * @returns {string}
 */
function _buildRouteSummary(data) {
    if (!data || data.ok === false) {
        return '\u2717 error \u00b7 ' + (data && data.error ? data.error : 'unknown');
    }
    var parts = [];

    var ipCount = (data.dns && data.dns.ips) ? data.dns.ips.length : 0;
    if (ipCount > 1) {
        parts.push(ipCount + ' IPs');
    }

    if (data.verdict === 'mixed' && data.verdict_devs && data.verdict_devs.length > 0) {
        parts.push(data.verdict_devs.map(function(d) { return _ifaceLabel(d); }).join(', '));
    } else {
        var route = (data.routes && data.routes[0]) ? data.routes[0] : null;
        if (route) {
            var routePrefix = (data.verdict === 'geo-split') ? 'geo ' : ((data.verdict === 'tunnel') ? 'system ' : '');
            var tableInfo = route.match_type ? routePrefix + route.match_type + ' (table ' + (route.table || 'main') + ')' : 'table ' + (route.table || 'main');
            parts.push(tableInfo);
            parts.push(_ifaceLabel(route.dev || '?') + (route.via ? ' via ' + route.via : ''));
        } else {
            var def = data.default_route || {};
            parts.push('main table');
            parts.push(_ifaceLabel(def.dev || '?') + (def.via ? ' via ' + def.via : ''));
        }
    }

    return parts.join(' \u2192 ');
}

/**
 * Build one-line text summary for a DNS check result.
 * @param {Object} data - API response from dns-check
 * @returns {string}
 */
function _buildDnsSummary(data) {
    if (!data || data.ok === false) {
        return '\u2717 error \u00b7 ' + (data && data.error ? data.error : 'unknown');
    }
    var parts = [];
    var zone = data.zone || {};
    parts.push(zone.group ? 'zone: ' + zone.group : 'zone: default');
    if (zone.match_rule) parts.push('rule: ' + zone.match_rule);

    var upstream = data.upstream || {};
    if (upstream.providers && upstream.providers.length) {
        parts.push(upstream.providers.join(', '));
    }

    var result = data.result || {};
    if (result.ips && result.ips[0]) parts.push(result.ips[0]);
    if (result.time_ms) parts.push(result.time_ms + 'ms');

    return parts.join(' \u00b7 ');
}

/**
 * Build technical details HTML (collapsible) for route check.
 * @param {Object} data - API response
 * @returns {string} HTML string
 */
function _buildRouteDetails(data) {
    if (!data || data.ok === false) return '';
    var rows = [];

    // DNS section
    if (data.dns) {
        rows.push('<tr><th colspan="2">DNS</th></tr>');
        if (data.dns.resolver) rows.push('<tr><td>Resolver</td><td>' + _esc(data.dns.resolver) + '</td></tr>');
        if (data.dns.group) rows.push('<tr><td>Group</td><td>' + _esc(data.dns.group) + '</td></tr>');
        if (data.dns.ips) rows.push('<tr><td>IPs</td><td>' + _esc(data.dns.ips.join(', ')) + '</td></tr>');
        if (data.dns.time_ms !== undefined) rows.push('<tr><td>Time</td><td>' + data.dns.time_ms + 'ms</td></tr>');
    }

    // All routes per IP (expanded table)
    if (data.routes && data.routes.length > 0) {
        rows.push('<tr><th colspan="2">Routes per IP (' + data.routes.length + ')</th></tr>');
        for (var i = 0; i < data.routes.length; i++) {
            var r = data.routes[i];
            var verdictBadge = r.verdict ? ' <span class="rc-verdict-badge rc-verdict-badge--' + _esc(r.verdict) + '">' + _esc(r.verdict) + '</span>' : '';
            var devLabel = r.dev ? _ifaceLabel(r.dev) : '?';
            var via = r.via ? ' via ' + r.via : '';
            var prefix = (r.match_prefix && r.match_prefix !== 'default') ? ' [' + r.match_prefix + ']' : '';
            rows.push('<tr class="rc-route-row rc-route-row--' + _esc(r.verdict || 'default') + '"><td>' + _esc(r.ip) + '</td><td>' + _esc(devLabel) + via + prefix + verdictBadge + '</td></tr>');
        }
    }

    // Default route
    if (data.default_route) {
        rows.push('<tr><th colspan="2">Default Route</th></tr>');
        if (data.default_route.dev) rows.push('<tr><td>Device</td><td>' + _esc(_ifaceLabel(data.default_route.dev)) + ' (' + _esc(data.default_route.dev) + ')</td></tr>');
        if (data.default_route.via) rows.push('<tr><td>Gateway</td><td>' + _esc(data.default_route.via) + '</td></tr>');
    }

    if (rows.length === 0) return '';
    return '<table class="rc-details-table">' + rows.join('') + '</table>';
}

/**
 * Build technical details HTML for DNS check.
 * @param {Object} data - API response
 * @returns {string} HTML string
 */
function _buildDnsDetails(data) {
    if (!data || data.ok === false) return '';
    var rows = [];

    if (data.zone) {
        rows.push('<tr><th colspan="2">Zone</th></tr>');
        if (data.zone.group) rows.push('<tr><td>Group</td><td>' + _esc(data.zone.group) + '</td></tr>');
        if (data.zone.match_rule) rows.push('<tr><td>Match rule</td><td>' + _esc(data.zone.match_rule) + '</td></tr>');
        if (data.zone.match_type) rows.push('<tr><td>Match type</td><td>' + _esc(data.zone.match_type) + '</td></tr>');
    }

    if (data.upstream) {
        rows.push('<tr><th colspan="2">Upstream</th></tr>');
        if (data.upstream.providers) rows.push('<tr><td>Providers</td><td>' + _esc(data.upstream.providers.join(', ')) + '</td></tr>');
        if (data.upstream.servers) rows.push('<tr><td>Servers</td><td>' + _esc(data.upstream.servers.join(', ')) + '</td></tr>');
        if (data.upstream.interface) rows.push('<tr><td>Interface</td><td>' + _esc(_ifaceLabel(data.upstream.interface)) + ' (' + _esc(data.upstream.interface) + ')</td></tr>');
    }

    if (data.result) {
        rows.push('<tr><th colspan="2">Result</th></tr>');
        if (data.result.ips) rows.push('<tr><td>IPs</td><td>' + _esc(data.result.ips.join(', ')) + '</td></tr>');
        if (data.result.ttl !== undefined) rows.push('<tr><td>TTL</td><td>' + data.result.ttl + '</td></tr>');
        if (data.result.time_ms !== undefined) rows.push('<tr><td>Time</td><td>' + data.result.time_ms + 'ms</td></tr>');
    }

    if (rows.length === 0) return '';
    return '<table class="rc-details-table">' + rows.join('') + '</table>';
}

/** Escape HTML. */
function _esc(str) {
    return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/**
 * Render a single full result card (SVG + summary + details).
 * @param {HTMLElement} container - parent to append into
 * @param {Object} data - API response
 * @param {string} type - "route" or "dns"
 */
function _renderFullResult(container, data, type) {
    var wrapper = document.createElement('div');
    wrapper.className = 'rc-result ' + _getVerdictClass(data);

    // Legend label on border (query + icon + verdict)
    var query = data && data.query;
    if (query) {
        var legend = document.createElement('span');
        legend.className = 'rc-result__legend';
        var verdict = (data && data.verdict) ? data.verdict : '';
        if (verdict) {
            var lIcon = verdict === 'geo-split' ? '\u21c4' : (verdict === 'tunnel' ? '\u2299' : (verdict === 'mixed' ? '\u26a0' : '\u21d2'));
            legend.textContent = query + ' ' + lIcon + ' ' + verdict;
        } else {
            legend.textContent = query;
        }
        wrapper.appendChild(legend);
    }

    // SVG diagram
    var diagramWrap = document.createElement('div');
    diagramWrap.className = 'rc-result__diagram';
    if (type === 'route') {
        // Inject cached all_paths if backend didn't provide them
        if (!data.all_paths && _cachedWanPaths) {
            data.all_paths = _cachedWanPaths;
        }
        renderRouteDiagram(diagramWrap, data);
    } else {
        renderDnsDiagram(diagramWrap, data);
    }
    wrapper.appendChild(diagramWrap);

    // Summary line (clickable — toggles tech details)
    var summary = document.createElement('div');
    summary.className = 'rc-result__summary';
    summary.textContent = (type === 'route') ? _buildRouteSummary(data) : _buildDnsSummary(data);
    wrapper.appendChild(summary);

    // Technical details (collapsed, toggled by clicking summary)
    var detailsHtml = (type === 'route') ? _buildRouteDetails(data) : _buildDnsDetails(data);
    if (detailsHtml) {
        var detailsDiv = document.createElement('div');
        detailsDiv.className = 'rc-result__details rc-hidden';
        detailsDiv.innerHTML = '<div class="rc-result__details-header">Technical details</div>' +
            '<div class="rc-result__details-body">' + detailsHtml + '</div>';
        wrapper.appendChild(detailsDiv);

        summary.classList.add('rc-result__summary--clickable');
        summary.addEventListener('click', function() {
            var hidden = detailsDiv.classList.contains('rc-hidden');
            if (hidden) {
                detailsDiv.classList.remove('rc-hidden');
                summary.classList.add('rc-result__summary--open');
            } else {
                detailsDiv.classList.add('rc-hidden');
                summary.classList.remove('rc-result__summary--open');
            }
        });
    }

    container.appendChild(wrapper);
}

// ── Batch Table ──────────────────────────────────────────────────────────────

/**
 * Render batch results as compact table with expandable rows.
 * @param {HTMLElement} container - parent element
 * @param {Array} results - array of {domain: string, data: Object}
 * @param {string} type - "route" or "dns"
 */
function _renderBatchTable(container, results, type) {
    container.innerHTML = '';
    var table = document.createElement('table');
    table.className = 'rc-batch-table';

    // Header
    var thead = '<thead><tr>';
    if (type === 'route') {
        thead += '<th></th><th>Domain</th><th>Route</th><th>Via</th><th>Verdict</th><th></th>';
    } else {
        thead += '<th></th><th>Domain</th><th>Zone</th><th>Upstream</th><th>IP</th><th></th>';
    }
    thead += '</tr></thead>';
    table.innerHTML = thead;

    var tbody = document.createElement('tbody');

    for (var i = 0; i < results.length; i++) {
        (function(item) {
            var data = item.data;
            var row = document.createElement('tr');
            row.className = 'rc-batch-row';

            if (type === 'route') {
                var icon = '\u21c4';
                var rowCls = 'rc-batch-row--geosplit';
                var routeText = '';
                var ifaceText = '';
                var verdictText = '';

                if (!data || data.ok === false) {
                    icon = '\u2717';
                    rowCls = 'rc-batch-row--error';
                    routeText = data && data.error ? data.error : 'ERROR';
                    ifaceText = '\u2014';
                    verdictText = 'error';
                } else if (data.verdict === 'geo-split') {
                    var rt = (data.routes && data.routes[0]) ? data.routes[0] : {};
                    routeText = rt.table_name || 'geo';
                    if (rt.match_prefix && rt.match_prefix !== 'default') {
                        var pfx = rt.match_prefix.split('/');
                        routeText += pfx[1] ? ' /' + pfx[1] : ' ' + rt.match_prefix;
                    }
                    ifaceText = _ifaceLabel(rt.dev || '?');
                    verdictText = 'geo-split';
                } else if (data.verdict === 'tunnel') {
                    icon = '\u2299';
                    rowCls = 'rc-batch-row--tunnel';
                    var trt = (data.routes && data.routes[0]) ? data.routes[0] : {};
                    routeText = 'policy';
                    ifaceText = _ifaceLabel(trt.dev || '?');
                    verdictText = 'tunnel';
                } else if (data.verdict === 'mixed') {
                    icon = '\u26a0';
                    rowCls = 'rc-batch-row--mixed';
                    routeText = (data.verdict_details || []).join(', ');
                    ifaceText = (data.verdict_devs || []).map(function(d) { return _ifaceLabel(d); }).join(', ');
                    verdictText = 'mixed';
                } else {
                    icon = '\u21d2';
                    rowCls = 'rc-batch-row--default';
                    var def = data.default_route || {};
                    routeText = 'main';
                    ifaceText = _ifaceLabel(def.dev || (data.routes && data.routes[0] ? data.routes[0].dev : '?'));
                    verdictText = 'default';
                }

                row.className += ' ' + rowCls;
                row.innerHTML = '<td class="rc-batch-icon">' + icon + '</td>' +
                    '<td class="rc-batch-domain">' + _esc(item.domain) + '</td>' +
                    '<td>' + _esc(routeText) + '</td>' +
                    '<td>' + _esc(ifaceText) + '</td>' +
                    '<td>' + _esc(verdictText) + '</td>' +
                    '<td><button class="rc-batch-expand" type="button">\u25b8</button></td>';
            } else {
                var dIcon = '\u2713';
                var dRowCls = 'rc-batch-row--geosplit';
                var zoneText = '';
                var upText = '';
                var ipText = '';

                if (!data || data.ok === false) {
                    dIcon = '\u2717';
                    dRowCls = 'rc-batch-row--error';
                    zoneText = data && data.error ? data.error : 'ERROR';
                    upText = '\u2014';
                    ipText = '\u2014';
                } else {
                    var z = data.zone || {};
                    zoneText = z.group || 'default';
                    var u = data.upstream || {};
                    upText = (u.providers && u.providers.length) ? u.providers.join(', ') : '\u2014';
                    var res = data.result || {};
                    ipText = (res.ips && res.ips[0]) ? res.ips[0] : '\u2014';
                }

                row.className += ' ' + dRowCls;
                row.innerHTML = '<td class="rc-batch-icon">' + dIcon + '</td>' +
                    '<td class="rc-batch-domain">' + _esc(item.domain) + '</td>' +
                    '<td>' + _esc(zoneText) + '</td>' +
                    '<td>' + _esc(upText) + '</td>' +
                    '<td>' + _esc(ipText) + '</td>' +
                    '<td><button class="rc-batch-expand" type="button">\u25b8</button></td>';
            }

            // Expandable detail row
            var detailRow = document.createElement('tr');
            detailRow.className = 'rc-batch-detail-row rc-hidden';
            detailRow.innerHTML = '<td colspan="6"><div class="rc-batch-detail-content"></div></td>';

            // Click on entire row toggles detail (not just the ▸ button)
            var expandBtn = row.querySelector('.rc-batch-expand');
            row.addEventListener('click', function() {
                var isOpen = !detailRow.classList.contains('rc-hidden');
                if (isOpen) {
                    detailRow.classList.add('rc-hidden');
                    expandBtn.textContent = '\u25b8';
                } else {
                    detailRow.classList.remove('rc-hidden');
                    expandBtn.textContent = '\u25be';
                    // Render SVG on first expand
                    var content = detailRow.querySelector('.rc-batch-detail-content');
                    if (!content.hasChildNodes()) {
                        _renderFullResult(content, data, type);
                    }
                }
            });

            tbody.appendChild(row);
            tbody.appendChild(detailRow);
        })(results[i]);
    }

    table.appendChild(tbody);
    container.appendChild(table);
}

// ── Batch Runner (sequential) ────────────────────────────────────────────────

/**
 * Run checks sequentially on a list of domains.
 * @param {Object} opts
 * @param {Array<string>} opts.domains - domains to check
 * @param {string} opts.type - "route" or "dns"
 * @param {string} opts.iface - source interface (route only)
 * @param {HTMLElement} opts.progressEl - progress display element
 * @param {HTMLElement} opts.resultsEl - results container
 * @param {Function} opts.onDone - callback when finished
 * @returns {{stop: Function}} - control handle
 */
function _runBatch(opts) {
    var domains = opts.domains;
    var type = opts.type;
    var iface = opts.iface || '';
    var progressEl = opts.progressEl;
    var resultsEl = opts.resultsEl;
    var onDone = opts.onDone;
    var stopped = false;
    var results = [];
    var idx = 0;

    function updateProgress() {
        if (progressEl) {
            progressEl.innerHTML = '<span class="rc-progress__text">Checking ' + idx + '/' + domains.length + '...</span>' +
                '<span class="rc-progress__bar"><span class="rc-progress__fill" style="width:' + Math.round((idx / domains.length) * 100) + '%"></span></span>' +
                '<button class="rc-progress__stop ndw-button ndw-button--toggle ndw-button--small" type="button">Stop</button>';
            var stopBtn = progressEl.querySelector('.rc-progress__stop');
            if (stopBtn) {
                stopBtn.addEventListener('click', function() { stopped = true; });
            }
        }
    }

    function next() {
        if (stopped || idx >= domains.length) {
            if (progressEl) {
                progressEl.innerHTML = stopped
                    ? '<span class="rc-progress__text">Stopped at ' + idx + '/' + domains.length + '</span>'
                    : '<span class="rc-progress__text">Done \u2014 ' + domains.length + ' checked</span>';
            }
            _renderBatchTable(resultsEl, results, type);
            if (onDone) onDone(results);
            return;
        }

        var domain = domains[idx];
        updateProgress();

        var url;
        if (type === 'route') {
            url = _buildRouteCheckUrl(domain, iface);
        } else {
            url = '/api/smartdns/dns-check?host=' + encodeURIComponent(domain);
        }

        _fetchWithRetry(url)
            .then(function(resp) {
                if (!resp.ok) throw new Error('HTTP ' + resp.status);
                return resp.json();
            })
            .then(function(data) {
                results.push({ domain: domain, data: data });
                idx++;
                // Render incrementally in table mode
                _renderBatchTable(resultsEl, results, type);
                next();
            })
            .catch(function(err) {
                results.push({ domain: domain, data: { ok: false, error: err.message } });
                idx++;
                _renderBatchTable(resultsEl, results, type);
                next();
            });
    }

    next();
    return { stop: function() { stopped = true; } };
}

// ── Interface Loader ─────────────────────────────────────────────────────────

/**
 * Build a custom radio dropdown for interface + client selection inside wrapEl.
 * Fetches interfaces and clients (with their policies) from API.
 * Also populates window._ewIfaceMap (id → label) for diagram renderer.
 * @param {HTMLElement} wrapEl - container div to build dropdown in
 */
function _loadInterfaces(wrapEl) {
    // Build default dropdown immediately (Router + br0)
    _buildIfaceDropdown(wrapEl, [
        { value: 'local', label: 'Router' },
        { value: 'br0', label: 'Home network (br0)' }
    ], 'br0');

    var ifacesP = fetch('/api/system/interfaces').then(function(r) { return r.ok ? r.json() : null; }).catch(function() { return null; });
    var clientsP = fetch('/api/system/clients').then(function(r) { return r.ok ? r.json() : null; }).catch(function() { return null; });

    Promise.all([ifacesP, clientsP]).then(function(results) {
        var ifData = results[0];
        var clData = results[1];

        // Build global id→label map for diagram/details use
        if (ifData && ifData.interfaces) {
            var map = {};
            for (var i = 0; i < ifData.interfaces.length; i++) {
                var iface = ifData.interfaces[i];
                var id = iface.id || iface.name || iface;
                var label = iface.label || iface.description || id;
                map[id] = label;
            }
            window._ewIfaceMap = map;
        }

        // Build options: Nets (Router + LAN bridges), sorted alphabetically
        var netOptions = [{ value: 'local', label: 'Router' }];
        if (ifData && ifData.interfaces) {
            for (var j = 0; j < ifData.interfaces.length; j++) {
                var ifc = ifData.interfaces[j];
                var ifcId = ifc.id || ifc.name || ifc;
                if (!/^br\d/.test(ifcId)) continue;
                var ifcLabel = ifc.label || ifc.description || ifcId;
                netOptions.push({ value: ifcId, label: ifcLabel + ' (' + ifcId + ')' });
            }
        }
        netOptions.sort(function(a, b) { return a.label.localeCompare(b.label); });
        var options = [{ value: '', label: 'Nets', disabled: true, group: true }];
        for (var n = 0; n < netOptions.length; n++) options.push(netOptions[n]);

        // Add all clients split into online/offline, sorted alphabetically
        if (clData && clData.clients && clData.clients.length) {
            var activeClients = [];
            var inactiveClients = [];
            for (var k = 0; k < clData.clients.length; k++) {
                var cl = clData.clients[k];
                var clLabel;
                if (cl.mark) {
                    // Client has VPN policy — show tunnel interface or "policy" when down
                    var devLabel = cl.dev_label || (window._ewIfaceMap && window._ewIfaceMap[cl.dev]) || cl.dev || '';
                    if (devLabel) {
                        clLabel = cl.name + ' \u2192 ' + devLabel;
                    } else {
                        // Tunnel unavailable (no route in policy table)
                        clLabel = cl.name + ' \u2192 policy \u2b07';
                    }
                } else {
                    // Client without VPN tunnel — uses connection policy
                    clLabel = cl.name + ' \u2192 Policy';
                }
                var item = { value: cl.mac, label: clLabel };
                if (cl.active) {
                    activeClients.push(item);
                } else {
                    inactiveClients.push(item);
                }
            }
            activeClients.sort(function(a, b) { return a.label.localeCompare(b.label); });
            inactiveClients.sort(function(a, b) { return a.label.localeCompare(b.label); });
            if (activeClients.length) {
                options.push({ value: '', label: 'Clients (online)', disabled: true, group: true });
                for (var m = 0; m < activeClients.length; m++) {
                    options.push(activeClients[m]);
                }
            }
            if (inactiveClients.length) {
                options.push({ value: '', label: 'Clients (offline)', disabled: true, group: true });
                for (var p = 0; p < inactiveClients.length; p++) {
                    options.push(inactiveClients[p]);
                }
            }
        }

        _buildIfaceDropdown(wrapEl, options, 'br0');
    });
}

/**
 * Build the custom radio dropdown HTML inside a wrapper element.
 * Uses ew-modal__iface-select classes for consistent look with settings modal.
 * @param {HTMLElement} wrapEl - container
 * @param {Array} options - [{value, label, disabled?}]
 * @param {string} selected - currently selected value
 */
function _buildIfaceDropdown(wrapEl, options, selected) {
    var selLabel = '';
    var html = '<div class="ew-modal__iface-select rc-iface-dropdown">' +
        '<button type="button" class="ew-modal__iface-select-trigger">' +
            '<span class="ew-modal__iface-select-text"></span>' +
            '<svg class="ew-modal__select-arrow" width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M7 10l5 5 5-5z"/></svg>' +
        '</button>' +
        '<div class="ew-modal__iface-select-panel ew-hidden">';
    for (var i = 0; i < options.length; i++) {
        var opt = options[i];
        if (opt.disabled) {
            html += '<div class="ew-modal__iface-select-group">' + opt.label + '</div>';
            continue;
        }
        var chk = (opt.value === selected) ? ' checked' : '';
        if (opt.value === selected) selLabel = opt.label;
        html += '<label class="ew-modal__iface-select-option">' +
            '<input type="radio" name="rc-iface" value="' + opt.value + '"' + chk + '>' +
            '<span>' + opt.label + '</span></label>';
    }
    html += '</div></div>';
    wrapEl.innerHTML = html;
    wrapEl.querySelector('.ew-modal__iface-select-text').textContent = selLabel || (options[0] ? options[0].label : '');
}

/**
 * Get the currently selected value from the custom dropdown.
 * @param {HTMLElement} wrapEl - the rc-iface-wrap container
 * @returns {string} selected value (e.g. "br0", "local", "80:A5:89:45:3C:4C")
 */
function _getSelectedIface(wrapEl) {
    var checked = wrapEl.querySelector('input[name="rc-iface"]:checked');
    return checked ? checked.value : 'br0';
}

/**
 * Build a route-check API URL with "from" param based on dropdown selection.
 * "from" can be an interface (br0, local) or a client MAC (XX:XX:XX:XX:XX:XX).
 * Backend resolves MAC to fwmark automatically.
 * @param {string} domain - domain or IP to check
 * @param {string} selected - dropdown value ("br0", "local", "XX:XX:XX:XX:XX:XX")
 * @returns {string} full API URL
 */
function _buildRouteCheckUrl(domain, selected) {
    var url = '/api/geo-split/route-check?host=' + encodeURIComponent(domain);
    if (selected) {
        url += '&from=' + encodeURIComponent(selected);
    }
    return url;
}

// ── Quick Examples ───────────────────────────────────────────────────────────

/**
 * Render quick example links.
 * @param {HTMLElement} container - element to render into
 * @param {Array<string>} examples - example domains
 * @param {Function} onCheck - callback(domain)
 */
function _renderExamples(container, examples, onCheck) {
    container.innerHTML = '';
    var label = document.createElement('span');
    label.className = 'rc-examples__label';
    label.textContent = 'Try:';
    container.appendChild(label);

    for (var i = 0; i < examples.length; i++) {
        (function(domain) {
            var link = document.createElement('a');
            link.className = 'rc-examples__link';
            link.href = '#';
            link.textContent = domain;
            link.addEventListener('click', function(e) {
                e.preventDefault();
                onCheck(domain);
            });
            container.appendChild(link);
            if (i < examples.length - 1) {
                var sep = document.createElement('span');
                sep.className = 'rc-examples__sep';
                sep.textContent = ' \u2022 ';
                container.appendChild(sep);
            }
        })(examples[i]);
    }
}

// ── Route Check Modal (Tool 1) ──────────────────────────────────────────────

/**
 * Open the Route Check diagnostic modal.
 * Called from app.js button in geo-split card header.
 */
function openRouteCheckModal() {
    var batchHandle = null;
    var allResults = [];

    // Fetch WAN paths (cached on server 60s, fetched once per modal open)
    _wanPathsReady = fetch('/api/geo-split/wan-paths').then(function(r) {
        return r.ok ? r.json() : null;
    }).then(function(paths) {
        if (Array.isArray(paths)) _cachedWanPaths = paths;
    }).catch(function() { /* non-critical */ });

    _createDiagModal('\ud83d\udd0d Route Check', function(body) {
        // Input row
        var inputRow = document.createElement('div');
        inputRow.className = 'rc-input-row';
        inputRow.innerHTML =
            '<input type="text" class="rc-input" placeholder="Enter domain or IP (e.g. github.com, 8.8.8.8)" autocomplete="off">' +
            '<span class="rc-iface-label">from</span>' +
            '<div class="rc-iface-wrap"></div>' +
            '<button class="ndw-button ndw-button--toggle ndw-button--toggle-enabled ndw-button--small rc-check-btn" type="button">Check</button>';
        body.appendChild(inputRow);

        var input = inputRow.querySelector('.rc-input');
        var ifaceWrap = inputRow.querySelector('.rc-iface-wrap');
        var checkBtn = inputRow.querySelector('.rc-check-btn');

        // Load interfaces (builds custom radio dropdown)
        _loadInterfaces(ifaceWrap);

        // Quick examples
        var examplesRow = document.createElement('div');
        examplesRow.className = 'rc-examples';
        body.appendChild(examplesRow);
        _renderExamples(examplesRow, ROUTE_EXAMPLES, function(domain) {
            input.value = domain;
            doCheck(domain);
        });

        // History row
        var historyRow = document.createElement('div');
        historyRow.className = 'rc-history';
        body.appendChild(historyRow);

        // Check All button (appended to history row)
        var checkAllBtn = document.createElement('button');
        checkAllBtn.className = 'ndw-button ndw-button--toggle ndw-button--small rc-check-all-btn';
        checkAllBtn.type = 'button';
        checkAllBtn.textContent = '\u25b6\u00a0 Check All';

        function refreshHistory() {
            renderHistoryPills(historyRow, ROUTE_HISTORY_KEY, function(domain) {
                input.value = domain;
                doCheck(domain);
            });
            // Re-append Check All btn after history
            var history = getHistory(ROUTE_HISTORY_KEY);
            if (history.length > 0) {
                historyRow.appendChild(checkAllBtn);
            }
        }
        refreshHistory();

        // Progress area
        var progressEl = document.createElement('div');
        progressEl.className = 'rc-progress';
        body.appendChild(progressEl);

        // Results area
        var resultsEl = document.createElement('div');
        resultsEl.className = 'rc-results';
        body.appendChild(resultsEl);

        // ── Check single domain ──
        function doCheck(domain) {
            var d = domain.trim().toLowerCase();
            if (!d) return;
            saveToHistory(ROUTE_HISTORY_KEY, d, null);
            refreshHistory();
            input.value = '';
            progressEl.innerHTML = '';

            var iface = _getSelectedIface(ifaceWrap);
            var url = _buildRouteCheckUrl(d, iface);

            // Show spinner
            var loadingDiv = document.createElement('div');
            loadingDiv.className = 'rc-loading';
            loadingDiv.innerHTML = '<div class="ew-spinner"></div>';
            resultsEl.innerHTML = '';
            resultsEl.appendChild(loadingDiv);

            _fetchWithRetry(url)
                .then(function(resp) {
                    if (!resp.ok) throw new Error('HTTP ' + resp.status);
                    return resp.json();
                })
                .then(function(data) {
                    // Ensure WAN paths are loaded before rendering diagram
                    return (_wanPathsReady || Promise.resolve()).then(function() {
                        allResults.unshift({ domain: d, data: data });
                        // Update history verdict after result
                        if (data && data.verdict) {
                            saveToHistory(ROUTE_HISTORY_KEY, d, data.verdict);
                            refreshHistory();
                        }
                        _renderResults(resultsEl, allResults, 'route');
                    });
                })
                .catch(function(err) {
                    allResults.unshift({ domain: d, data: { ok: false, error: err.message } });
                    _renderResults(resultsEl, allResults, 'route');
                });
        }

        // ── Check All ──
        checkAllBtn.addEventListener('click', function() {
            var history = getHistoryDomains(ROUTE_HISTORY_KEY);
            if (history.length === 0) return;
            allResults = [];
            resultsEl.innerHTML = '';
            var iface = _getSelectedIface(ifaceWrap);
            batchHandle = _runBatch({
                domains: history,
                type: 'route',
                iface: iface,
                progressEl: progressEl,
                resultsEl: resultsEl,
                onDone: function(results) {
                    allResults = results;
                    batchHandle = null;
                    // Update verdicts in history from batch results
                    for (var r = 0; r < results.length; r++) {
                        if (results[r].data && results[r].data.verdict) {
                            saveToHistory(ROUTE_HISTORY_KEY, results[r].domain, results[r].data.verdict);
                        }
                    }
                    refreshHistory();
                }
            });
        });

        // ── Event handlers ──
        checkBtn.addEventListener('click', function() {
            doCheck(input.value);
        });
        input.addEventListener('keydown', function(e) {
            if (e.key === 'Enter') {
                e.preventDefault();
                doCheck(input.value);
            }
        });

        // Focus input
        setTimeout(function() { input.focus(); }, 50);
    });
}

// ── DNS Check Modal (Tool 2) ─────────────────────────────────────────────────

/**
 * Open the DNS Check diagnostic modal.
 * Called from app.js button in smartdns card header.
 */
function openDnsCheckModal() {
    var batchHandle = null;
    var allResults = [];

    _createDiagModal('\ud83d\udd0d DNS Check', function(body) {
        // Input row
        var inputRow = document.createElement('div');
        inputRow.className = 'rc-input-row';
        inputRow.innerHTML =
            '<input type="text" class="rc-input rc-input--wide" placeholder="Enter domain (e.g. github.com)" autocomplete="off">' +
            '<button class="ndw-button ndw-button--toggle ndw-button--toggle-enabled ndw-button--small rc-check-btn" type="button">Check</button>';
        body.appendChild(inputRow);

        var input = inputRow.querySelector('.rc-input');
        var checkBtn = inputRow.querySelector('.rc-check-btn');

        // Quick examples
        var examplesRow = document.createElement('div');
        examplesRow.className = 'rc-examples';
        body.appendChild(examplesRow);
        _renderExamples(examplesRow, DNS_EXAMPLES, function(domain) {
            input.value = domain;
            doCheck(domain);
        });

        // History row
        var historyRow = document.createElement('div');
        historyRow.className = 'rc-history';
        body.appendChild(historyRow);

        var checkAllBtn = document.createElement('button');
        checkAllBtn.className = 'ndw-button ndw-button--toggle ndw-button--small rc-check-all-btn';
        checkAllBtn.type = 'button';
        checkAllBtn.textContent = '\u25b6\u00a0 Check All';

        function refreshHistory() {
            renderHistoryPills(historyRow, DNS_HISTORY_KEY, function(domain) {
                input.value = domain;
                doCheck(domain);
            });
            var history = getHistory(DNS_HISTORY_KEY);
            if (history.length > 0) {
                historyRow.appendChild(checkAllBtn);
            }
        }
        refreshHistory();

        // Progress area
        var progressEl = document.createElement('div');
        progressEl.className = 'rc-progress';
        body.appendChild(progressEl);

        // Results area
        var resultsEl = document.createElement('div');
        resultsEl.className = 'rc-results';
        body.appendChild(resultsEl);

        // ── Check single domain ──
        function doCheck(domain) {
            var d = domain.trim().toLowerCase();
            if (!d) return;
            saveToHistory(DNS_HISTORY_KEY, d);
            refreshHistory();
            input.value = '';
            progressEl.innerHTML = '';

            var url = '/api/smartdns/dns-check?host=' + encodeURIComponent(d);

            var loadingDiv = document.createElement('div');
            loadingDiv.className = 'rc-loading';
            loadingDiv.innerHTML = '<div class="ew-spinner"></div>';
            resultsEl.innerHTML = '';
            resultsEl.appendChild(loadingDiv);

            _fetchWithRetry(url)
                .then(function(resp) {
                    if (!resp.ok) throw new Error('HTTP ' + resp.status);
                    return resp.json();
                })
                .then(function(data) {
                    allResults.unshift({ domain: d, data: data });
                    _renderResults(resultsEl, allResults, 'dns');
                })
                .catch(function(err) {
                    allResults.unshift({ domain: d, data: { ok: false, error: err.message } });
                    _renderResults(resultsEl, allResults, 'dns');
                });
        }

        // ── Check All ──
        checkAllBtn.addEventListener('click', function() {
            var history = getHistoryDomains(DNS_HISTORY_KEY);
            if (history.length === 0) return;
            allResults = [];
            resultsEl.innerHTML = '';
            batchHandle = _runBatch({
                domains: history,
                type: 'dns',
                iface: '',
                progressEl: progressEl,
                resultsEl: resultsEl,
                onDone: function(results) {
                    allResults = results;
                    batchHandle = null;
                }
            });
        });

        // ── Event handlers ──
        checkBtn.addEventListener('click', function() {
            doCheck(input.value);
        });
        input.addEventListener('keydown', function(e) {
            if (e.key === 'Enter') {
                e.preventDefault();
                doCheck(input.value);
            }
        });

        // Focus input
        setTimeout(function() { input.focus(); }, 50);
    });
}

// ── Results Renderer (auto-switch between full and batch) ────────────────────

/**
 * Render results list — full diagrams if <= BATCH_THRESHOLD, else batch table.
 * @param {HTMLElement} container - results container
 * @param {Array} results - array of {domain, data}
 * @param {string} type - "route" or "dns"
 */
function _renderResults(container, results, type) {
    container.innerHTML = '';

    if (results.length === 0) return;

    if (results.length >= BATCH_THRESHOLD) {
        _renderBatchTable(container, results, type);
        return;
    }

    // Full diagram mode (1-4 results)
    for (var i = 0; i < results.length; i++) {
        var item = results[i];
        var section = document.createElement('div');
        section.className = 'rc-result-section';

        _renderFullResult(section, item.data, type);
        container.appendChild(section);
    }
}
