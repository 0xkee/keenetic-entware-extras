// route-diagram.js — SVG diagram renderer for Route Check and DNS Check.
// Vanilla JS (ES5), no dependencies. Uses inline SVG via createElementNS.
// Public API: renderRouteDiagram(container, data), renderDnsDiagram(container, data)

"use strict";

var SVG_NS = "http://www.w3.org/2000/svg";

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

// ── Icon definitions (SVG <defs> + <use> for lightweight reuse) ───────────────
// Icons are defined once at origin (0,0) in <defs>; _useIcon() places them
// via <use> + translate(cx,cy).  This avoids recreating 3-8 SVG child nodes
// per icon instance, cutting DOM node count by ~60% per diagram.

/**
 * Add reusable icon definitions to an SVG element.
 * Each icon is drawn centered at (0,0); callers position via _useIcon().
 * @param {SVGElement} svg - target SVG element
 */
function _addIconDefs(svg) {
    var defs = _svgEl("defs", {});
    var g, txt;

    // Client — monitor with stand
    g = _svgEl("g", { id: "ico-client" });
    g.appendChild(_svgEl("rect", { x: -12, y: -10, width: 24, height: 16, rx: 2 }));
    g.appendChild(_svgEl("line", { x1: 0, y1: 6, x2: 0, y2: 10 }));
    g.appendChild(_svgEl("line", { x1: -6, y1: 10, x2: 6, y2: 10 }));
    defs.appendChild(g);

    // Router — box with antennas + LED dots
    g = _svgEl("g", { id: "ico-router" });
    g.appendChild(_svgEl("rect", { x: -14, y: -4, width: 28, height: 14, rx: 3 }));
    g.appendChild(_svgEl("line", { x1: -7, y1: -4, x2: -9, y2: -14 }));
    g.appendChild(_svgEl("line", { x1: 0, y1: -4, x2: 0, y2: -16 }));
    g.appendChild(_svgEl("line", { x1: 7, y1: -4, x2: 9, y2: -14 }));
    g.appendChild(_svgEl("circle", { cx: -5, cy: 3, r: 1.5 }));
    g.appendChild(_svgEl("circle", { cx: 0, cy: 3, r: 1.5 }));
    g.appendChild(_svgEl("circle", { cx: 5, cy: 3, r: 1.5 }));
    defs.appendChild(g);

    // Cloud (Internet) — cumulus shape
    g = _svgEl("g", { id: "ico-cloud" });
    g.appendChild(_svgEl("path", {
        d: "M-12,7 L12,7 C16,7 18,4 18,1 C18,-3 15,-6 11,-6" +
           " C10,-10 6,-12 2,-12 C-3,-12 -7,-10 -9,-7" +
           " C-13,-7 -17,-4 -17,0 C-17,4 -14,7 -12,7 Z"
    }));
    defs.appendChild(g);

    // DNS — circle with "DNS" text
    g = _svgEl("g", { id: "ico-dns" });
    g.appendChild(_svgEl("circle", { cx: 0, cy: 0, r: 13 }));
    txt = _svgEl("text", {
        x: 0, y: 3.5,
        "text-anchor": "middle",
        "font-size": "7",
        "font-weight": "600",
        fill: "currentColor",
        "class": "route-node-label"
    });
    txt.textContent = "DNS";
    g.appendChild(txt);
    defs.appendChild(g);

    // Query — magnifying glass
    g = _svgEl("g", { id: "ico-query" });
    g.appendChild(_svgEl("circle", { cx: -2, cy: -2, r: 9 }));
    g.appendChild(_svgEl("line", { x1: 5, y1: 5, x2: 11, y2: 11 }));
    defs.appendChild(g);

    // Globe — circle with meridians (ISP/provider)
    g = _svgEl("g", { id: "ico-globe" });
    g.appendChild(_svgEl("circle", { cx: 0, cy: 0, r: 12 }));
    g.appendChild(_svgEl("line", { x1: -12, y1: 0, x2: 12, y2: 0 }));
    g.appendChild(_svgEl("ellipse", { cx: 0, cy: 0, rx: 5, ry: 12 }));
    g.appendChild(_svgEl("line", { x1: -10, y1: -5, x2: 10, y2: -5 }));
    g.appendChild(_svgEl("line", { x1: -10, y1: 5, x2: 10, y2: 5 }));
    defs.appendChild(g);

    // Shield — VPN/tunnel lock
    g = _svgEl("g", { id: "ico-shield" });
    g.appendChild(_svgEl("path", {
        d: "M0,-12 L10,-7 L10,2 Q10,8 0,12 Q-10,8 -10,2 L-10,-7 Z"
    }));
    g.appendChild(_svgEl("circle", { cx: 0, cy: -2, r: 3 }));
    g.appendChild(_svgEl("line", { x1: 0, y1: 1, x2: 0, y2: 5 }));
    defs.appendChild(g);

    // Signpost — policy routing (two directional arrows on a pole)
    g = _svgEl("g", { id: "ico-signpost" });
    g.appendChild(_svgEl("line", { x1: 0, y1: -12, x2: 0, y2: 12 }));
    g.appendChild(_svgEl("path", { d: "M-8,-11 L5,-11 L9,-8 L5,-5 L-8,-5 Z" }));
    g.appendChild(_svgEl("path", { d: "M8,1 L-5,1 L-9,4 L-5,7 L8,7 Z" }));
    defs.appendChild(g);

    // Zone — filter/funnel
    g = _svgEl("g", { id: "ico-zone" });
    g.appendChild(_svgEl("path", {
        d: "M-10,-8 L10,-8 L4,2 L4,8 L-4,8 L-4,2 Z"
    }));
    defs.appendChild(g);

    // Result — clipboard with lines
    g = _svgEl("g", { id: "ico-result" });
    g.appendChild(_svgEl("rect", { x: -9, y: -10, width: 18, height: 22, rx: 2 }));
    g.appendChild(_svgEl("rect", { x: -4, y: -13, width: 8, height: 5, rx: 1 }));
    g.appendChild(_svgEl("line", { x1: -5, y1: -3, x2: 5, y2: -3 }));
    g.appendChild(_svgEl("line", { x1: -5, y1: 1, x2: 5, y2: 1 }));
    g.appendChild(_svgEl("line", { x1: -5, y1: 5, x2: 3, y2: 5 }));
    defs.appendChild(g);

    // Server — rack with sections + LED dots
    g = _svgEl("g", { id: "ico-server" });
    g.appendChild(_svgEl("rect", { x: -10, y: -12, width: 20, height: 24, rx: 2 }));
    g.appendChild(_svgEl("line", { x1: -10, y1: -4, x2: 10, y2: -4 }));
    g.appendChild(_svgEl("line", { x1: -10, y1: 4, x2: 10, y2: 4 }));
    g.appendChild(_svgEl("circle", { cx: -6, cy: -8, r: 1.5 }));
    g.appendChild(_svgEl("circle", { cx: -6, cy: 0, r: 1.5 }));
    g.appendChild(_svgEl("circle", { cx: -6, cy: 8, r: 1.5 }));
    defs.appendChild(g);

    svg.appendChild(defs);
}

/**
 * Place a pre-defined icon from <defs> via <use>.
 * @param {string} id - icon def id (e.g. "ico-client")
 * @param {number} cx - center x
 * @param {number} cy - center y
 * @param {string} [extraClass] - additional CSS class
 * @returns {SVGGElement}
 */
function _useIcon(id, cx, cy, extraClass) {
    var g = _svgEl("g", {
        "class": "route-icon" + (extraClass ? " " + extraClass : ""),
        transform: "translate(" + cx + "," + cy + ")"
    });
    g.appendChild(_svgEl("use", { href: "#" + id }));
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
    title.textContent = "⚠ Diagnostic error";
    div.appendChild(title);
    var msg = document.createElement("div");
    msg.className = "route-diagram__error-msg";
    msg.textContent = data.error || data.message || "Unknown error";
    div.appendChild(msg);
    container.innerHTML = "";
    container.appendChild(div);
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
    // CIDR mixed: also activate devs from coverage overlaps + default route
    if (isMixed && data.input_type === "cidr") {
        if (defaultRoute.dev) activeDevs[defaultRoute.dev] = true;
        if (data.coverage && data.coverage.overlaps) {
            for (var oi = 0; oi < data.coverage.overlaps.length; oi++) {
                var oDev = data.coverage.overlaps[oi].dev;
                if (oDev) activeDevs[oDev] = true;
            }
        }
    }

    // If backend provides all_paths — use directly (two-icon model: globe + shield)
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
        return paths;
    }

    // Fallback: derive paths from legacy fields (two-icon model: globe + shield)
    var paths = [];
    var seen = {};

    // ISP/default path — globe, always present when non-tunnel default route exists
    if (defaultRoute.dev && !EW.isTunnelIface(defaultRoute.dev)) {
        var ispActive = !!activeDevs[defaultRoute.dev];
        paths.push({ dev: defaultRoute.dev, via: defaultRoute.via || "", type: "isp", active: ispActive, mixed: isMixed && ispActive });
        seen[defaultRoute.dev] = true;
    }

    // VPN/tunnel path — shield (client's VPN policy fwmark → policy table default route)
    var vpnDev = tunnelRoute.dev || "";
    if (vpnDev && !seen[vpnDev]) {
        paths.push({ dev: vpnDev, via: "", type: "tunnel", active: !!activeDevs[vpnDev], mixed: isMixed && !!activeDevs[vpnDev] });
        seen[vpnDev] = true;
    }

    // Geo-split through tunnel (ROUTE_OUT→tunnel): add as tunnel if not yet seen
    if (data.verdict === "geo-split" && activeRoute && EW.isTunnelIface(activeRoute.dev) && !seen[activeRoute.dev]) {
        paths.push({ dev: activeRoute.dev, via: activeRoute.via || "", type: "tunnel", active: true, mixed: false });
        seen[activeRoute.dev] = true;
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
    _addIconDefs(svg);

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
        var isGeoVerdict = data.verdict === "geo-split";
        // Green only for geo-split active paths; all other active paths are blue
        var isBlue = !isGeoVerdict && isActive;
        var pathCls = isMixedPath ? "route-path--mixed" : (isBlue ? "route-path--tunnel" : (isActive ? "route-path--active" : "route-path--inactive"));

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
    svg.appendChild(_useIcon("ico-client", clientX, clientY, ""));
    var clientLabel = data.from_name || (data.source_iface ? "Client" : "Router");
    if (clientLabel.length > 18) clientLabel = clientLabel.substring(0, 16) + "\u2026";
    // Source sublabel: interface label when iif is set, empty when Router
    var sourceSublabel = data.source_iface
        ? EW.ifaceLabelShort(data.source_iface)
        : "";
    svg.appendChild(_svgText(clientLabel, clientX, clientY + 26, "route-node-label"));
    if (sourceSublabel) {
        svg.appendChild(_svgText(sourceSublabel, clientX, clientY + 38, "route-node-sublabel"));
    }

    // DNS
    var dnsIconClass = dnsSkipped ? " route-icon--skipped" : " route-icon--primary";
    svg.appendChild(_useIcon("ico-dns", dnsX, dnsY, dnsIconClass));
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
    svg.appendChild(_useIcon("ico-router", routerX, routerY, ""));
    svg.appendChild(_svgText("Router", routerX, routerY + 26, "route-node-label"));

    // Path nodes — two-icon model: globe (ISP/default) + shield (tunnel)
    // Globe icon always gray; shield icon always blue. Path lines carry the color.
    for (var pi2 = 0; pi2 < pathCount; pi2++) {
        var py2 = pathYs[pi2];
        var p = paths[pi2];

        if (p.type === "tunnel") {
            svg.appendChild(_useIcon("ico-shield", pathNodeX, py2, " route-icon--tunnel"));
        } else {
            svg.appendChild(_useIcon("ico-globe", pathNodeX, py2, ""));
        }
        svg.appendChild(_svgText(EW.ifaceLabelShort(p.dev), pathNodeX, py2 + 27, "route-node-sublabel"));
    }

    // Internet cloud
    svg.appendChild(_useIcon("ico-cloud", internetX, internetY, ""));
    svg.appendChild(_svgText("Internet", internetX, internetY + 22, "route-node-label"));

    // Internet → Server connection (always active — traffic reaches destination)
    svg.appendChild(_svgLine(internetX + 20, internetY, serverX - 12, serverY, "route-path--active"));

    // Server (destination)
    svg.appendChild(_useIcon("ico-server", serverX, serverY, ""));
    var destLabel = data.query || "";
    svg.appendChild(_svgText(destLabel, serverX, serverY + 27, "route-node-label"));

    wrap.appendChild(svg);
    container.innerHTML = "";
    container.appendChild(wrap);
}

// ── Tool 2: DNS Diagram (topology, mirrors Route Diagram layout) ─────────────

/**
 * Build the list of DNS group branches for the diagram.
 * Uses data.groups if available (new backend) — ALWAYS both configured
 * groups ("zone" and "default"), regardless of which one matched the
 * current query. This mirrors Route Diagram's all_paths: every configured
 * path is always shown, with the active one highlighted.
 * Falls back to a single synthetic branch from legacy data.zone/data.upstream
 * fields when the backend hasn't been updated yet.
 * @param {Object} data - API response
 * @returns {Array<Object>} [{ label, providers, matched }]
 */
function _buildDnsGroups(data) {
    if (data.groups && data.groups.length > 0) {
        var out = [];
        for (var i = 0; i < data.groups.length; i++) {
            var g = data.groups[i];
            out.push({
                label: g.label || g.group || "\u2014",
                providers: g.providers || [],
                hostnames: g.hostnames || [],
                matched: !!g.matched
            });
        }
        return out;
    }
    // Legacy fallback: single branch from the matched-only fields
    var zone = data.zone || {};
    var upstream = data.upstream || {};
    return [{
        label: zone.group || "default",
        providers: upstream.providers || [],
        hostnames: upstream.hostnames || [],
        matched: true
    }];
}

/**
 * Render DNS check diagram (topology).
 * Layout: Domain → Zone → [DNS group branches] → Result.
 * Every configured DNS group (zone-specific + default) is always rendered
 * as a branch, analogous to the WAN path branches in renderRouteDiagram().
 * Path coloring mirrors Route Diagram: the segment leading into the branch
 * point is always active (green); the matched group's branch stays green
 * through the fan-out and fan-in, while non-matched groups render blue.
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

    var zone = data.zone || {};
    var result = data.result || {};
    var branches = _buildDnsGroups(data);
    var branchCount = branches.length;

    // Dynamic height: identical formula to renderRouteDiagram (min 160, capped at
    // 340, 55px/branch) — full unification of the vertical fan-out spacing so
    // multi-branch nodes get the same breathing room as Route Check's WAN paths
    // and never overlap each other.
    var H = Math.max(160, Math.min(340, 70 + branchCount * 55));
    var W = 780;
    var svg = _svgEl("svg", { viewBox: "0 0 " + W + " " + H, preserveAspectRatio: "xMidYMid meet" });
    _addIconDefs(svg);

    // Fixed node positions — reuse Route Diagram's X coordinates for visual parity
    var midY = H / 2;
    var domainX = 50, domainY = midY;
    var zoneX = 290, zoneY = midY;
    var branchX = 505;   // centered between zone and result (like Route Diagram)
    var resultX = 720, resultY = midY;

    // Branch Y positions (evenly distributed, centered around midY) — same
    // spacing formula as renderRouteDiagram's pathYs.
    var branchYs = [];
    var branchSpacing = Math.min(55, (H - 70) / branchCount);
    var branchBlockH = (branchCount - 1) * branchSpacing;
    var branchStartY = midY - branchBlockH / 2;
    for (var i = 0; i < branchCount; i++) {
        branchYs.push(branchStartY + i * branchSpacing);
    }

    // ── Draw connections ──

    // Domain → Zone — always the active/green lead-in segment, regardless
    // of which group ends up matching (same as Route's Client→Router hops).
    svg.appendChild(_svgLine(domainX + 16, domainY, zoneX - 18, zoneY, "route-path--active"));

    // Zone → each branch → Result. Coloring mirrors Route Diagram verdicts:
    // - matched zone-specific group → green (route-path--active), like geo-split
    // - matched default group → blue (route-path--tunnel), like policy/tunnel
    // - non-matched → gray (route-path--inactive)
    for (var pi = 0; pi < branchCount; pi++) {
        var py = branchYs[pi];
        var isDefault = !branches[pi].label || branches[pi].label.toLowerCase() === "default";
        var branchCls = branches[pi].matched
            ? (isDefault ? "route-path--tunnel" : "route-path--active")
            : "route-path--inactive";

        var zoneExitY = zoneY + ((py - zoneY) * 0.15);
        svg.appendChild(_svgPolyline([
            [zoneX + 18, zoneExitY],
            [zoneX + 50, py],
            [branchX - 14, py]
        ], branchCls));

        var resultEntryY = resultY + ((py - resultY) * 0.3);
        svg.appendChild(_svgPolyline([
            [branchX + 14, py],
            [resultX - 40, py],
            [resultX - 18, resultEntryY]
        ], branchCls));
    }

    // ── Draw icons ──

    // Domain (query) node — magnifying glass, distinct from the DNS-server icon
    // used below. Gray (neutral), same as Route Diagram's Client icon.
    svg.appendChild(_useIcon("ico-query", domainX, domainY, ""));
    svg.appendChild(_svgText("Domain", domainX, domainY + 26, "route-node-label"));
    svg.appendChild(_svgText(data.query || "", domainX, domainY + 38, "route-node-sublabel"));

    // Zone node — gray (neutral), same as Route Diagram's Router icon.
    svg.appendChild(_useIcon("ico-zone", zoneX, zoneY, ""));
    svg.appendChild(_svgText("Zone", zoneX, zoneY + 26, "route-node-label"));
    svg.appendChild(_svgText(zone.group || "default", zoneX, zoneY + 38, "route-node-sublabel"));

    // DNS group branch nodes — one node per configured group (zone/default),
    // NOT one per individual provider. Providers are listed as text under the node.
    // Icon color follows MATCH STATE: the matched (active) group gets a blue icon
    // (route-icon--primary), non-matched groups stay neutral gray — mirroring
    // Route Diagram where the active WAN path icon is highlighted.
    for (var bi = 0; bi < branchCount; bi++) {
        var by = branchYs[bi];
        var b = branches[bi];
        var branchIconCls = b.matched ? " route-icon--primary" : "";
        svg.appendChild(_useIcon("ico-dns", branchX, by, branchIconCls));
        svg.appendChild(_svgText(b.label, branchX, by + 27, "route-node-sublabel"));
        var provText = b.providers.join(", ");
        if (provText) {
            svg.appendChild(_svgText(provText, branchX, by + 39, "route-node-sublabel"));
        }
    }

    // Result node — gray (neutral), same as Route Diagram's Server icon.
    svg.appendChild(_useIcon("ico-result", resultX, resultY, ""));
    svg.appendChild(_svgText("Result", resultX, resultY + 26, "route-node-label"));
    var ips = (result.ips || []);
    if (ips.length > 0) {
        svg.appendChild(_svgText(ips[0], resultX, resultY + 38, "route-node-sublabel"));
        if (ips.length > 1) {
            svg.appendChild(_svgText("+" + (ips.length - 1) + " more", resultX, resultY + 50, "route-node-sublabel"));
        }
    }
    var meta = [];
    if (result.ttl !== undefined) { meta.push("TTL " + result.ttl); }
    if (result.time_ms !== undefined) { meta.push(result.time_ms + "ms"); }
    if (meta.length > 0) {
        var metaY = (ips.length > 1) ? resultY + 62 : resultY + 50;
        svg.appendChild(_svgText(meta.join(" | "), resultX, metaY, "route-node-sublabel"));
    }

    wrap.appendChild(svg);
    container.innerHTML = "";
    container.appendChild(wrap);
}
