// detail-render.js — Detail rendering helpers for Entware Extras WebUI.
// Extracted from app.js; shared helpers (EW.renderRulesDetail, EW.renderDnsTests)
// are used by both app.js (custom dashboard) and inject-dashboard.js (stock Keenetic page).
"use strict";

/** Key detail labels shown in Summary mode per service. Others are hidden via CSS. */
var SUMMARY_KEYS = {
    'geo-split':         ['geo_zone', 'active_zones', 'subnets', 'domains', 'route_in', 'route_out'],
    'smartdns':          ['dns_zone', 'active_zones', 'zone_dns_providers', 'other_dns_providers', 'custom_providers', 'servers', 'rules'],
    'smartdns-redirect': ['interfaces', 'name'],
    'webui':             ['firmware', 'patch_set']
};

/** Get skeleton count for a service: cached from last API response, or default 9. */
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

/**
 * Render rules_detail per-iface condensed breakdown into HTML.
 * Replaces the "Rules" detail item value with per-interface summary lines.
 * All OK: "br0: v4+v6 DNS/DoT" — one line per iface.
 * Failures: "br0: v4+v6 DNS/DoT (6/8)" + per-failure "✗ v4 udp DoT".
 * @param {Array} rulesDetail - data.rules_detail array from API
 * @param {string} html - current details HTML string
 * @returns {string} modified HTML with rules breakdown injected
 */
EW.renderRulesDetail = function(rulesDetail, html) {
    if (!rulesDetail || !rulesDetail.length) return html;

    var byIface = {}, order = [];
    for (var i = 0; i < rulesDetail.length; i++) {
        var r = rulesDetail[i];
        if (!byIface[r.iface]) { byIface[r.iface] = []; order.push(r.iface); }
        byIface[r.iface].push(r);
    }

    var lines = [];
    for (var g = 0; g < order.length; g++) {
        var iface = order[g];
        var rules = byIface[iface];
        var allOk = true, okCount = 0;
        var famSet = {}, portSet = {};
        for (var j = 0; j < rules.length; j++) {
            famSet[rules[j].family] = 1;
            portSet[rules[j].type === 'dot_block' ? 'DoT' : 'DNS'] = 1;
            if (rules[j].ok) { okCount++; } else { allOk = false; }
        }
        var fams = (famSet.v4 ? 'v4' : '') + (famSet.v4 && famSet.v6 ? '+' : '') + (famSet.v6 ? 'v6' : '');
        var ports = (portSet.DNS ? 'DNS' : '') + (portSet.DNS && portSet.DoT ? '/' : '') + (portSet.DoT ? 'DoT' : '');
        var line = EW.escapeHtml(iface) + ': ' + EW.escapeHtml(fams + ' ' + ports);
        if (!allOk) line += ' (' + okCount + '/' + rules.length + ')';
        lines.push(line);

        if (!allOk) {
            for (var k = 0; k < rules.length; k++) {
                if (!rules[k].ok) {
                    lines.push('\u00a0\u00a0<span class="ew-bool-icon ew-bool-icon--fail">\u2717</span> ' +
                        EW.escapeHtml(rules[k].family + ' ' + rules[k].proto + ' ' + (rules[k].type === 'dot_block' ? 'DoT' : 'DNS')));
                }
            }
        }
    }

    var breakdown = '<div class="ew-dns-line">' + lines.join('</div><div class="ew-dns-line">') + '</div>';
    var rp = html.indexOf('ew-detail-label">Rules<');
    if (rp !== -1) {
        var vp = html.indexOf('ew-detail-value', rp);
        if (vp !== -1) {
            var endTag = html.indexOf('</div>', html.indexOf('>', vp) + 1);
            if (endTag !== -1) {
                html = html.substring(0, vp) + 'ew-detail-value">' + breakdown + html.substring(endTag);
            }
        }
    }
    return html;
};

/**
 * Render DNS test results into HTML.
 * Inserts a "DNS Tests" detail item before the "Cache" item, or appends at end.
 * Each test line: checkmark/cross icon + linked domain + arrow + result.
 * @param {Array} dnsTests - data.dns_tests array from API
 * @param {string} html - current details HTML string
 * @returns {string} modified HTML with DNS tests item inserted
 */
EW.renderDnsTests = function(dnsTests, html) {
    if (!dnsTests || !dnsTests.length) return html;

    var dnsLines = [];
    for (var i = 0; i < dnsTests.length; i++) {
        var t = dnsTests[i];
        var ok = t.result && t.result !== 'FAILED';
        var icon = ok ? '\u2713' : '\u2717';
        var cls = ok ? 'ew-bool-icon--ok' : 'ew-bool-icon--fail';
        dnsLines.push('<span class="ew-bool-icon ' + cls + '">' + icon + '</span> ' +
            '<a class="ew-dns-link" href="https://' + EW.escapeHtml(t.domain) + '" target="_blank" rel="noopener">' +
            EW.escapeHtml(t.domain) + '</a> \u2192 ' + EW.escapeHtml(t.result || 'FAILED'));
    }

    var dnsItem = '<div class="ew-detail-item" data-priority="low">' +
        '<div class="ew-detail-label">DNS Tests</div>' +
        '<div class="ew-detail-value">' +
        '<div class="ew-dns-line">' + dnsLines.join('</div><div class="ew-dns-line">') + '</div>' +
        '</div></div>';

    // Insert before "Cache" item if present, otherwise append
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
    return html;
};

/**
 * Set structured details for a service card.
 * Uses EW.parseDetails() for parsing, wraps entries in list rows.
 * Calls EW.renderRulesDetail() and EW.renderDnsTests() for shared rendering.
 * @param {string} id - service id
 * @param {Object} data - full JSON response from API
 */
function setDetails(id, data) {
    var el = document.getElementById("details-" + id);
    if (!el) return;
    if (!data.details) { el.innerHTML = ""; return; }

    var entries = EW.parseDetails(data.details, { isRunning: data.running, serviceId: id, checks: data.checks });
    var html = "";
    var summaryKeys = SUMMARY_KEYS[id] || [];
    for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        if (e.isSpacer) { html += '<div class="ew-detail-item"></div>'; continue; }

        // Base rendering from shared
        var valHtml = EW.renderDetailValue(e, { dnsServerChecks: data.dns_server_checks });
        var valStyle = EW.detailValueStyle(e);

        // app.js-specific: priority for summary condensed mode
        var priority = (summaryKeys.indexOf(e.key) !== -1) ? 'high' : 'low';
        if (priority === 'high' && e.shortValue) {
            valHtml = '<span class="ew-val-short">' + EW.escapeHtml(e.shortValue) + '</span>' +
                '<span class="ew-val-full">' + valHtml + '</span>';
        }

        // app.js-specific: version badge link
        if (e.label.toLowerCase() === 'version') {
            // TODO: replace forum link with GitHub releases URL when available
            valHtml = '<a class="ew-version-badge" href="https://forum.keenetic.ru/topic/28369-geo-split-routing-%D0%B4%D0%BB%D1%8F-keenetic-%D1%81-entware-geoip-%D0%B4%D0%BE%D0%BC%D0%B5%D0%BD%D1%8B-ipk-%D0%BF%D0%B0%D0%BA%D0%B5%D1%82%D1%8B/" target="_blank" rel="noopener" data-tooltip="Open project page">' + EW.escapeHtml(e.value) + '</a>';
        }

        var isNumericOnly = /^\d[\d,.]*[KMG]?[Bb]?$/.test(e.value.trim());
        var numClass = isNumericOnly ? ' ew-detail-value--numeric' : '';
        var updateBtn = EW.renderUpdateBtn(e);
        var dataAttr = e.freshnessKey ? ' data-freshness-key="' + e.freshnessKey + '"' : '';
        html += '<div class="ew-detail-item" data-priority="' + priority + '">' +
            '<div class="ew-detail-label">' + EW.escapeHtml(e.label) + '</div>' +
            '<div class="ew-detail-value' + numClass + '"' + valStyle + dataAttr + '>' + valHtml + updateBtn + '</div></div>';
    }

    // Shared: rules_detail and dns_tests rendering
    html = EW.renderRulesDetail(data.rules_detail, html);
    html = EW.renderDnsTests(data.dns_tests, html);

    // Cache real field count for next page load skeleton rendering
    var dnsExtra = (data.dns_tests && data.dns_tests.length) ? 1 : 0;
    var realCount = entries.filter(function(e) { return !e.isSpacer; }).length + dnsExtra;
    saveSkeletonCount(id, realCount);
    el.innerHTML = html;
}
