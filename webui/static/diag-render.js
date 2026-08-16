

// diag-render.js — Result rendering functions for Route Check / DNS Check.
// Vanilla JS (ES5), no dependencies beyond route-diagram.js and shared.js (EW).

"use strict";

// ── Constants ────────────────────────────────────────────────────────────────

/** Threshold for switching from full diagram to batch table view. */
var BATCH_THRESHOLD = 5;

// ── Result Rendering ─────────────────────────────────────────────────────────

/**
 * Determine verdict class for color-coded border.
 * @param {Object} data - API response
 * @param {string} [type] - "route" (default) or "dns"
 * @returns {string} CSS modifier class
 */
function _getVerdictClass(data, type) {
    if (!data || data.ok === false) return 'rc-result--error';
    if (type === 'dns') {
        // System DNS fallback — always "default" style (blue)
        if (data.dns_source === 'system') return 'rc-result--default';
        // DNS has no top-level verdict — color by matched zone group:
        // a zone-specific override group is treated like a "matched rule"
        // (green, same as route geo-split); plain "default" stays blue.
        var zone = data.zone || {};
        var groupLabel = zone.group || 'default';
        return (groupLabel === 'default') ? 'rc-result--default' : 'rc-result--geosplit';
    }
    if (data.verdict === 'mixed') return 'rc-result--mixed';
    if (data.verdict === 'geo-split') return 'rc-result--geosplit';
    if (data.verdict === 'tunnel') return 'rc-result--tunnel';
    return 'rc-result--default';
}

/**
 * Collect all unique non-lo device names from verdict_devs + CIDR coverage overlaps.
 * Used by summary line, batch table, and route devices section.
 * @param {Object} data - route-check API response
 * @returns {Object} map {dev_name: true}
 */
function _collectAllDevs(data) {
    var devs = {};
    if (data.verdict_devs) {
        for (var i = 0; i < data.verdict_devs.length; i++) {
            devs[data.verdict_devs[i]] = true;
        }
    }
    if (data.input_type === 'cidr' && data.coverage && data.coverage.overlaps) {
        for (var j = 0; j < data.coverage.overlaps.length; j++) {
            var d = data.coverage.overlaps[j].dev;
            if (d) devs[d] = true;
        }
    }
    return devs;
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

    // CIDR: show coverage instead of IP count
    if (data.input_type === 'cidr' && data.coverage) {
        parts.push(data.coverage.geo_split_pct + '% geo-split');
    } else {
        var ipCount = (data.dns && data.dns.ips) ? data.dns.ips.length : 0;
        if (ipCount > 1) {
            parts.push(ipCount + ' IPs');
        }
    }

    if (data.verdict === 'mixed' && data.verdict_devs && data.verdict_devs.length > 0) {
        parts.push(Object.keys(_collectAllDevs(data)).map(function(d) { return EW.ifaceLabelShort(d); }).join(', '));
    } else {
        var route = (data.routes && data.routes[0]) ? data.routes[0] : null;
        if (route) {
            var routePrefix = (data.verdict === 'geo-split') ? 'geo ' : ((data.verdict === 'tunnel') ? 'tunnel ' : '');
            var tableInfo = route.match_type ? routePrefix + route.match_type + ' (table ' + (route.table || 'main') + ')' : 'table ' + (route.table || 'main');
            parts.push(tableInfo);
            parts.push(EW.ifaceLabelShort(route.dev || '?'));
        } else {
            var def = data.default_route || {};
            parts.push('main table');
            parts.push(EW.ifaceLabelShort(def.dev || '?'));
        }
    }

    return parts.join(' \u2192 ');
}

/**
 * Build one-line text summary for a DNS check result.
 * Mirrors _buildRouteSummary style: arrow-joined stages instead of
 * middot-separated key:value pairs.
 * @param {Object} data - API response from dns-check
 * @returns {string}
 */
function _buildDnsSummary(data) {
    if (!data || data.ok === false) {
        return '\u2717 error \u00b7 ' + (data && data.error ? data.error : 'unknown');
    }
    var parts = [];

    // System DNS warning prefix
    if (data.dns_source === 'system') {
        parts.push('\u26a0 system DNS :' + (data.dns_port || 53));
    }

    var result = data.result || {};
    var sIps = result.ips || [];

    var zone = data.zone || {};
    var groupLabel = zone.group || 'default';
    // When nothing matched (match_type is "none"/empty), just show the plain
    // group name ("default") instead of a noisy "none (default)" label.
    var zoneInfo = (zone.match_type && zone.match_type !== 'none')
        ? zone.match_type + ' (' + groupLabel + ')'
        : groupLabel;
    parts.push(zoneInfo);

    var upstream = data.upstream || {};
    var servers = upstream.servers || [];
    var hostnames = upstream.hostnames || [];
    if (upstream.providers && upstream.providers.length) {
        var viaText = '';
        if (hostnames[0]) {
            // hostname (ip:port) format
            viaText = hostnames[0] + (servers[0] ? ' (' + servers[0] + ')' : '');
        } else if (servers[0]) {
            viaText = servers[0];
        }
        parts.push(upstream.providers.join(', ') + (viaText ? ' via ' + viaText : ''));
    }

    // IP at the end; append count in parentheses when >1 address resolved
    if (sIps.length > 1) {
        parts.push(sIps[0] + ' (' + sIps.length + ' IPs)');
    } else if (sIps.length === 1) {
        parts.push(sIps[0]);
    }

    return parts.join(' \u2192 ');
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
        if (data.dns.resolver) rows.push('<tr><td>Resolver</td><td>' + EW.escapeHtml(data.dns.resolver) + '</td></tr>');
        if (data.dns.group) rows.push('<tr><td>Group</td><td>' + EW.escapeHtml(data.dns.group) + '</td></tr>');
        if (data.dns.ips) rows.push('<tr><td>IPs</td><td>' + _multiLine(data.dns.ips.map(EW.escapeHtml)) + '</td></tr>');
        if (data.dns.time_ms !== undefined) rows.push('<tr><td>Time</td><td>' + data.dns.time_ms + 'ms</td></tr>');
    }

    // CIDR Coverage section (only for CIDR input)
    if (data.input_type === 'cidr' && data.coverage) {
        var cov = data.coverage;
        var pct = cov.geo_split_pct || 0;
        var barColor = pct === 100 ? '#4caf50' : (pct > 0 ? '#ff9800' : '#666');
        rows.push('<tr><th colspan="2">CIDR Coverage (' + pct + '% geo-split)</th></tr>');
        rows.push('<tr><td colspan="2"><div style="background:#333;border-radius:3px;height:8px;overflow:hidden;margin:2px 0">' +
            '<div style="width:' + pct + '%;height:100%;background:' + barColor + '"></div></div>' +
            '<span style="font-size:11px;color:#aaa">' +
            (cov.geo_split_ips || 0).toLocaleString() + ' / ' + (cov.total_ips || 0).toLocaleString() + ' IPs</span></td></tr>');
        // Show top overlapping subnets (max 8, sorted by IP count desc)
        if (cov.overlaps && cov.overlaps.length > 0) {
            var sorted = cov.overlaps.slice().sort(function(a, b) { return (b.ips || 0) - (a.ips || 0); });
            var show = Math.min(sorted.length, 8);
            for (var ci = 0; ci < show; ci++) {
                var ov = sorted[ci];
                var devL = ov.dev ? EW.ifaceLabelShort(ov.dev) : '?';
                rows.push('<tr><td>' + EW.escapeHtml(ov.prefix) + '</td><td>' + EW.escapeHtml(devL) +
                    ' <span style="color:#888">' + ov.table_name + ', ' + (ov.ips || 0).toLocaleString() + ' IPs</span></td></tr>');
            }
            if (sorted.length > show) {
                rows.push('<tr><td colspan="2" style="color:#888;font-size:11px">+' + (sorted.length - show) + ' more subnets</td></tr>');
            }
        }
    }

    // All routes per IP (expanded table)
    if (data.routes && data.routes.length > 0) {
        var routeLabel = (data.input_type === 'cidr') ? 'Sampled Routes' : 'Routes per IP';
        rows.push('<tr><th colspan="2">' + routeLabel + ' (' + data.routes.length + ')</th></tr>');
        for (var i = 0; i < data.routes.length; i++) {
            var r = data.routes[i];
            var verdictBadge = r.verdict ? ' <span class="rc-verdict-badge rc-verdict-badge--' + EW.escapeHtml(r.verdict) + '">' + EW.escapeHtml(r.verdict) + '</span>' : '';
            var devLabel = r.dev ? EW.ifaceLabelShort(r.dev) : '?';
            var prefix = (r.match_prefix && r.match_prefix !== 'default') ? ' [' + r.match_prefix + ']' : '';
            rows.push('<tr class="rc-route-row rc-route-row--' + EW.escapeHtml(r.verdict || 'default') + '"><td>' + EW.escapeHtml(r.ip) + '</td><td>' + EW.escapeHtml(devLabel) + prefix + verdictBadge + '</td></tr>');
        }
    }

    // Route devices — unique devices from sampled routes + CIDR coverage overlaps
    var routeDevs = {};
    if (data.routes && data.routes.length > 0) {
        for (var ri = 0; ri < data.routes.length; ri++) {
            var rd = data.routes[ri];
            if (rd.dev && !routeDevs[rd.dev]) {
                routeDevs[rd.dev] = { verdict: rd.verdict || 'default', via: rd.via || '', table_name: rd.table_name || '' };
            }
        }
    }
    // Add devices from CIDR coverage overlaps missing in sampled routes
    if (data.input_type === 'cidr' && data.coverage && data.coverage.overlaps) {
        for (var oi = 0; oi < data.coverage.overlaps.length; oi++) {
            var ov2 = data.coverage.overlaps[oi];
            if (ov2.dev && !routeDevs[ov2.dev]) {
                routeDevs[ov2.dev] = { verdict: 'geo-split', via: ov2.via || '', table_name: ov2.table_name || '' };
            }
        }
    }
    var devKeys = Object.keys(routeDevs);
    if (devKeys.length > 0) {
        rows.push('<tr><th colspan="2">Route Devices</th></tr>');
        for (var di = 0; di < devKeys.length; di++) {
            var dk = devKeys[di];
            var info = routeDevs[dk];
            var verdictLabel = info.verdict === 'geo-split' ? 'geo' : info.verdict;
            var viaText = info.via ? ' via ' + info.via : '';
            var tableText = info.table_name ? ' <span style="color:#888">\u00b7 ' + EW.escapeHtml(info.table_name) + '</span>' : '';
            rows.push('<tr><td>' + EW.escapeHtml(verdictLabel) + '</td><td>' + EW.escapeHtml(EW.ifaceLabelShort(dk)) + ' (' + EW.escapeHtml(dk) + ')' + EW.escapeHtml(viaText) + tableText + '</td></tr>');
        }
    } else if (data.default_route && data.default_route.dev) {
        var defVia = data.default_route.via ? ' via ' + data.default_route.via : '';
        rows.push('<tr><th colspan="2">Route Devices</th></tr>');
        rows.push('<tr><td>default</td><td>' + EW.escapeHtml(EW.ifaceLabelShort(data.default_route.dev)) + ' (' + EW.escapeHtml(data.default_route.dev) + ')' + EW.escapeHtml(defVia) + '</td></tr>');
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

    // DNS source indicator
    if (data.dns_source) {
        rows.push('<tr><th colspan="2">DNS Source</th></tr>');
        var srcLabel = data.dns_source === 'system'
            ? 'System DNS (:' + (data.dns_port || 53) + ') \u2014 zone routing not active'
            : 'SmartDNS (:' + (data.dns_port || 6053) + ')';
        rows.push('<tr><td>Resolver</td><td>' + EW.escapeHtml(srcLabel) + '</td></tr>');
    }

    if (data.zone) {
        rows.push('<tr><th colspan="2">Zone</th></tr>');
        if (data.zone.group) rows.push('<tr><td>Group</td><td>' + EW.escapeHtml(data.zone.group) + '</td></tr>');
        if (data.zone.match_rule) rows.push('<tr><td>Match rule</td><td>' + EW.escapeHtml(data.zone.match_rule) + '</td></tr>');
        if (data.zone.match_type) rows.push('<tr><td>Match type</td><td>' + EW.escapeHtml(data.zone.match_type) + '</td></tr>');
    }

    if (data.upstream) {
        rows.push('<tr><th colspan="2">Upstream</th></tr>');
        if (data.upstream.providers) rows.push('<tr><td>Providers</td><td>' + _multiLine(data.upstream.providers.map(EW.escapeHtml)) + '</td></tr>');
        if (data.upstream.servers) {
            // Pair each server with its hostname (if available) on separate lines
            var srvLines = [];
            var hostnames = data.upstream.hostnames || [];
            for (var si = 0; si < data.upstream.servers.length; si++) {
                var srv = EW.escapeHtml(data.upstream.servers[si]);
                var hn = hostnames[si] ? EW.escapeHtml(hostnames[si]) : '';
                srvLines.push(hn ? hn + ' (' + srv + ')' : srv);
            }
            rows.push('<tr><td>Servers</td><td>' + _multiLine(srvLines) + '</td></tr>');
        }
        if (data.upstream.interface) {
            // Interface may be space-separated list; split and label each
            // Format: "Label (dev)" per interface, like Route Check details
            var ifaces = data.upstream.interface.split(/\s+/).filter(function(s) { return s && s !== 'default'; });
            if (ifaces.length) {
                var ifParts = ifaces.map(function(iif) {
                    var label = EW.ifaceLabelShort(iif);
                    return (label !== iif) ? label + ' (' + iif + ')' : iif;
                });
                rows.push('<tr><td>Interface</td><td>' + _multiLine(ifParts.map(EW.escapeHtml)) + '</td></tr>');
            } else if (data.upstream.interface.indexOf('direct') >= 0) {
                rows.push('<tr><td>Interface</td><td>direct</td></tr>');
            }
        }
    }

    if (data.result) {
        rows.push('<tr><th colspan="2">Result</th></tr>');
        if (data.result.ips) rows.push('<tr><td>IPs</td><td>' + _multiLine(data.result.ips.map(EW.escapeHtml)) + '</td></tr>');
        if (data.result.ttl !== undefined) rows.push('<tr><td>TTL</td><td>' + data.result.ttl + '</td></tr>');
        if (data.result.time_ms !== undefined) rows.push('<tr><td>Time</td><td>' + data.result.time_ms + 'ms</td></tr>');
    }

    if (rows.length === 0) return '';
    return '<table class="rc-details-table">' + rows.join('') + '</table>';
}

/**
 * Wrap array of HTML strings into separator-lined divs.
 * Single item → plain text (no wrapper). Multiple → div per item with thin borders.
 * @param {Array<string>} items - pre-escaped HTML strings
 * @returns {string} HTML
 */
function _multiLine(items) {
    if (items.length <= 1) return items[0] || '';
    return '<div class="rc-mline">' + items.join('</div><div class="rc-mline">') + '</div>';
}

/**
 * Render a single full result card (SVG + summary + details).
 * @param {HTMLElement} container - parent to append into
 * @param {Object} data - API response
 * @param {string} type - "route" or "dns"
 */
function _renderFullResult(container, data, type) {
    var wrapper = document.createElement('div');
    wrapper.className = 'rc-result ' + _getVerdictClass(data, type);

    // Legend label on border (query + icon + verdict/zone-group)
    var query = data && data.query;
    if (query) {
        var legend = document.createElement('span');
        legend.className = 'rc-result__legend';
        if (type === 'dns') {
            if (data.dns_source === 'system') {
                // System DNS fallback — show port instead of zone group
                legend.textContent = query + ' \u2192 system :' + (data.dns_port || 53);
            } else {
                // DNS Check has no top-level verdict — use matched zone group instead,
                // same visual pattern as Route Check's "query + icon + verdict".
                var zone = data.zone || {};
                var groupLabel = zone.group || 'default';
                var isDefaultGroup = groupLabel === 'default';
                var dIcon = isDefaultGroup ? '\u2192' : '\u21c4';
                legend.textContent = query + ' ' + dIcon + ' ' + groupLabel;
            }
        } else {
            var verdict = (data && data.verdict) ? data.verdict : '';
            if (verdict) {
                var isPolicy = verdict === 'default';
                var displayVerdict = isPolicy ? 'policy' : verdict;
                // Append CIDR coverage % for mixed verdict (<1% when rounds to 0)
                if (verdict === 'mixed' && data.input_type === 'cidr' && data.coverage) {
                    var pctLabel = (data.coverage.geo_split_pct === 0 && data.coverage.geo_split_ips > 0) ? '<1' : data.coverage.geo_split_pct;
                    displayVerdict += ' ' + pctLabel + '%';
                }
                var lIcon = verdict === 'geo-split' ? '\u21c4' : (verdict === 'tunnel' ? '\u2299' : (verdict === 'mixed' ? '\u26a0' : (isPolicy ? '\u229E' : '\u21d2')));
                legend.textContent = query + ' ' + lIcon + ' ' + displayVerdict;
            } else {
                legend.textContent = query;
            }
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
