

// diagnostics.js — Route Check & DNS Check modal UI module.
// Vanilla JS (ES5), depends on route-diagram.js (renderRouteDiagram, renderDnsDiagram).
// Rendering: diag-render.js; Batch table/runner: diag-batch.js (loaded before this file).
// Public API: openRouteCheckModal(), openDnsCheckModal()

"use strict";

// ── Constants ────────────────────────────────────────────────────────────────

var ROUTE_HISTORY_KEY = 'ew-route-check-history';
var DNS_HISTORY_KEY = 'ew-dns-check-history';
var HISTORY_MAX = 20;
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

var ROUTE_EXAMPLES = [ 'github.com', 'kaspi.kz', 'ozon.ru', '8.8.8.8', '5.0.0.0/8'];
var DNS_EXAMPLES = ['github.com', 'kaspi.kz', 'bbc.co.uk', 'ozon.ru' ];

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

    // Re-attach Check All button if stored on container (survives innerHTML clear)
    if (container._checkAllBtn && history.length > 0) {
        container.appendChild(container._checkAllBtn);
    }

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

    var ifacesP = EW.loadIfaceMap();
    var clientsP = fetch('/api/system/clients').then(function(r) { return r.ok ? r.json() : null; }).catch(function() { return null; });

    Promise.all([ifacesP, clientsP]).then(function(results) {
        var ifData = results[0];
        var clData = results[1];

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
                    // Client has tunnel policy — show tunnel interface or "policy" when down
                    var devLabel = cl.dev_label || (window._ewIfaceMap && window._ewIfaceMap[cl.dev]) || cl.dev || '';
                    if (devLabel) {
                        clLabel = cl.name + ' \u2192 ' + devLabel;
                    } else {
                        // Tunnel unavailable (no route in policy table)
                        clLabel = cl.name + ' \u2192 policy \u2b07';
                    }
                } else {
                    // Client without tunnel — uses connection policy
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

// ── Results Renderer (auto-switch between full and batch) ────────────────────

/**
 * Render results list — full diagrams if <= BATCH_THRESHOLD, else batch table.
 * Coordination point: calls _renderFullResult (diag-render.js) and
 * _renderBatchTable (diag-batch.js).
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

// ── Check Modal Factory ──────────────────────────────────────────────────────

/**
 * Common factory for Route Check / DNS Check modal.
 * Extracts the shared DOM-creation, event-wiring, history and batch logic
 * so that each public opener is a thin configuration wrapper.
 *
 * @param {Object} opts
 * @param {string}   opts.title          - modal title
 * @param {string}   opts.type           - 'route' or 'dns'
 * @param {string}   opts.placeholder    - input placeholder text
 * @param {Array}    opts.examples       - example domains array
 * @param {string}   opts.historyKey     - localStorage history key
 * @param {Function} [opts.preOpen]      - called before modal opens (e.g. fetch WAN paths)
 * @param {boolean}  opts.hasIface       - whether to show interface dropdown
 * @param {Function} opts.buildUrl       - function(domain, iface) → URL string
 * @param {Function} opts.extractVerdict - function(data) → verdict string|null for history pill
 * @param {Function} [opts.beforeRender] - optional function() → Promise to wait before rendering
 */
function _openCheckModal(opts) {
    var batchHandle = null;
    var allResults = [];

    if (opts.preOpen) opts.preOpen();

    _createDiagModal(opts.title, function(body) {
        // Input row
        var inputRow = document.createElement('div');
        inputRow.className = 'rc-input-row';
        if (opts.hasIface) {
            inputRow.innerHTML =
                '<input type="text" class="rc-input" placeholder="' + opts.placeholder + '" autocomplete="off">' +
                '<span class="rc-iface-label">from</span>' +
                '<div class="rc-iface-wrap"></div>' +
                '<button class="ndw-button ndw-button--toggle ndw-button--toggle-enabled ndw-button--small rc-check-btn" type="button">Check</button>';
        } else {
            inputRow.innerHTML =
                '<input type="text" class="rc-input rc-input--wide" placeholder="' + opts.placeholder + '" autocomplete="off">' +
                '<button class="ndw-button ndw-button--toggle ndw-button--toggle-enabled ndw-button--small rc-check-btn" type="button">Check</button>';
        }
        body.appendChild(inputRow);

        var input = inputRow.querySelector('.rc-input');
        var checkBtn = inputRow.querySelector('.rc-check-btn');
        var ifaceWrap = opts.hasIface ? inputRow.querySelector('.rc-iface-wrap') : null;

        if (opts.hasIface && ifaceWrap) _loadInterfaces(ifaceWrap);

        // Quick examples
        var examplesRow = document.createElement('div');
        examplesRow.className = 'rc-examples';
        body.appendChild(examplesRow);
        _renderExamples(examplesRow, opts.examples, function(domain) {
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

        historyRow._checkAllBtn = checkAllBtn;

        function refreshHistory() {
            renderHistoryPills(historyRow, opts.historyKey, function(domain) {
                input.value = domain;
                doCheck(domain);
            });
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
            saveToHistory(opts.historyKey, d, null);
            refreshHistory();
            input.value = '';
            progressEl.innerHTML = '';

            var iface = (opts.hasIface && ifaceWrap) ? _getSelectedIface(ifaceWrap) : '';
            var url = opts.buildUrl(d, iface);

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
                    var render = function() {
                        allResults.unshift({ domain: d, data: data });
                        var verdict = opts.extractVerdict(data);
                        if (verdict) {
                            saveToHistory(opts.historyKey, d, verdict);
                            refreshHistory();
                        }
                        _renderResults(resultsEl, allResults, opts.type);
                    };
                    if (opts.beforeRender) {
                        return (opts.beforeRender() || Promise.resolve()).then(render);
                    }
                    render();
                })
                .catch(function(err) {
                    allResults.unshift({ domain: d, data: { ok: false, error: err.message } });
                    _renderResults(resultsEl, allResults, opts.type);
                });
        }

        // ── Check All ──
        checkAllBtn.addEventListener('click', function() {
            var history = getHistoryDomains(opts.historyKey);
            if (history.length === 0) return;
            allResults = [];
            resultsEl.innerHTML = '';
            var iface = (opts.hasIface && ifaceWrap) ? _getSelectedIface(ifaceWrap) : '';
            batchHandle = _runBatch({
                domains: history,
                type: opts.type,
                iface: iface,
                progressEl: progressEl,
                resultsEl: resultsEl,
                onDone: function(results) {
                    allResults = results;
                    batchHandle = null;
                    for (var r = 0; r < results.length; r++) {
                        var v = opts.extractVerdict(results[r].data);
                        if (v) saveToHistory(opts.historyKey, results[r].domain, v);
                    }
                    refreshHistory();
                }
            });
        });

        // ── Event handlers ──
        checkBtn.addEventListener('click', function() { doCheck(input.value); });
        input.addEventListener('keydown', function(e) {
            if (e.key === 'Enter') { e.preventDefault(); doCheck(input.value); }
        });

        // Focus input
        setTimeout(function() { input.focus(); }, 50);
    });
}

// ── Route Check Modal (Tool 1) ──────────────────────────────────────────────

/**
 * Open the Route Check diagnostic modal.
 * Called from app.js button in geo-split card header.
 */
function openRouteCheckModal() {
    _openCheckModal({
        title: '\ud83d\udd0d Route Check',
        type: 'route',
        placeholder: 'Enter domain, IP or CIDR (e.g. github.com, 8.8.8.8, 5.0.0.0/8)',
        examples: ROUTE_EXAMPLES,
        historyKey: ROUTE_HISTORY_KEY,
        hasIface: true,
        preOpen: function() {
            _wanPathsReady = fetch('/api/geo-split/wan-paths').then(function(r) {
                return r.ok ? r.json() : null;
            }).then(function(paths) {
                if (Array.isArray(paths)) _cachedWanPaths = paths;
            }).catch(function() {});
        },
        buildUrl: function(domain, iface) { return _buildRouteCheckUrl(domain, iface); },
        extractVerdict: function(data) { return (data && data.verdict) ? data.verdict : null; },
        beforeRender: function() { return _wanPathsReady || Promise.resolve(); }
    });
}

// ── DNS Check Modal (Tool 2) ─────────────────────────────────────────────────

/**
 * Open the DNS Check diagnostic modal.
 * Called from app.js button in smartdns card header.
 */
function openDnsCheckModal() {
    _openCheckModal({
        title: '\ud83d\udd0d DNS Check',
        type: 'dns',
        placeholder: 'Enter domain (e.g. github.com)',
        examples: DNS_EXAMPLES,
        historyKey: DNS_HISTORY_KEY,
        hasIface: false,
        preOpen: function() { EW.loadIfaceMap(); },
        buildUrl: function(domain) {
            return '/api/smartdns/dns-check?host=' + encodeURIComponent(domain);
        },
        extractVerdict: function(data) {
            if (!data || !data.zone || !data.zone.group) return null;
            return (data.zone.group !== 'default') ? 'geo-split' : 'default';
        }
    });
}
