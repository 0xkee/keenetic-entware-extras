// app-sysinfo.js — System info bar for Entware Extras WebUI.
// Extracted from app.js for maintainability.
// Depends on: shared.js (EW.escapeHtml).
// Called from: refreshAll() in app.js.
"use strict";

// ── System info ──────────────────────────────────────────────────────────────

// Inline SVG icons for sysinfo bar (12x12, fill:currentColor)
var SYSINFO_ICONS = {
    host: '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" style="vertical-align:-1px"><path d="M20 18c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2H4c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2H1v2h22v-2h-3zM4 6h16v10H4V6z"/></svg>',
    up: '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" style="vertical-align:-1px"><path d="M12 2C6.5 2 2 6.5 2 12s4.5 10 10 10 10-4.5 10-10S17.5 2 12 2zm0 18c-4.4 0-8-3.6-8-8s3.6-8 8-8 8 3.6 8 8-3.6 8-8 8zm.5-13H11v6l5.2 3.2.8-1.3-4.5-2.7V7z"/></svg>',
    cpu: '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" style="vertical-align:-1px"><path d="M15 9H9v6h6V9zm-2 4h-2v-2h2v2zm8-2V9h-2V7c0-1.1-.9-2-2-2h-2V3h-2v2h-2V3H9v2H7c-1.1 0-2 .9-2 2v2H3v2h2v2H3v2h2v2c0 1.1.9 2 2 2h2v2h2v-2h2v2h2v-2h2c1.1 0 2-.9 2-2v-2h2v-2h-2v-2h2zm-4 6H7V7h10v10z"/></svg>',
    temp: '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" style="vertical-align:-1px"><path d="M15 13V5c0-1.66-1.34-3-3-3S9 3.34 9 5v8c-1.21.91-2 2.37-2 4 0 2.76 2.24 5 5 5s5-2.24 5-5c0-1.63-.79-3.09-2-4zm-4-8c0-.55.45-1 1-1s1 .45 1 1h-1v1h1v2h-1v1h1v2h-2V5z"/></svg>',
    ram: '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" style="vertical-align:-1px"><path d="M2 7v10h20V7H2zm18 8H4V9h16v6zM6 11h2v2H6zm3 0h2v2H9zm3 0h2v2h-2zm3 0h2v2h-2z"/></svg>',
    disk: '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" style="vertical-align:-1px"><path d="M20 6H12L10 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm0 12H4V8h16v10z"/></svg>'
};

/**
 * Fetch system info (hostname, uptime, RAM, disk, CPU, temperature) and render header bar.
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
                diskPct = Math.ceil((data.disk_opt.used_kb / data.disk_opt.total_kb) * 100);
            }

            // CPU: prefer /proc/stat delta (cpu_pct) — actual utilization.
            // Fallback to load1/cores when cpu_pct not yet available (-1 on first poll).
            var cpuCores = (data.cpu_load && data.cpu_load.cores) || 1;
            var cpuLoad1 = (data.cpu_load && data.cpu_load.load1) || 0;
            var cpuStatPct = data.cpu_load ? data.cpu_load.cpu_pct : -1;
            var cpuPct = cpuStatPct >= 0
                ? cpuStatPct
                : Math.min(100, Math.round((cpuLoad1 / cpuCores) * 100));

            // CPU temperature (optional — null when thermal zone absent on this SoC).
            // Thresholds and Tj_max from SoC datasheet, resolved server-side.
            var tempHtml = '';
            if (data.cpu_temp != null && data.cpu_temp_limits) {
                var tl = data.cpu_temp_limits;
                var tempPct = Math.max(0, Math.min(100, Math.round(data.cpu_temp / tl.max * 100)));
                var tempClass = data.cpu_temp > tl.crit ? " ew-sysinfo__bar-fill--crit" : data.cpu_temp > tl.warn ? " ew-sysinfo__bar-fill--warn" : "";
                tempHtml =
                    '<span class="ew-sysinfo__item" data-tooltip="' +
                        'CPU temperature: ' + data.cpu_temp + '°C (sensor: ' + EW.escapeHtml(tl.type) + ')\n' +
                        'Thresholds: >' + tl.warn + '°C warning, >' + tl.crit + '°C critical\n' +
                        'Tj_max: ' + tl.max + '°C (SoC datasheet maximum)' + '" data-tooltip-pos="below">' +
                        '<span class="ew-sysinfo__icon">' + SYSINFO_ICONS.temp + '</span>' +
                        '<span class="ew-sysinfo__value">' + data.cpu_temp + '°C</span>' +
                        '<span class="ew-sysinfo__bar"><span class="ew-sysinfo__bar-fill' + tempClass + '" style="width:' + tempPct + '%"></span></span>' +
                    '</span>';
            }

            var cpuClass = cpuPct > 90 ? " ew-sysinfo__bar-fill--crit" : cpuPct > 75 ? " ew-sysinfo__bar-fill--warn" : "";
            var memClass = memPct > 90 ? " ew-sysinfo__bar-fill--crit" : memPct > 75 ? " ew-sysinfo__bar-fill--warn" : "";
            var diskClass = diskPct > 90 ? " ew-sysinfo__bar-fill--crit" : diskPct > 75 ? " ew-sysinfo__bar-fill--warn" : "";

            el.innerHTML =
                '<span class="ew-sysinfo__item">' +
                    '<span class="ew-sysinfo__icon">' + SYSINFO_ICONS.host + '</span>' +
                    '<span class="ew-sysinfo__value">' + EW.escapeHtml(data.hostname || "router") + '</span>' +
                '</span>' +
                '<span class="ew-sysinfo__item">' +
                    '<span class="ew-sysinfo__icon">' + SYSINFO_ICONS.up + '</span>' +
                    '<span class="ew-sysinfo__label">up</span>' +
                    '<span class="ew-sysinfo__value">' + EW.escapeHtml(data.uptime || "?") + '</span>' +
                '</span>' +
                '<span class="ew-sysinfo__item" data-tooltip="' +
                    'Utilization: ' + cpuPct + '% (from /proc/stat)\n' +
                    'Load avg: ' + cpuLoad1.toFixed(2) + ' / ' + cpuCores + ' cores\n' +
                    'Load average includes I/O wait — may be higher than actual CPU usage.' + '" data-tooltip-pos="below">' +
                    '<span class="ew-sysinfo__icon">' + SYSINFO_ICONS.cpu + '</span>' +
                    '<span class="ew-sysinfo__label">CPU</span>' +
                    '<span class="ew-sysinfo__value">' + cpuPct + '%</span>' +
                    '<span class="ew-sysinfo__bar"><span class="ew-sysinfo__bar-fill' + cpuClass + '" style="width:' + cpuPct + '%"></span></span>' +
                '</span>' +
                tempHtml +
                '<span class="ew-sysinfo__item" data-tooltip="' +
                    'Available: ' + Math.round(data.memory.available_kb / 1024) + ' MB / ' + Math.round(data.memory.total_kb / 1024) + ' MB\n' +
                    'Conservative estimate — accounts for memory locked by kernel (conntrack, routing tables, slab cache) that cannot be freed.\n' +
                    'May show ~15% higher usage than stock UI — this is normal and not a cause for concern.' + '" data-tooltip-pos="below">' +
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
