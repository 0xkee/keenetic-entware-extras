

// diag-batch.js — Batch table and sequential runner for Route Check / DNS Check.
// Vanilla JS (ES5), depends on diag-render.js (_renderFullResult, _collectAllDevs)
// and diagnostics.js (_buildRouteCheckUrl, _fetchWithRetry) at runtime.

"use strict";

// ── Batch Table ──────────────────────────────────────────────────────────────

/**
 * Create an empty batch table element with header.
 * @param {string} type - "route" or "dns"
 * @returns {HTMLTableElement}
 */
function _createBatchTableEl(type) {
    var table = document.createElement('table');
    table.className = 'rc-batch-table';
    var thead = '<thead><tr>';
    if (type === 'route') {
        thead += '<th></th><th>Domain</th><th>Route</th><th>Via</th><th>Verdict</th><th></th>';
    } else {
        thead += '<th></th><th>Domain</th><th>Zone</th><th>Upstream</th><th>IP</th><th></th>';
    }
    thead += '</tr></thead>';
    table.innerHTML = thead;
    return table;
}

/**
 * Build a single batch row pair (summary row + expandable detail row).
 * @param {Object} item - {domain: string, data: Object}
 * @param {string} type - "route" or "dns"
 * @returns {{row: HTMLElement, detailRow: HTMLElement}}
 */
function _buildBatchRowPair(item, type) {
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
                if (pfx[1] && pfx[1] !== '32') {
                    routeText += ' /' + pfx[1];
                }
            }
            ifaceText = EW.ifaceLabelShort(rt.dev || '?');
            verdictText = 'geo-split';
        } else if (data.verdict === 'tunnel') {
            icon = '\u2299';
            rowCls = 'rc-batch-row--tunnel';
            var trt = (data.routes && data.routes[0]) ? data.routes[0] : {};
            routeText = trt.table_name || 'tunnel';
            ifaceText = EW.ifaceLabelShort(trt.dev || '?');
            verdictText = 'tunnel';
        } else if (data.verdict === 'mixed') {
            icon = '\u26a0';
            rowCls = 'rc-batch-row--mixed';
            routeText = (data.verdict_details || []).join(', ');
            ifaceText = Object.keys(_collectAllDevs(data)).map(function(d) { return EW.ifaceLabelShort(d); }).join(', ');
            var mixedPctVal = (data.input_type === 'cidr' && data.coverage) ? ((data.coverage.geo_split_pct === 0 && data.coverage.geo_split_ips > 0) ? '<1' : data.coverage.geo_split_pct) : '';
            var mixedPct = mixedPctVal !== '' ? ' ' + mixedPctVal + '%' : '';
            verdictText = 'mixed' + mixedPct;
        } else {
            icon = '\u229E';
            rowCls = 'rc-batch-row--default';
            var def = data.default_route || {};
            routeText = 'default';
            ifaceText = EW.ifaceLabelShort(def.dev || (data.routes && data.routes[0] ? data.routes[0].dev : '?'));
            verdictText = 'policy';
        }

        row.className += ' ' + rowCls;
        row.innerHTML = '<td class="rc-batch-icon">' + icon + '</td>' +
            '<td class="rc-batch-domain">' + EW.escapeHtml(item.domain) + '</td>' +
            '<td>' + EW.escapeHtml(routeText) + '</td>' +
            '<td>' + EW.escapeHtml(ifaceText) + '</td>' +
            '<td>' + EW.escapeHtml(verdictText) + '</td>' +
            '<td><button class="rc-batch-expand" type="button">\u25b8</button></td>';
    } else {
        var dIcon = '\u21c4';
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
            if (zoneText === 'default') {
                dIcon = '\u2192';
                dRowCls = 'rc-batch-row--default';
            }
            var u = data.upstream || {};
            upText = (u.providers && u.providers.length) ? u.providers.join(', ') : '\u2014';
            var res = data.result || {};
            var dIps = res.ips || [];
            if (dIps.length > 1) {
                ipText = dIps[0] + ' (' + dIps.length + ' IPs)';
            } else if (dIps.length === 1) {
                ipText = dIps[0];
            } else {
                ipText = '\u2014';
            }
        }

        row.className += ' ' + dRowCls;
        row.innerHTML = '<td class="rc-batch-icon">' + dIcon + '</td>' +
            '<td class="rc-batch-domain">' + EW.escapeHtml(item.domain) + '</td>' +
            '<td>' + EW.escapeHtml(zoneText) + '</td>' +
            '<td>' + EW.escapeHtml(upText) + '</td>' +
            '<td>' + EW.escapeHtml(ipText) + '</td>' +
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
            var content = detailRow.querySelector('.rc-batch-detail-content');
            if (!content.hasChildNodes()) {
                _renderFullResult(content, data, type);
            }
        }
    });

    return { row: row, detailRow: detailRow };
}

/**
 * Render batch results as compact table with expandable rows.
 * Used for full (re)render: _renderResults auto-switch and non-batch contexts.
 * @param {HTMLElement} container - parent element
 * @param {Array} results - array of {domain: string, data: Object}
 * @param {string} type - "route" or "dns"
 */
function _renderBatchTable(container, results, type) {
    container.innerHTML = '';
    var table = _createBatchTableEl(type);
    var tbody = document.createElement('tbody');

    for (var i = 0; i < results.length; i++) {
        var pair = _buildBatchRowPair(results[i], type);
        tbody.appendChild(pair.row);
        tbody.appendChild(pair.detailRow);
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
    var batchTbody = null;

    /** Create batch table on first result (lazy init). */
    function ensureBatchTable() {
        if (batchTbody) return;
        resultsEl.innerHTML = '';
        var table = _createBatchTableEl(type);
        batchTbody = document.createElement('tbody');
        table.appendChild(batchTbody);
        resultsEl.appendChild(table);
    }

    /** Append a single result row (no full re-render). */
    function appendResult(domain, data) {
        ensureBatchTable();
        var pair = _buildBatchRowPair({ domain: domain, data: data }, type);
        batchTbody.appendChild(pair.row);
        batchTbody.appendChild(pair.detailRow);
    }

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
                appendResult(domain, data);
                next();
            })
            .catch(function(err) {
                var errData = { ok: false, error: err.message };
                results.push({ domain: domain, data: errData });
                idx++;
                appendResult(domain, errData);
                next();
            });
    }

    next();
    return { stop: function() { stopped = true; } };
}
