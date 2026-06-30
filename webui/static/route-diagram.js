// route-diagram.js — SVG diagram renderer for Route Check and DNS Check.
// Vanilla JS (ES5), no dependencies. Uses inline SVG via createElementNS.
// Public API: renderRouteDiagram(container, data), renderDnsDiagram(container, data)

"use strict";

var SVG_NS = "http://www.w3.org/2000/svg";

/**
 * Get human-readable label for an interface from the cached map.
 * Falls back to the raw device name if map is unavailable.
 * @param {string} dev - technical interface name
 * @returns {string}
 */
function _ifaceLabel(dev) {
    if (!dev) return "";
    var map = window._ewIfaceMap;
    return (map && map[dev]) ? map[dev] : dev;
}

// ── SVG helpers ──────────────────────────────────────────────────────────────

/**
 * Create an SVG element with attributes.
 * @param {string} tag - SVG element tag name
 * @param {Object} attrs - attributes map
 * @returns {SVGElement}
 */
function _svgEl(tag, attrs) {
    var el = document.createElementNS(SVG_NS, tag);
    if (attrs) {
        for (var k in attrs) {
            if (attrs.hasOwnProperty(k)) {
                el.setAttribute(k, attrs[k]);
            }
        }
    }
    return el;
}

/**
 * Create an SVG text element.
 * @param {string} text - text content
 * @param {number} x - x position
 * @param {number} y - y position
 * @param {string} cssClass - CSS class
 * @returns {SVGTextElement}
 */
function _svgText(text, x, y, cssClass) {
    var el = _svgEl("text", { x: x, y: y, "class": cssClass });
    el.textContent = text;
    return el;
}

/**
 * Draw a polyline path between points.
 * @param {Array} points - [[x1,y1],[x2,y2],...]
 * @param {string} cssClass - CSS class for the path
 * @returns {SVGPolylineElement}
 */
function _svgPolyline(points, cssClass) {
    var pts = [];
    for (var i = 0; i < points.length; i++) {
        pts.push(points[i][0] + "," + points[i][1]);
    }
    return _svgEl("polyline", {
        points: pts.join(" "),
        "class": cssClass,
        fill: "none"
    });
}

/**
 * Draw a line between two points.
 * @param {number} x1
 * @param {number} y1
 * @param {number} x2
 * @param {number} y2
 * @param {string} cssClass
 * @returns {SVGLineElement}
 */
function _svgLine(x1, y1, x2, y2, cssClass) {
    return _svgEl("line", {
        x1: x1, y1: y1, x2: x2, y2: y2,
        "class": cssClass
    });
}

// ── Icon renderers (simple geometric shapes) ─────────────────────────────────

/**
 * Client icon — monitor with stand.
 * @param {number} cx - center x
 * @param {number} cy - center y
 * @param {string} [extraClass] - additional CSS class
 * @returns {SVGGElement}
 */
function _iconClient(cx, cy, extraClass) {
    var g = _svgEl("g", { "class": "route-icon" + (extraClass ? " " + extraClass : "") });
    // Monitor body
    g.appendChild(_svgEl("rect", { x: cx - 12, y: cy - 10, width: 24, height: 16, rx: 2 }));
    // Screen inner
    g.appendChild(_svgEl("line", { x1: cx, y1: cy + 6, x2: cx, y2: cy + 10 }));
    // Stand base
    g.appendChild(_svgEl("line", { x1: cx - 6, y1: cy + 10, x2: cx + 6, y2: cy + 10 }));
    return g;
}

/**
 * Router icon — box with antennas.
 * @param {number} cx - center x
 * @param {number} cy - center y
 * @param {string} [extraClass]
 * @returns {SVGGElement}
 */
function _iconRouter(cx, cy, extraClass) {
    var g = _svgEl("g", { "class": "route-icon" + (extraClass ? " " + extraClass : "") });
    // Body
    g.appendChild(_svgEl("rect", { x: cx - 14, y: cy - 4, width: 28, height: 14, rx: 3 }));
    // Antennas
    g.appendChild(_svgEl("line", { x1: cx - 7, y1: cy - 4, x2: cx - 9, y2: cy - 14 }));
    g.appendChild(_svgEl("line", { x1: cx, y1: cy - 4, x2: cx, y2: cy - 16 }));
    g.appendChild(_svgEl("line", { x1: cx + 7, y1: cy - 4, x2: cx + 9, y2: cy - 14 }));
    // LED dots
    g.appendChild(_svgEl("circle", { cx: cx - 5, cy: cy + 3, r: 1.5 }));
    g.appendChild(_svgEl("circle", { cx: cx, cy: cy + 3, r: 1.5 }));
    g.appendChild(_svgEl("circle", { cx: cx + 5, cy: cy + 3, r: 1.5 }));
    return g;
}

/**
 * Cloud icon (Internet).
 * @param {number} cx - center x
 * @param {number} cy - center y
 * @param {string} [extraClass]
 * @returns {SVGGElement}
 */
function _iconCloud(cx, cy, extraClass) {
    var g = _svgEl("g", { "class": "route-icon" + (extraClass ? " " + extraClass : "") });
    // Classic cumulus cloud: 3 bumps on top, flat bottom, no rays
    g.appendChild(_svgEl("path", {
        d: "M" + (cx - 12) + "," + (cy + 7) +
           " L" + (cx + 12) + "," + (cy + 7) +
           " C" + (cx + 16) + "," + (cy + 7) + " " + (cx + 18) + "," + (cy + 4) + " " + (cx + 18) + "," + (cy + 1) +
           " C" + (cx + 18) + "," + (cy - 3) + " " + (cx + 15) + "," + (cy - 6) + " " + (cx + 11) + "," + (cy - 6) +
           " C" + (cx + 10) + "," + (cy - 10) + " " + (cx + 6) + "," + (cy - 12) + " " + (cx + 2) + "," + (cy - 12) +
           " C" + (cx - 3) + "," + (cy - 12) + " " + (cx - 7) + "," + (cy - 10) + " " + (cx - 9) + "," + (cy - 7) +
           " C" + (cx - 13) + "," + (cy - 7) + " " + (cx - 17) + "," + (cy - 4) + " " + (cx - 17) + "," + cy +
           " C" + (cx - 17) + "," + (cy + 4) + " " + (cx - 14) + "," + (cy + 7) + " " + (cx - 12) + "," + (cy + 7) +
           " Z"
    }));
    return g;
}

/**
 * DNS icon — circle with "DNS" text.
 * @param {number} cx
 * @param {number} cy
 * @param {string} [extraClass]
 * @returns {SVGGElement}
 */
function _iconDns(cx, cy, extraClass) {
    var g = _svgEl("g", { "class": "route-icon" + (extraClass ? " " + extraClass : "") });
    g.appendChild(_svgEl("circle", { cx: cx, cy: cy, r: 13 }));
    var txt = _svgEl("text", {
        x: cx, y: cy + 3.5,
        "text-anchor": "middle",
        "font-size": "7",
        "font-weight": "600",
        fill: "currentColor",
        "class": "route-node-label"
    });
    txt.textContent = "DNS";
    g.appendChild(txt);
    return g;
}

/**
 * Interface/port icon — small rectangle with cable.
 * @param {number} cx
 * @param {number} cy
 * @param {string} [extraClass]
 * @returns {SVGGElement}
 */
function _iconInterface(cx, cy, extraClass) {
    var g = _svgEl("g", { "class": "route-icon" + (extraClass ? " " + extraClass : "") });
    g.appendChild(_svgEl("rect", { x: cx - 8, y: cy - 6, width: 16, height: 12, rx: 2 }));
    // Horizontal lines (port look)
    g.appendChild(_svgEl("line", { x1: cx - 5, y1: cy - 2, x2: cx + 5, y2: cy - 2 }));
    g.appendChild(_svgEl("line", { x1: cx - 5, y1: cy + 1, x2: cx + 5, y2: cy + 1 }));
    g.appendChild(_svgEl("line", { x1: cx - 5, y1: cy + 4, x2: cx + 5, y2: cy + 4 }));
    return g;
}

/**
 * Globe icon — circle with meridians and equator (provider/ISP).
 * @param {number} cx - center x
 * @param {number} cy - center y
 * @param {string} [extraClass]
 * @returns {SVGGElement}
 */
function _iconGlobe(cx, cy, extraClass) {
    var g = _svgEl("g", { "class": "route-icon" + (extraClass ? " " + extraClass : "") });
    var r = 12;
    // Outer circle (globe outline)
    g.appendChild(_svgEl("circle", { cx: cx, cy: cy, r: r }));
    // Equator (horizontal line through center)
    g.appendChild(_svgEl("line", { x1: cx - r, y1: cy, x2: cx + r, y2: cy }));
    // Central meridian (vertical ellipse)
    g.appendChild(_svgEl("ellipse", { cx: cx, cy: cy, rx: 5, ry: r }));
    // Latitude lines (upper and lower arcs via short lines within circle)
    g.appendChild(_svgEl("line", { x1: cx - 10, y1: cy - 5, x2: cx + 10, y2: cy - 5 }));
    g.appendChild(_svgEl("line", { x1: cx - 10, y1: cy + 5, x2: cx + 10, y2: cy + 5 }));
    return g;
}

/**
 * Shield icon — VPN/tunnel path indicator.
 * @param {number} cx - center x
 * @param {number} cy - center y
 * @param {string} [extraClass]
 * @returns {SVGGElement}
 */
function _iconShield(cx, cy, extraClass) {
    var g = _svgEl("g", { "class": "route-icon" + (extraClass ? " " + extraClass : "") });
    // Shield outline (pointed bottom)
    g.appendChild(_svgEl("path", {
        d: "M" + cx + "," + (cy - 12) +
           " L" + (cx + 10) + "," + (cy - 7) +
           " L" + (cx + 10) + "," + (cy + 2) +
           " Q" + (cx + 10) + "," + (cy + 8) + " " + cx + "," + (cy + 12) +
           " Q" + (cx - 10) + "," + (cy + 8) + " " + (cx - 10) + "," + (cy + 2) +
           " L" + (cx - 10) + "," + (cy - 7) +
           " Z"
    }));
    // Lock/keyhole mark inside
    g.appendChild(_svgEl("circle", { cx: cx, cy: cy - 2, r: 3 }));
    g.appendChild(_svgEl("line", { x1: cx, y1: cy + 1, x2: cx, y2: cy + 5 }));
    return g;
}

/**
 * Signpost icon — policy/NDM routing (two directional arrows on a pole).
 * @param {number} cx - center x
 * @param {number} cy - center y
 * @param {string} [extraClass]
 * @returns {SVGGElement}
 */
function _iconSignpost(cx, cy, extraClass) {
    var g = _svgEl("g", { "class": "route-icon" + (extraClass ? " " + extraClass : "") });
    // Vertical pole
    g.appendChild(_svgEl("line", { x1: cx, y1: cy - 12, x2: cx, y2: cy + 12 }));
    // Upper arrow sign (pointing right)
    g.appendChild(_svgEl("path", {
        d: "M" + (cx - 8) + "," + (cy - 11) +
           " L" + (cx + 5) + "," + (cy - 11) +
           " L" + (cx + 9) + "," + (cy - 8) +
           " L" + (cx + 5) + "," + (cy - 5) +
           " L" + (cx - 8) + "," + (cy - 5) + " Z"
    }));
    // Lower arrow sign (pointing left)
    g.appendChild(_svgEl("path", {
        d: "M" + (cx + 8) + "," + (cy + 1) +
           " L" + (cx - 5) + "," + (cy + 1) +
           " L" + (cx - 9) + "," + (cy + 4) +
           " L" + (cx - 5) + "," + (cy + 7) +
           " L" + (cx + 8) + "," + (cy + 7) + " Z"
    }));
    return g;
}

/**
 * Zone icon — filter/funnel shape.
 * @param {number} cx
 * @param {number} cy
 * @param {string} [extraClass]
 * @returns {SVGGElement}
 */
function _iconZone(cx, cy, extraClass) {
    var g = _svgEl("g", { "class": "route-icon" + (extraClass ? " " + extraClass : "") });
    // Funnel shape
    g.appendChild(_svgEl("path", {
        d: "M" + (cx - 10) + "," + (cy - 8) +
           " L" + (cx + 10) + "," + (cy - 8) +
           " L" + (cx + 4) + "," + (cy + 2) +
           " L" + (cx + 4) + "," + (cy + 8) +
           " L" + (cx - 4) + "," + (cy + 8) +
           " L" + (cx - 4) + "," + (cy + 2) +
           " Z"
    }));
    return g;
}

/**
 * Result/list icon — clipboard shape.
 * @param {number} cx
 * @param {number} cy
 * @param {string} [extraClass]
 * @returns {SVGGElement}
 */
function _iconResult(cx, cy, extraClass) {
    var g = _svgEl("g", { "class": "route-icon" + (extraClass ? " " + extraClass : "") });
    g.appendChild(_svgEl("rect", { x: cx - 9, y: cy - 10, width: 18, height: 22, rx: 2 }));
    // Clipboard clip
    g.appendChild(_svgEl("rect", { x: cx - 4, y: cy - 13, width: 8, height: 5, rx: 1 }));
    // Lines
    g.appendChild(_svgEl("line", { x1: cx - 5, y1: cy - 3, x2: cx + 5, y2: cy - 3 }));
    g.appendChild(_svgEl("line", { x1: cx - 5, y1: cy + 1, x2: cx + 5, y2: cy + 1 }));
    g.appendChild(_svgEl("line", { x1: cx - 5, y1: cy + 5, x2: cx + 3, y2: cy + 5 }));
    return g;
}

/**
 * Server icon — rack server with sections and LED dots.
 * @param {number} cx - center x
 * @param {number} cy - center y
 * @param {string} [extraClass]
 * @returns {SVGGElement}
 */
function _iconServer(cx, cy, extraClass) {
    var g = _svgEl("g", { "class": "route-icon" + (extraClass ? " " + extraClass : "") });
    // Server body
    g.appendChild(_svgEl("rect", { x: cx - 10, y: cy - 12, width: 20, height: 24, rx: 2 }));
    // Section dividers
    g.appendChild(_svgEl("line", { x1: cx - 10, y1: cy - 4, x2: cx + 10, y2: cy - 4 }));
    g.appendChild(_svgEl("line", { x1: cx - 10, y1: cy + 4, x2: cx + 10, y2: cy + 4 }));
    // LED dots (one per section)
    g.appendChild(_svgEl("circle", { cx: cx - 6, cy: cy - 8, r: 1.5 }));
    g.appendChild(_svgEl("circle", { cx: cx - 6, cy: cy, r: 1.5 }));
    g.appendChild(_svgEl("circle", { cx: cx - 6, cy: cy + 8, r: 1.5 }));
    return g;
}

// ── Error rendering ──────────────────────────────────────────────────────────

/**
 * Render error state into container (no diagram).
 * @param {HTMLElement} container
 * @param {Object} data - response with ok=false
 */
function _renderError(container, data) {
    var div = document.createElement("div");
    div.className = "route-diagram route-diagram--error";
    var title = document.createElement("div");
    title.className = "route-diagram__error-title";
    title.textContent = "⚠ Ошибка диагностики";
    div.appendChild(title);
    var msg = document.createElement("div");
    msg.className = "route-diagram__error-msg";
    msg.textContent = data.error || data.message || "Неизвестная ошибка";
    div.appendChild(msg);
    container.innerHTML = "";
    container.appendChild(div);
}

// ── Verdict badge renderer ───────────────────────────────────────────────────

/**
 * Render verdict badge in SVG.
 * @param {SVGElement} svg - parent SVG
 * @param {number} cx - center x
 * @param {number} cy - center y
 * @param {string} verdict - "geo-split", "default", or error text
 */
function _renderVerdict(svg, cx, cy, verdict, hasPolicy) {
    var isGeo = verdict === "geo-split";
    var isTunnel = verdict === "tunnel";
    var isMixed = verdict === "mixed";
    var isDefault = verdict === "default";
    var isPolicy = isDefault && hasPolicy;
    var label = isMixed ? "⚠ mixed" : (isGeo ? "✓ geo-split" : (isTunnel ? "= tunnel" : (isPolicy ? "⊙ policy" : (isDefault ? "→ default" : "✗ " + verdict))));
    var cls = isMixed ? "mixed" : (isGeo ? "geo" : (isTunnel ? "tunnel" : ((isPolicy || isDefault) ? "default" : "error")));

    var bgW = label.length * 5.5 + 16;
    svg.appendChild(_svgEl("rect", {
        x: cx - bgW / 2, y: cy - 8,
        width: bgW, height: 16,
        "class": "route-verdict-bg route-verdict-bg--" + cls
    }));
    var txt = _svgText(label, cx, cy + 4, "route-verdict-text route-verdict-text--" + cls);
    svg.appendChild(txt);
}

// ── Tool 1: Route Diagram (topology) ─────────────────────────────────────────

/**
 * Build list of all WAN paths for the diagram.
 * Uses data.all_paths if available (new backend), otherwise derives from legacy fields.
 * Each path: { dev, via, type, active }
 * @param {Object} data - API response
 * @returns {Array<Object>}
 */
function _buildPaths(data) {
    var activeRoute = (data.routes && data.routes.length > 0) ? data.routes[0] : null;
    var activeDev = activeRoute ? activeRoute.dev : (data.default_route ? data.default_route.dev : "");
    var defaultRoute = data.default_route || {};
    var tunnelRoute = data.tunnel_route || {};
    var isMixed = data.verdict === "mixed";

    // Collect all active devs (for mixed: all verdict_devs are active)
    var activeDevs = {};
    if (isMixed && data.verdict_devs) {
        for (var d = 0; d < data.verdict_devs.length; d++) {
            activeDevs[data.verdict_devs[d]] = true;
        }
    } else {
        activeDevs[activeDev] = true;
    }

    // If backend provides all_paths — use it directly
    if (data.all_paths && data.all_paths.length > 0) {
        var paths = [];
        for (var i = 0; i < data.all_paths.length; i++) {
            var p = data.all_paths[i];
            paths.push({
                dev: p.dev || "",
                via: p.via || "",
                type: p.type || "isp",
                active: !!activeDevs[p.dev || ""],
                mixed: isMixed && !!activeDevs[p.dev || ""]
            });
        }
        // Always append policy path (NDM default route) if not already present
        if (defaultRoute.dev) {
            var hasPolicy = false;
            for (var k = 0; k < paths.length; k++) {
                if (paths[k].type === "policy") { hasPolicy = true; break; }
            }
            if (!hasPolicy) {
                var isDefaultVerdict = (data.verdict === "default");
                var policyActive = !!activeDevs[defaultRoute.dev];
                var alreadySeen = false;
                for (var m = 0; m < paths.length; m++) {
                    if (paths[m].dev === defaultRoute.dev) { alreadySeen = true; break; }
                }
                // For "default" verdict, policy IS the active path (don't suppress)
                var policyIsActive = (alreadySeen && !isDefaultVerdict) ? false : policyActive;
                paths.push({ dev: defaultRoute.dev, via: defaultRoute.via || "", type: "policy", active: policyIsActive, mixed: isMixed && policyActive });
                // When policy is active on same dev, demote ISP/tunnel path to inactive
                if (policyIsActive && alreadySeen) {
                    for (var n = 0; n < paths.length; n++) {
                        if (paths[n].dev === defaultRoute.dev && paths[n].type !== "policy") {
                            paths[n].active = false;
                        }
                    }
                }
            }
        }
        return paths;
    }

    // Fallback: derive paths from legacy fields (up to 3 branches: ISP + VPN + Policy)
    var paths = [];
    var seen = {};

    // ISP path (geo-split route or config ROUTE_OUT)
    var ispDev = "";
    if (data.verdict === "geo-split" && activeRoute) {
        ispDev = activeRoute.dev;
    }
    if (ispDev) {
        paths.push({ dev: ispDev, via: activeRoute.via, type: "isp", active: true, mixed: isMixed && !!activeDevs[ispDev] });
        seen[ispDev] = true;
    }

    // VPN/tunnel path (client's VPN policy fwmark → policy table default route)
    var vpnDev = tunnelRoute.dev || "";
    if (vpnDev && !seen[vpnDev]) {
        paths.push({ dev: vpnDev, via: "", type: "tunnel", active: !!activeDevs[vpnDev], mixed: isMixed && !!activeDevs[vpnDev] });
        seen[vpnDev] = true;
    }

    // Policy path (NDM def/deg.def default route — ALWAYS shown regardless of other paths)
    if (defaultRoute.dev) {
        var isDefVerdict = (data.verdict === "default");
        var policyActive = !!activeDevs[defaultRoute.dev];
        // For "default" verdict, policy IS the active path; otherwise suppress if same dev seen
        var policyIsActive = (seen[defaultRoute.dev] && !isDefVerdict) ? false : policyActive;
        paths.push({ dev: defaultRoute.dev, via: defaultRoute.via, type: "policy", active: policyIsActive, mixed: isMixed && policyActive });
        // When policy is active on same dev, demote other paths to inactive
        if (policyIsActive && seen[defaultRoute.dev]) {
            for (var j = 0; j < paths.length; j++) {
                if (paths[j].dev === defaultRoute.dev && paths[j].type !== "policy") {
                    paths[j].active = false;
                }
            }
        }
    }

    return paths;
}

/**
 * Render route check diagram (network topology).
 * Layout: Client → DNS → Router → [N paths with globe icons] → Internet
 * All available WAN paths shown; active path highlighted.
 *
 * @param {HTMLElement} container - DOM element to render into
 * @param {Object} data - JSON response from /api/geo-split/route-check
 */
function renderRouteDiagram(container, data) {
    if (!data || data.ok === false) {
        _renderError(container, data || { error: "No data" });
        return;
    }

    var wrap = document.createElement("div");
    wrap.className = "route-diagram";

    // Build dynamic paths list
    var paths = _buildPaths(data);
    var pathCount = paths.length || 1;

    // Dynamic height: 55 per path (min 160, capped at 340)
    var H = Math.max(160, Math.min(340, 70 + pathCount * 55));
    var W = 780;
    var svg = _svgEl("svg", { viewBox: "0 0 " + W + " " + H, preserveAspectRatio: "xMidYMid meet" });

    // Fixed node positions (left-to-right)
    var midY = H / 2;
    var clientX = 50, clientY = midY;
    var dnsX = 160, dnsY = midY;
    var routerX = 290, routerY = midY;
    var pathNodeX = 440;
    var internetX = 580, internetY = midY;
    var serverX = 720, serverY = midY;

    // Calculate Y positions for each path (evenly distributed, centered around midY)
    var pathYs = [];
    var pathSpacing = Math.min(55, (H - 70) / pathCount);
    var pathBlockH = (pathCount - 1) * pathSpacing;
    var pathStartY = midY - pathBlockH / 2;
    for (var i = 0; i < pathCount; i++) {
        pathYs.push(pathStartY + i * pathSpacing);
    }

    // DNS state
    var dnsSkipped = !data.dns || data.dns === null;
    var dnsIps = (!dnsSkipped && data.dns.ips) ? data.dns.ips : [];
    var dnsTime = (!dnsSkipped && data.dns.time_ms) ? data.dns.time_ms + "ms" : "";

    // ── Draw connections ──

    // Client → DNS → Router (inactive when skipped, active when used)
    var pathClientDns = dnsSkipped ? "route-path--inactive" : "route-path--active";
    svg.appendChild(_svgLine(clientX + 16, clientY, dnsX - 16, dnsY, pathClientDns));
    svg.appendChild(_svgLine(dnsX + 16, dnsY, routerX - 18, routerY, pathClientDns));

    // Bypass path above DNS (active green, only when DNS skipped)
    if (dnsSkipped) {
        var bypassY = clientY - 30;
        svg.appendChild(_svgPolyline([
            [clientX + 16, clientY],
            [clientX + 40, bypassY],
            [routerX - 40, bypassY],
            [routerX - 18, routerY]
        ], "route-path--active"));
    }

    // Router → each path node → Internet
    for (var pi = 0; pi < pathCount; pi++) {
        var py = pathYs[pi];
        var isActive = paths[pi].active;
        var isMixedPath = paths[pi].mixed;
        var isPolicyPath = (paths[pi].type === "tunnel" || paths[pi].type === "policy") && isActive;
        var pathCls = isMixedPath ? "route-path--mixed" : (isPolicyPath ? "route-path--tunnel" : (isActive ? "route-path--active" : "route-path--inactive"));

        // Router → path node
        var routerExitY = routerY + ((py - routerY) * 0.15);
        svg.appendChild(_svgPolyline([
            [routerX + 18, routerExitY],
            [routerX + 50, py],
            [pathNodeX - 14, py]
        ], pathCls));

        // Path node → Internet → Server
        var internetEntryY = internetY + ((py - internetY) * 0.3);
        svg.appendChild(_svgPolyline([
            [pathNodeX + 14, py],
            [internetX - 40, py],
            [internetX - 18, internetEntryY]
        ], pathCls));
    }

    // ── Draw icons ──

    // Client — show client name (from --from MAC), "Router" when local, or generic "Client".
    // Truncate long names to fit SVG node width (~18 chars max).
    svg.appendChild(_iconClient(clientX, clientY, ""));
    var clientLabel = data.from_name || (data.source_iface ? "Client" : "Router");
    if (clientLabel.length > 18) clientLabel = clientLabel.substring(0, 16) + "\u2026";
    // Source sublabel: interface label when iif is set, empty when Router
    var sourceSublabel = data.source_iface
        ? _ifaceLabel(data.source_iface)
        : "";
    svg.appendChild(_svgText(clientLabel, clientX, clientY + 26, "route-node-label"));
    if (sourceSublabel) {
        svg.appendChild(_svgText(sourceSublabel, clientX, clientY + 38, "route-node-sublabel"));
    }

    // DNS
    var dnsIconClass = dnsSkipped ? " route-icon--skipped" : " route-icon--primary";
    svg.appendChild(_iconDns(dnsX, dnsY, dnsIconClass));
    if (dnsSkipped) {
        svg.appendChild(_svgText("skipped", dnsX, dnsY + 28, "route-node-sublabel"));
    } else {
        // Show up to 3 IPs, then "+N more"
        var dnsLabelY = dnsY + 28;
        var dnsShown = Math.min(dnsIps.length, 3);
        for (var di = 0; di < dnsShown; di++) {
            svg.appendChild(_svgText(dnsIps[di], dnsX, dnsLabelY, "route-node-sublabel"));
            dnsLabelY += 11;
        }
        if (dnsIps.length > 3) {
            svg.appendChild(_svgText("+" + (dnsIps.length - 3) + " more", dnsX, dnsLabelY, "route-node-sublabel"));
        }
    }

    // Router
    svg.appendChild(_iconRouter(routerX, routerY, ""));
    svg.appendChild(_svgText("Router", routerX, routerY + 26, "route-node-label"));

    // Path nodes (globe for ISP, shield for tunnel, signpost for policy)
    // Icons use fixed type-based color (not highlighted on active — only paths animate)
    for (var pi2 = 0; pi2 < pathCount; pi2++) {
        var py2 = pathYs[pi2];
        var p = paths[pi2];
        var iconClass = (p.type === "tunnel") ? " route-icon--tunnel" : "";

        if (p.type === "tunnel") {
            svg.appendChild(_iconShield(pathNodeX, py2, iconClass));
        } else if (p.type === "policy") {
            svg.appendChild(_iconSignpost(pathNodeX, py2, ""));
        } else {
            svg.appendChild(_iconGlobe(pathNodeX, py2, iconClass));
        }
        var pathLabel = (p.type === "policy") ? "Policy" : _ifaceLabel(p.dev);
        svg.appendChild(_svgText(pathLabel, pathNodeX, py2 + 27, "route-node-sublabel"));
        if (p.via) {
            svg.appendChild(_svgText("via " + p.via, pathNodeX, py2 + 39, "route-node-sublabel"));
        }
    }

    // Internet cloud
    svg.appendChild(_iconCloud(internetX, internetY, ""));
    svg.appendChild(_svgText("Internet", internetX, internetY + 22, "route-node-label"));

    // Internet → Server connection (always active — traffic reaches destination)
    svg.appendChild(_svgLine(internetX + 20, internetY, serverX - 12, serverY, "route-path--active"));

    // Server (destination)
    svg.appendChild(_iconServer(serverX, serverY, ""));
    var destLabel = data.query || "";
    svg.appendChild(_svgText(destLabel, serverX, serverY + 27, "route-node-label"));

    wrap.appendChild(svg);
    container.innerHTML = "";
    container.appendChild(wrap);
}

// ── Tool 2: DNS Diagram (horizontal flow) ────────────────────────────────────

/**
 * Render DNS check diagram (horizontal flow).
 * Layout: Domain → Zone Match → Upstream → Result
 *
 * @param {HTMLElement} container - DOM element to render into
 * @param {Object} data - JSON response from /api/smartdns/dns-check
 */
function renderDnsDiagram(container, data) {
    if (!data || data.ok === false) {
        _renderError(container, data || { error: "No data" });
        return;
    }

    var wrap = document.createElement("div");
    wrap.className = "route-diagram";

    var W = 700, H = 140;
    var svg = _svgEl("svg", { viewBox: "0 0 " + W + " " + H, preserveAspectRatio: "xMidYMid meet" });

    // Node positions (evenly spaced)
    var y = 55;
    var domainX = 90;
    var zoneX = 270;
    var upstreamX = 450;
    var resultX = 620;

    // ── Draw connections (blue flow) ──
    svg.appendChild(_svgLine(domainX + 16, y, zoneX - 16, y, "route-path--dns"));
    svg.appendChild(_svgLine(zoneX + 16, y, upstreamX - 16, y, "route-path--dns"));
    svg.appendChild(_svgLine(upstreamX + 16, y, resultX - 16, y, "route-path--dns"));

    // ── Draw icons and labels ──

    // Domain node
    svg.appendChild(_iconDns(domainX, y, " route-icon--primary"));
    svg.appendChild(_svgText("Domain", domainX, y + 26, "route-node-label"));
    svg.appendChild(_svgText(data.query || "", domainX, y + 38, "route-node-sublabel"));

    // Zone node
    var zone = data.zone || {};
    svg.appendChild(_iconZone(zoneX, y, " route-icon--primary"));
    svg.appendChild(_svgText("Zone", zoneX, y + 26, "route-node-label"));
    svg.appendChild(_svgText(zone.group || "—", zoneX, y + 38, "route-node-sublabel"));
    if (zone.match_rule) {
        svg.appendChild(_svgText(zone.match_rule, zoneX, y + 50, "route-node-sublabel"));
    }
    if (zone.match_type) {
        svg.appendChild(_svgText(zone.match_type, zoneX, y + 62, "route-node-sublabel"));
    }

    // Upstream node
    var upstream = data.upstream || {};
    svg.appendChild(_iconInterface(upstreamX, y, " route-icon--primary"));
    svg.appendChild(_svgText("Upstream", upstreamX, y + 26, "route-node-label"));
    var providers = (upstream.providers || []).join(", ");
    svg.appendChild(_svgText(providers || "—", upstreamX, y + 38, "route-node-sublabel"));
    var servers = (upstream.servers || []);
    if (servers.length > 0) {
        svg.appendChild(_svgText(servers[0], upstreamX, y + 50, "route-node-sublabel"));
    }
    if (upstream.interface) {
        svg.appendChild(_svgText(_ifaceLabel(upstream.interface), upstreamX, y + 62, "route-node-sublabel"));
    }

    // Result node
    var result = data.result || {};
    svg.appendChild(_iconResult(resultX, y, " route-icon--primary"));
    svg.appendChild(_svgText("Result", resultX, y + 26, "route-node-label"));
    var ips = (result.ips || []);
    if (ips.length > 0) {
        svg.appendChild(_svgText(ips[0], resultX, y + 38, "route-node-sublabel"));
        if (ips.length > 1) {
            svg.appendChild(_svgText("+" + (ips.length - 1) + " more", resultX, y + 50, "route-node-sublabel"));
        }
    }
    var meta = [];
    if (result.ttl !== undefined) { meta.push("TTL " + result.ttl); }
    if (result.time_ms !== undefined) { meta.push(result.time_ms + "ms"); }
    if (meta.length > 0) {
        var metaY = (ips.length > 1) ? y + 62 : y + 50;
        svg.appendChild(_svgText(meta.join(" | "), resultX, metaY, "route-node-sublabel"));
    }

    // ── Query title (top) ──
    if (data.query) {
        svg.appendChild(_svgText("DNS: " + data.query, W / 2, 16, "route-node-label"));
    }

    wrap.appendChild(svg);
    container.innerHTML = "";
    container.appendChild(wrap);
}
