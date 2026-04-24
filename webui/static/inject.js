// inject.js — Keenetic NDMS WebUI sidebar + dashboard integration for Entware extras.
// Injected via nginx sub_filter into every proxied Keenetic page.
// Uses stock Keenetic DOM classes (dashboard-card, ndw-status, ndw-router-link).
(function() {
    'use strict';

    // ── Card ID for RCI ndw4_settings integration ────────────────────────────
    var ENTWARE_CARD_ID = 'ENTWARE_EXTRAS';

    // ── XHR interceptor — re-inject ENTWARE_EXTRAS into ndw4_settings on save ─
    // Angular uses XMLHttpRequest (not fetch) for RCI API.  When user saves
    // via Cards Position dialog, Angular strips unknown card IDs.  This
    // monkey-patch intercepts the outgoing request and re-inserts our card.
    var _origXhrSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function(body) {
        if (body && typeof body === 'string' && body.indexOf('ndw4_settings') !== -1) {
            try {
                var parsed = JSON.parse(body);
                for (var i = 0; i < parsed.length; i++) {
                    var cmd = parsed[i];
                    if (cmd && cmd.system && cmd.system.environment && cmd.system.environment.set &&
                        cmd.system.environment.set.name === 'ndw4_settings') {
                        var ndw4 = JSON.parse(cmd.system.environment.set.value);
                        var cfg = ndw4.dashboardCardsConfiguration;
                        if (cfg && [].concat.apply([], cfg.desktop).indexOf(ENTWARE_CARD_ID) === -1) {
                            var pos = getEntwareCardPosition();
                            var col = pos ? pos.column : 0;
                            var idx = pos ? pos.position : cfg.desktop[col].length;
                            if (col >= cfg.desktop.length) col = 0;
                            if (idx > cfg.desktop[col].length) idx = cfg.desktop[col].length;
                            cfg.desktop[col].splice(idx, 0, ENTWARE_CARD_ID);
                            if (cfg.mobile && cfg.mobile[0] &&
                                cfg.mobile[0].indexOf(ENTWARE_CARD_ID) === -1) {
                                cfg.mobile[0].push(ENTWARE_CARD_ID);
                            }
                            cfg.cardStates[ENTWARE_CARD_ID] = pos ? pos.visible !== false : true;
                            cmd.system.environment.set.value = JSON.stringify(ndw4);
                            body = JSON.stringify(parsed);
                        }
                    }
                }
            } catch(e) { /* don't break Angular */ }
        }
        return _origXhrSend.call(this, body);
    };

    var CUSTOM_ITEMS = [
        { id: 'dashboard',          label: 'Dashboard',    url: '/custom/' },
        { id: 'geo-split',          label: 'Geo Split',    url: '/custom/#geo-split' },
        { id: 'smartdns',           label: 'SmartDNS',     url: '/custom/#smartdns' },
        { id: 'smartdns-redirect',  label: 'DNS Redirect', url: '/custom/#smartdns-redirect' },
        { id: 'webui',              label: 'WebUI',        url: '/custom/#webui' },
    ];

    var SERVICE_APIS = [
        { id: 'geo-split',         label: 'Geo-Split',    desc: 'Policy-based geographic split routing',     url: '/custom/#geo-split',         api: '/api/geo-split/status' },
        { id: 'smartdns',          label: 'SmartDNS',     desc: 'DNS resolver with geographic routing rules', url: '/custom/#smartdns',           api: '/api/smartdns/status' },
        { id: 'smartdns-redirect', label: 'DNS Redirect', desc: 'Transparent DNS redirect for local networks', url: '/custom/#smartdns-redirect',  api: '/api/smartdns-redirect/status' },
        { id: 'webui',             label: 'WebUI',        desc: 'Entware Extras web dashboard',               url: '/custom/#webui',              api: '/api/webui/status' },
    ];

    var DASH_POLL_INTERVAL = 30000;
    var DETAILS_SKIP_KEYS = { uptime: 1, version: 1, pid: 1, background: 1 };
    /** Detail keys whose numeric values are seconds — formatted via formatUptimeStock() and live-ticked. */
    var TIMER_KEYS = { subnet_freshness: 1, domain_freshness: 1 };

    var injected = false;
    var dashboardInjected = false;
    var dashboardPending = false;  // guard against multiple setTimeout queues
    var activeItem = null;
    var insertingIframe = false;
    var dashboardTimer = null;
    var geoFastPollTimer = null;
    var GEO_FAST_POLL = 1000;  // 1s when background update is running
    var uptimeBaselines = {};  // { 'geo-split': { seconds: 12345, timestamp: Date.now() }, ... }
    var freshnessBaselines = {};  // { 'subnet_freshness': {seconds, timestamp}, 'domain_freshness': ... }
    var uptimeTickTimer = null;

    // ── RCI card position tracking ───────────────────────────────────────────
    // Card position is stored in RCI env variable "entware_extras_dashboard"
    // as JSON: { column: 0, position: 2, visible: true }
    var _entwareCardPos = null;
    var _entwareCardPosRead = false;

    /** @returns {{column:number, position:number, visible:boolean}|null} */
    function getEntwareCardPosition() { return _entwareCardPos; }

    /**
     * Read card position from RCI env variables.
     * Also triggers first-run registration in ndw4_settings if needed.
     * @param {function} callback - called with position or null
     */
    function readEntwarePosition(callback) {
        _entwareCardPosRead = true;
        var xhr = new XMLHttpRequest();
        xhr.open('POST', '/rci/', true);
        xhr.setRequestHeader('Content-Type', 'application/json');
        xhr.onload = function() {
            try {
                var resp = JSON.parse(xhr.responseText);
                var env = resp[0] && resp[0].show && resp[0].show.environment;
                if (env) {
                    if (env.entware_extras_dashboard) {
                        _entwareCardPos = JSON.parse(env.entware_extras_dashboard);
                    }
                    // First-run: register in ndw4_settings if not present
                    if (env.ndw4_settings) {
                        registerEntwareCard(env.ndw4_settings);
                    }
                }
            } catch(e) {}
            callback(_entwareCardPos);
        };
        xhr.onerror = function() { callback(null); };
        xhr.send(JSON.stringify([{"show":{"environment":{}}}]));
    }

    /**
     * Persist card position to RCI env variable.
     * @param {{column:number, position:number, visible:boolean}} pos
     */
    function saveEntwarePosition(pos) {
        _entwareCardPos = pos;
        var xhr = new XMLHttpRequest();
        xhr.open('POST', '/rci/', true);
        xhr.setRequestHeader('Content-Type', 'application/json');
        xhr.send(JSON.stringify([{"system":{"environment":{"set":{
            "name": "entware_extras_dashboard",
            "value": JSON.stringify(pos)
        }}}}]));
    }

    /**
     * First-run: add ENTWARE_EXTRAS to ndw4_settings if not yet present.
     * @param {string} ndw4settings - raw JSON string from RCI env
     */
    function registerEntwareCard(ndw4settings) {
        try {
            var ndw4 = JSON.parse(ndw4settings);
            var cfg = ndw4.dashboardCardsConfiguration;
            if (!cfg || !cfg.desktop) return;
            if ([].concat.apply([], cfg.desktop).indexOf(ENTWARE_CARD_ID) !== -1) return;
            cfg.desktop[0].push(ENTWARE_CARD_ID);
            if (cfg.mobile && cfg.mobile[0]) {
                cfg.mobile[0].push(ENTWARE_CARD_ID);
            }
            cfg.cardStates[ENTWARE_CARD_ID] = true;
            var xhr = new XMLHttpRequest();
            xhr.open('POST', '/rci/', true);
            xhr.setRequestHeader('Content-Type', 'application/json');
            xhr.send(JSON.stringify([{"system":{"environment":{"set":{
                "name": "ndw4_settings",
                "value": JSON.stringify(ndw4)
            }}}}]));
            if (!_entwareCardPos) {
                saveEntwarePosition({ column: 0, position: cfg.desktop[0].length - 1, visible: true });
            }
        } catch(e) {}
    }

    // ── Cards Position dialog integration ────────────────────────────────────

    /**
     * Watch for Cards Position dialog opening via CDK overlay container.
     * Injects ENTWARE EXTRAS row with show/hide toggle into the dialog.
     */
    var _cardsDialogObserverSet = false;
    function setupCardsPositionDialog() {
        if (_cardsDialogObserverSet) return;
        _cardsDialogObserverSet = true;
        var container = document.querySelector('.cdk-overlay-container') || document.body;
        new MutationObserver(function(mutations) {
            for (var mi = 0; mi < mutations.length; mi++) {
                var added = mutations[mi].addedNodes;
                for (var ni = 0; ni < added.length; ni++) {
                    var node = added[ni];
                    if (node.nodeType !== 1) continue;
                    // Angular renders dialog content async — the overlay pane
                    // is added first, column-wrapper comes in a later tick.
                    // Detect any node added inside .cdk-overlay-container and
                    // poll for the dialog column-wrapper inside overlay panes.
                    _tryInjectCardsDialog();
                    return; // one fire per batch is enough
                }
            }
        }).observe(container, { childList: true, subtree: true });
    }

    var _cardsDialogPending = false;
    /** Poll overlay panes for Cards Position dialog and inject our row. */
    function _tryInjectCardsDialog() {
        if (_cardsDialogPending) return;
        _cardsDialogPending = true;
        var attempts = 0;
        var timer = setInterval(function() {
            attempts++;
            // Find dialog pane inside overlay (not the main dashboard)
            var panes = document.querySelectorAll('.cdk-overlay-pane');
            for (var i = 0; i < panes.length; i++) {
                var wrapper = panes[i].querySelector('.ndw-drag-panel__column-wrapper');
                if (wrapper && !wrapper.querySelector('.entware-dialog-row')) {
                    injectIntoCardsDialog(wrapper);
                    clearInterval(timer);
                    _cardsDialogPending = false;
                    return;
                }
            }
            if (attempts > 15) { // 3 seconds max
                clearInterval(timer);
                _cardsDialogPending = false;
            }
        }, 200);
    }

    /**
     * Inject ENTWARE EXTRAS row into the Cards Position dialog.
     * Reproduces stock DOM structure: ndw-dashboard-card stub + ndw-toggle.
     * @param {HTMLElement} dialogWrapper - .ndw-drag-panel__column-wrapper element
     */
    function injectIntoCardsDialog(dialogWrapper) {
        if (dialogWrapper.querySelector('.entware-dialog-row')) return;
        var pos = getEntwareCardPosition();
        var colIdx = pos ? pos.column : 0;
        var cols = dialogWrapper.querySelectorAll('.ndw-drag-panel__column');
        var col = cols[colIdx] || cols[0];
        if (!col) return;

        var isVisible = pos ? pos.visible !== false : true;

        var row = document.createElement('div');
        row.className = 'ndw-drag-panel__row entware-dialog-row' + (isVisible ? '' : ' entware-dialog-row--off');
        row.innerHTML = '<div>' +
            '<ndw-dashboard-card class="dashboard-card-stub">' +
              '<div class="dashboard-card">' +
                '<div class="dashboard-card__header">' +
                  '<div class="dashboard-card__header-text text-card-heading">ENTWARE EXTRAS</div>' +
                  '<div class="dashboard-card__header-buttons">' +
                    '<ndw-svg-icon class="ndw-drag-handle dashboard-card__drag-icon">' +
                      '<svg class="ndw-svg-icon svg-drag-and-drop-dims">' +
                        '<use href="./assets/sprite/sprite.svg#drag-and-drop"></use>' +
                    '</svg></ndw-svg-icon></div></div>' +
                '<div class="ew-dialog-toggle">' +
                  '<ndw-toggle><div class="ndw-toggle"><label class="ndw-toggle__wrapper">' +
                    '<div class="ndw-toggle__button" tabindex="0">' +
                      '<input type="checkbox" role="switch" tabindex="-1" class="ndw-toggle__checkbox entware-show-toggle"' +
                        ' aria-label="ENTWARE_EXTRAS"' + (isVisible ? ' checked' : '') + '>' +
                      '<div class="ndw-toggle__toggle-bar' + (isVisible ? ' ndw-toggle__toggle-bar--on' : '') + '">' +
                        '<div class="ndw-toggle__toggle-bar__thumb"></div></div></div>' +
                    '<div class="ndw-toggle__label-wrapper"><div class="ndw-toggle__label" role="status">Show card</div></div>' +
                  '</label></div></ndw-toggle></div>' +
              '</div>' +
            '</ndw-dashboard-card></div>';

        // Insert before hidden placeholder row if present
        var placeholder = col.querySelector('.ndw-drag-panel__row--hidden');
        if (placeholder) {
            col.insertBefore(row, placeholder);
        } else {
            col.appendChild(row);
        }

        // Enable HTML5 drag for our dialog row
        setupEntwareDrag(row, function(colIdx, posIdx) {
            var p = getEntwareCardPosition() || { column: 0, position: 0, visible: true };
            p.column = colIdx;
            p.position = posIdx;
            saveEntwarePosition(p);
        });

        // Toggle handler — show/hide card + persist via RCI
        var toggle = row.querySelector('.entware-show-toggle');
        if (toggle) {
            toggle.addEventListener('change', function(e) {
                var visible = e.target.checked;
                row.classList.toggle('entware-dialog-row--off', !visible);
                var barEl = row.querySelector('.ndw-toggle__toggle-bar');
                if (barEl) {
                    barEl.classList.toggle('ndw-toggle__toggle-bar--on', visible);
                    barEl.classList.toggle('ndw-toggle__toggle-bar--off', !visible);
                }
                var p = getEntwareCardPosition() || { column: 0, position: 999, visible: true };
                p.visible = visible;
                saveEntwarePosition(p);
                // Show/hide on live dashboard
                var wrapper = document.getElementById('entware-dashboard-wrapper');
                if (wrapper) {
                    wrapper.style.display = visible ? '' : 'none';
                }
            });
        }
    }

    // ── HTML5 drag-and-drop for our injected elements ────────────────────────

    /**
     * Enable HTML5 native drag on our row element within drag-panel columns.
     * Works for both dashboard wrapper and Cards Position dialog rows.
     * @param {HTMLElement} row - the draggable row (.ndw-drag-panel__row)
     * @param {function} [onDrop] - callback(colIdx, posIdx) after drop
     */
    function setupEntwareDrag(row, onDrop) {
        row.setAttribute('draggable', 'true');

        // Use drag handle as the visual cue (stock CDK pattern)
        var handle = row.querySelector('.ndw-drag-handle, .dashboard-card__drag-icon');
        if (handle) handle.style.cursor = 'grab';

        row.addEventListener('dragstart', function(e) {
            e.dataTransfer.setData('text/plain', 'entware-drag');
            e.dataTransfer.effectAllowed = 'move';
            row.classList.add('ew-dragging');
            // Store ref for cross-column drops
            window._ewDragRow = row;
        });

        row.addEventListener('dragend', function() {
            row.classList.remove('ew-dragging');
            // Clean up all drag-over indicators
            document.querySelectorAll('.ew-drag-over').forEach(function(el) {
                el.classList.remove('ew-drag-over');
            });
            window._ewDragRow = null;
        });

        // Set up drop zones on sibling columns
        var columnWrapper = row.closest('.ndw-drag-panel__column-wrapper');
        if (!columnWrapper) return;
        var columns = columnWrapper.querySelectorAll('.ndw-drag-panel__column');

        columns.forEach(function(col) {
            // Prevent duplicate listeners with a flag
            if (col._ewDropSetup) return;
            col._ewDropSetup = true;

            col.addEventListener('dragover', function(e) {
                if (!window._ewDragRow) return;
                e.preventDefault();
                e.dataTransfer.dropEffect = 'move';
                // Find closest row to show drop indicator
                var rows = col.querySelectorAll('.ndw-drag-panel__row:not(.ndw-drag-panel__row--hidden):not(.ew-dragging)');
                var closest = null;
                var closestDist = Infinity;
                for (var i = 0; i < rows.length; i++) {
                    var rect = rows[i].getBoundingClientRect();
                    var mid = rect.top + rect.height / 2;
                    var dist = Math.abs(e.clientY - mid);
                    if (dist < closestDist) { closestDist = dist; closest = rows[i]; }
                }
                // Remove old indicators
                col.querySelectorAll('.ew-drag-over').forEach(function(el) {
                    el.classList.remove('ew-drag-over');
                });
                if (closest) closest.classList.add('ew-drag-over');
            });

            col.addEventListener('dragleave', function() {
                col.querySelectorAll('.ew-drag-over').forEach(function(el) {
                    el.classList.remove('ew-drag-over');
                });
            });

            col.addEventListener('drop', function(e) {
                if (!window._ewDragRow) return;
                e.preventDefault();
                var dragRow = window._ewDragRow;
                // Find target position
                var target = col.querySelector('.ew-drag-over');
                col.querySelectorAll('.ew-drag-over').forEach(function(el) {
                    el.classList.remove('ew-drag-over');
                });

                if (target) {
                    var targetRect = target.getBoundingClientRect();
                    var above = e.clientY < targetRect.top + targetRect.height / 2;
                    if (above) {
                        col.insertBefore(dragRow, target);
                    } else {
                        col.insertBefore(dragRow, target.nextSibling);
                    }
                } else {
                    // Drop at end (before hidden placeholder)
                    var ph = col.querySelector('.ndw-drag-panel__row--hidden');
                    if (ph) { col.insertBefore(dragRow, ph); }
                    else { col.appendChild(dragRow); }
                }

                // Calculate new position
                var colIdx = Array.prototype.indexOf.call(columns, col);
                var visibleRows = col.querySelectorAll('.ndw-drag-panel__row:not(.ndw-drag-panel__row--hidden)');
                var posIdx = Array.prototype.indexOf.call(visibleRows, dragRow);
                if (onDrop && colIdx >= 0 && posIdx >= 0) {
                    onDrop(colIdx, posIdx);
                }
            });
        });
    }

    // ── Inject dashboard card CSS ────────────────────────────────────────────

    /** Inject minimal CSS for dashboard card layout (once). */
    function injectDashStyles() {
        if (document.getElementById('entware-dash-styles')) return;
        var style = document.createElement('style');
        style.id = 'entware-dash-styles';
        // Scoped via #entware-dashboard-card to avoid leaking into stock UI.
        // Stock Angular component CSS is scoped with [_ngcontent-*] attributes
        // and does NOT cascade to dynamically injected DOM — we provide our own.
        style.textContent =
            /* Card container — stock: flex column, no padding, background=--background */
            /* Wrapper — stock row gap: 24px between drag-panel rows */
            '#entware-dashboard-wrapper{margin-bottom:24px;}' +
            /* Card — stock ndw-dashboard-card host */
            '#entware-dashboard-card{' +
                'width:100%;position:relative;' +
                'word-break:break-word;' +
                'display:flex;flex-direction:column;' +
                'border:1px solid var(--dashboard-card-border,#4d545f);' +
                'border-radius:8px;' +
                'background:var(--background,#1b2434);' +
                'box-sizing:border-box;}' +
            /* Card header — matches stock: margin-top:24px, padding:0 8px 0 24px */
            '#entware-dashboard-card .dashboard-card__header{' +
                'display:flex;align-items:center;justify-content:space-between;' +
                'margin-top:24px;margin-bottom:16px;' +
                'padding:0 8px 0 24px;' +
                'color:var(--text-gray,#949b9f);}' +
            '#entware-dashboard-card .text-card-heading{' +
                'font-size:16px;font-weight:700;letter-spacing:1px;' +
                'text-transform:uppercase;color:var(--primary-text,#c2c2c2);' +
                'text-decoration:none;cursor:pointer;line-height:1.2;}' +
            '#entware-dashboard-card .text-card-heading:hover{' +
                'text-decoration:underline;}' +
            '#entware-dashboard-card .dashboard-card__header-buttons{' +
                'display:flex;align-items:center;gap:8px;}' +
            '#entware-dashboard-card .dashboard-card__drag-icon{' +
                'color:var(--text-gray,#949b9f);cursor:grab;display:flex;}' +
            '#entware-dashboard-card .dashboard-card__drag-icon svg{' +
                'width:20px;height:20px;fill:currentColor;}' +
            /* Card content — stock: position:relative + same left/right padding as header */
            '#entware-dashboard-card .dashboard-card__content{' +
                'position:relative;padding:0 24px 16px 24px;}' +
            /* Service rows — stock layout: toggle | info block */
            '.ew-dash-row{display:flex;align-items:flex-start;gap:16px;padding:14px 0;}' +
            '.ew-dash-row+.ew-dash-row,.ew-details+.ew-dash-row{border-top:1px solid var(--stroke,#4d545f);}' +
            '.ew-dash-info{flex:1;min-width:0;}' +
            '.ew-dash-title{font-size:16px;font-weight:500;color:var(--primary-text,#c2c2c2);' +
                'cursor:pointer;line-height:1.3;}' +
            '.ew-dash-title:hover{text-decoration:underline;}' +
            '.ew-dash-desc{color:var(--text-gray,#949b9f);font-size:13px;margin-top:2px;}' +
            '.ew-dash-meta{color:var(--text-gray,#949b9f);font-size:12px;margin-top:2px;' +
                'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}' +
            /* Toggle switch — connected to start/stop API */
            '.ew-toggle{position:relative;width:36px;height:20px;flex-shrink:0;margin-top:2px;}' +
            '.ew-toggle input{opacity:0;width:0;height:0;position:absolute;}' +
            '.ew-toggle__bar{position:absolute;top:0;left:0;right:0;bottom:0;' +
                'background:var(--disabled,#2f3745);border-radius:10px;cursor:pointer;' +
                'transition:background .2s;}' +
            '.ew-toggle__bar::after{content:\'\';position:absolute;width:16px;height:16px;' +
                'border-radius:50%;background:var(--text-gray,#949b9f);' +
                'bottom:2px;left:2px;transition:transform .2s,background .2s;}' +
            '.ew-toggle input:checked+.ew-toggle__bar{' +
                'background:var(--primary-color-disabled,#2e3d57);}' +
            '.ew-toggle input:checked+.ew-toggle__bar::after{' +
                'transform:translateX(16px);background:var(--primary-color,#0086cb);}' +
            '.ew-toggle input:disabled+.ew-toggle__bar{opacity:0.5;cursor:not-allowed;}' +
            /* Status chip — stock-like with background */
            '.ew-chip{display:inline-flex;align-items:center;gap:6px;' +
                'padding:4px 12px;border-radius:12px;font-size:12px;font-weight:500;' +
                'text-transform:uppercase;letter-spacing:.5px;margin-top:6px;}' +
            '.ew-chip__dot{width:6px;height:6px;border-radius:50%;flex-shrink:0;}' +
            '.ew-chip--running{background:rgba(125,206,112,.12);color:var(--indicator-online,#7dce70);}' +
            '.ew-chip--running .ew-chip__dot{background:var(--indicator-online,#7dce70);}' +
            '.ew-chip--caution{background:rgba(242,229,114,.12);color:var(--status-caution-text,#ffbb57);}' +
            '.ew-chip--caution .ew-chip__dot{background:var(--indicator-yellow,#f2e572);}' +
            '.ew-chip--stopped{background:var(--disabled,#2f3745);color:var(--text-gray,#949b9f);}' +
            '.ew-chip--stopped .ew-chip__dot{background:var(--text-gray,#949b9f);}' +
            '.ew-chip--error{background:rgba(222,61,61,.12);color:var(--error,#de3d3d);}' +
            '.ew-chip--error .ew-chip__dot{background:var(--error,#de3d3d);}' +
            /* Expand button — stock toggle vars, geometry tuned for our card style */
            '.ew-expand-btn{' +
                'min-width:unset;width:36px;height:36px;' +
                'justify-content:center;padding:0;' +
                'border:1px solid var(--toggle-button-default-border,rgba(235,235,235,.24));' +
                'border-radius:8px;outline:none;' +
                'background:var(--toggle-button-default-background,var(--background,#1b2434));' +
                'color:var(--primary-text,#c2c2c2);' +
                'display:flex;align-items:center;' +
                'flex-shrink:0;align-self:flex-start;cursor:pointer;' +
                'transition:border-color .15s,color .15s,background .15s;}' +
            '.ew-expand-btn:hover{' +
                'border-color:var(--toggle-button-hover-background,rgba(105,201,155,.15));' +
                'background:var(--toggle-button-hover-background,rgba(105,201,155,.15));cursor:pointer;}' +
            '.ew-expand-btn--active,.ew-expand-btn:active{' +
                'border-color:var(--toggle-button-active-border,#03825a);' +
                'background:var(--toggle-button-hover-background,rgba(105,201,155,.15));}' +
            '.ew-expand-btn:disabled{' +
                'border-color:var(--outline-button-disabled-border,#687378);' +
                'background:var(--outline-button-disabled-background,#333a48);' +
                'color:var(--outline-button-disabled-text,#687378);' +
                'cursor:default;-webkit-user-select:none;user-select:none;}' +
            '.ew-expand-btn svg{width:18px;height:18px;stroke:currentColor;fill:none;stroke-width:2;}' +
            /* Expandable details — CSS Grid for left-to-right order */
            '.ew-details{display:none;padding:16px 0;}' +
                '.ew-details--open{display:grid;grid-template-columns:repeat(3,1fr);gap:16px 24px;}' +
            '.ew-detail-item{overflow-wrap:anywhere;}' +
            '.ew-detail-label{color:var(--text-gray,#949b9f);font-size:14px;' +
                'line-height:22px;}' +
            '.ew-detail-value{color:var(--primary-text,#c2c2c2);font-size:14px;' +
                'line-height:22px;min-height:16px;}' +
            /* Update button inline (stock Keenetic style) */
            '.ew-update-btn{' +
                'position:relative;background:none;border:none;cursor:pointer;' +
                'color:var(--text-gray,#949b9f);font-size:16px;' +
                'padding:0 2px;margin-left:4px;vertical-align:middle;' +
                'line-height:1;opacity:0.7;transition:color .15s,opacity .15s;}' +
            '.ew-update-btn:hover{color:var(--primary-text,#c2c2c2);opacity:1;}' +
            '.ew-update-btn:disabled{opacity:0.3;cursor:not-allowed;}' +
            '.ew-update-btn--spinning svg{animation:ew-spin 1s linear infinite;}' +
            '@keyframes ew-spin{from{transform:rotate(0deg)}to{transform:rotate(360deg)}}' +
            /* Tooltip (stock Keenetic variables) */
            '.ew-update-btn[data-tooltip]:hover::after{' +
                'content:attr(data-tooltip);position:absolute;' +
                'bottom:calc(100% + 6px);left:50%;transform:translateX(-50%);' +
                'background:var(--tooltip-background,#2a3444);' +
                'color:var(--tooltip-text,#fff);font-size:12px;' +
                'padding:4px 8px;border-radius:4px;white-space:nowrap;' +
                'pointer-events:none;z-index:1000;}' +
            /* ── Cards Position dialog — card stub styling ── */
            '.entware-dialog-row{margin-bottom:24px;}' +
            '.entware-dialog-row .dashboard-card{' +
                'background:var(--dashboard-card-background,var(--background,#1b2434));' +
                'border-radius:8px;border:1px solid var(--dashboard-card-border,#4d545f);' +
                'padding-bottom:4px;}' +
            '.ew-dialog-toggle{padding:8px 16px 12px 16px;}' +
            /* ── Cards Position dialog — stock ndw-toggle 1:1 replica ── */
            /* Uses stock CSS vars (--toggle-*) from body — auto-adapts to dark/light theme */
            '.entware-dialog-row .ndw-toggle__checkbox{' +
                'position:absolute;opacity:0;width:34px;height:20px;margin:0;cursor:pointer;}' +
            '.entware-dialog-row .ndw-toggle{display:inline-block;}' +
            '.entware-dialog-row .ndw-toggle__wrapper{' +
                'display:flex;align-items:center;cursor:pointer;gap:8px;}' +
            '.entware-dialog-row .ndw-toggle__button{' +
                'position:relative;width:34px;height:14px;display:block;}' +
            '.entware-dialog-row .ndw-toggle__toggle-bar{' +
                'width:inherit;height:14px;border:1px solid transparent;' +
                'border-radius:10px;background-color:var(--toggle-off-background,#2e3d57);' +
                'transition:background-color .1s;}' +
            '.entware-dialog-row .ndw-toggle__toggle-bar__thumb{' +
                'width:20px;height:20px;position:absolute;top:-3px;left:1px;' +
                'border-radius:50%;transition:transform .1s;' +
                'transform:translate(-1px);' +
                'background-color:var(--toggle-off-thumb-background,#808B96);' +
                'box-shadow:var(--toggle-off-thumb-box-shadow,0);}' +
            '.entware-dialog-row .ndw-toggle__toggle-bar--on{' +
                'background-color:var(--toggle-on-background,#3d5073);}' +
            '.entware-dialog-row .ndw-toggle__toggle-bar--on .ndw-toggle__toggle-bar__thumb{' +
                'transform:translate(14px);' +
                'background-color:var(--toggle-on-thumb-background,#0097DC);' +
                'box-shadow:var(--toggle-on-thumb-box-shadow,0);}' +
            '.entware-dialog-row .ndw-toggle__label-wrapper{display:flex;align-items:center;}' +
            '.entware-dialog-row .ndw-toggle__label{' +
                'font-size:14px;line-height:16px;color:inherit;}' +
            /* ── HTML5 drag visual feedback ── */
            /* ── Cards Position dialog — disabled card state (toggle OFF) ── */
            '.entware-dialog-row--off .dashboard-card{opacity:0.5;}' +
            '.entware-dialog-row--off .ndw-drag-handle{display:none;}' +
            /* ── HTML5 drag visual feedback ── */
            '.ew-dragging{opacity:0.5;}' +
            '.ew-drag-over{border-top:2px solid var(--primary-color,#0086cb);}';
        document.head.appendChild(style);
    }

    // ── Build sidebar section ────────────────────────────────────────────────

    /**
     * Create the "Entware Extras" sidebar section DOM.
     * Uses stock Keenetic menu classes. Inline list-style:none because
     * stock CSS doesn't cascade to dynamically injected DOM nodes.
     * @returns {HTMLDivElement}
     */
    function buildSection() {
        var section = document.createElement('div');
        section.className = 'entware-menu-section';

        // Group header — stock classes: menu__header menu-subtitle
        var header = document.createElement('div');
        header.setAttribute('role', 'menuitem');
        header.tabIndex = 0;
        header.className = 'menu__header menu-subtitle menu-subtitle--expanded';
        header.innerHTML =
            '<ndw-svg-icon class="menu-subtitle__icon">' +
                '<svg class="ndw-svg-icon svg-settings-dims" style="width:24px;height:24px;fill:currentColor;">' +
                    '<use href="./assets/sprite/sprite.svg#settings"></use>' +
                '</svg>' +
            '</ndw-svg-icon>' +
            '<div class="menu-subtitle__label menu-subtitle__label--wrapped">' +
                'Entware Extras' +
            '</div>';
        section.appendChild(header);

        // Items list — stock classes: menu__pages page-link
        var ul = document.createElement('ul');
        ul.setAttribute('role', 'menu');
        ul.className = 'menu__pages page-link';
        ul.style.listStyle = 'none';
        ul.style.margin = '0';
        ul.style.padding = '0';

        CUSTOM_ITEMS.forEach(function(item) {
            var li = document.createElement('li');
            li.className = 'page-link__list';

            var link = document.createElement('a');
            link.setAttribute('role', 'menuitem');
            link.className = 'page-link__link text-menu-item page-link__link--wrapped';
            link.tabIndex = 0;
            link.id = 'entware-item-' + item.id;
            link.href = 'javascript:void(0)';

            var span = document.createElement('span');
            span.className = 'page-link__label';
            span.textContent = item.label;
            link.appendChild(span);

            link.addEventListener('click', function(e) {
                e.preventDefault();
                e.stopPropagation();
                showInContent(item);
            });

            li.appendChild(link);
            ul.appendChild(li);
        });

        section.appendChild(ul);
        return section;
    }

    // ── Show custom page in layout__content iframe ───────────────────────────

    /**
     * Load a custom page inside the Keenetic layout content area via iframe.
     * @param {{id: string, url: string}} item
     */
    function showInContent(item) {
        var menu = document.querySelector('ndw-menu');
        var content = null;
        if (menu && menu.parentElement) {
            content = menu.parentElement.querySelector('[class*="layout__content"]');
            if (!content) content = menu.nextElementSibling;
        }
        if (!content) content = document.querySelector('[class*="layout__content"]');

        if (!content) {
            window.open(item.url, '_blank');
            return;
        }

        // Remove active from stock menu items
        document.querySelectorAll('.menu__item--active, .page-link__link--active').forEach(function(el) {
            el.classList.remove('menu__item--active', 'page-link__link--active');
        });
        // Set our active state
        document.querySelectorAll('.entware-menu-section .page-link__link').forEach(function(el) {
            el.classList.remove('page-link__link--active');
        });
        var el = document.getElementById('entware-item-' + item.id);
        if (el) el.classList.add('page-link__link--active');
        activeItem = item.id;

        insertingIframe = true;
        var iframe = document.getElementById('entware-iframe');
        if (!iframe) {
            for (var i = 0; i < content.children.length; i++) {
                content.children[i].dataset.entwareHidden = content.children[i].style.display;
                content.children[i].style.display = 'none';
            }
            iframe = document.createElement('iframe');
            iframe.id = 'entware-iframe';
            iframe.style.cssText = 'width:100%;height:100%;border:none;min-height:calc(100vh - 64px);background:var(--background, #1b2434);display:block;';
            content.appendChild(iframe);
        }
        iframe.src = item.url;

        // Send stock CSS URL to iframe for theme resilience
        iframe.onload = function() {
            sendCSSUrlToIframe(iframe);
        };

        setTimeout(function() { insertingIframe = false; }, 100);
    }

    // ── CSS URL resilience ───────────────────────────────────────────────────

    /** @returns {string|null} Current stock styles-*.css URL */
    function getStockCSSUrl() {
        var link = document.querySelector('link[rel="stylesheet"][href*="styles-"]');
        return link ? link.href : null;
    }

    /**
     * Send stock CSS URL to iframe via postMessage.
     * @param {HTMLIFrameElement} iframe
     */
    function sendCSSUrlToIframe(iframe) {
        var url = getStockCSSUrl();
        if (url && iframe.contentWindow) {
            try {
                iframe.contentWindow.postMessage({ type: 'keenetic-css-url', url: url }, '*');
            } catch (_) { /* cross-origin */ }
        }
    }

    // ── Remove iframe ────────────────────────────────────────────────────────

    /** Remove the custom iframe and reset menu active state. */
    function removeIframe() {
        activeItem = null;
        document.querySelectorAll('.entware-menu-section .page-link__link').forEach(function(el) {
            el.classList.remove('page-link__link--active');
        });
        var iframe = document.getElementById('entware-iframe');
        if (iframe) iframe.remove();
    }

    // ── Restore on stock menu click + Angular navigation ─────────────────────

    /** Set up listeners to remove iframe when user navigates via stock menu. */
    function setupRestore() {
        document.addEventListener('click', function(e) {
            var item = e.target.closest('.menu__item, .page-link__link');
            if (item && !item.closest('.entware-menu-section') && activeItem) {
                removeIframe();
            }
        }, true);

        setTimeout(function() {
            var content = document.querySelector('[class*="layout__content"]');
            if (!content) {
                var menu = document.querySelector('ndw-menu');
                if (menu) content = menu.nextElementSibling;
            }
            if (content) {
                var obs = new MutationObserver(function() {
                    if (insertingIframe) return;
                    var iframe = document.getElementById('entware-iframe');
                    if (iframe) removeIframe();
                });
                obs.observe(content, { childList: true });
            }
        }, 3000);
    }

    // ── Dashboard summary card ───────────────────────────────────────────────

    /**
     * Build a single service row for the dashboard card.
     * Layout matches stock: [toggle] [title + description + status chip].
     * @param {{id: string, label: string, desc: string, url: string}} svc
     * @returns {HTMLDivElement}
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
                cb.disabled = true;
                bar.style.opacity = '0.5';
                fetch('/api/' + svc.id + '/' + action, { method: 'POST' })
                    .then(function(r) { return r.json(); })
                    .then(function(data) {
                        cb.disabled = false;
                        bar.style.opacity = '';
                        if (!data.ok) cb.checked = !cb.checked;
                        setTimeout(fetchDashboardStatuses, 500);
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
            showInContent({ id: svc.id, url: svc.url });
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
     * Build and inject ENTWARE EXTRAS summary card on /dashboard.
     * Uses stock dashboard-card classes + ndw-drag-panel column layout.
     * Reads card position from RCI to place in correct column/position.
     */
    function injectDashboardCard() {
        dashboardPending = false;
        if (dashboardInjected) return;
        if (window.location.pathname !== '/dashboard') return;

        // Determine target column from saved position
        var pos = getEntwareCardPosition();
        var colIdx = pos ? pos.column : 0;
        var visible = pos ? pos.visible !== false : true;

        // Find target column in drag-panel grid
        var colEl = null;
        var columns = document.querySelectorAll('.ndw-drag-panel__column');
        if (columns.length > 0) {
            colEl = columns[colIdx] || columns[0];
        }
        if (!colEl) {
            // Fallback: find grid via stock dashboard card parent
            var firstCard = document.querySelector('ndw-dashboard-card');
            if (firstCard) {
                colEl = firstCard.parentElement;
            } else {
                var menu = document.querySelector('ndw-menu');
                if (menu && menu.parentElement) {
                    colEl = menu.parentElement.querySelector('[class*="layout__content"]');
                }
                if (!colEl) colEl = document.querySelector('[class*="layout__content"]');
            }
        }
        if (!colEl) return;

        // Inject CSS for dashboard card layout
        injectDashStyles();

        // Card container — stock class
        var card = document.createElement('div');
        card.id = 'entware-dashboard-card';
        card.className = 'dashboard-card ew-dash-card';

        // Header — stock pattern: title left, buttons right
        var header = document.createElement('div');
        header.className = 'dashboard-card__header';

        var headerTitle = document.createElement('span');
        headerTitle.className = 'dashboard-card__header-link text-card-heading';
        headerTitle.textContent = 'ENTWARE EXTRAS';
        headerTitle.addEventListener('click', function(e) {
            e.preventDefault();
            showInContent({ id: 'dashboard', url: '/custom/' });
        });

        var headerButtons = document.createElement('div');
        headerButtons.className = 'dashboard-card__header-buttons';
        // Drag handle icon (6 dots) — stock SVG sprite
        headerButtons.innerHTML =
            '<ndw-svg-icon class="ndw-drag-handle dashboard-card__drag-icon">' +
                '<svg class="ndw-svg-icon svg-drag-and-drop-dims">' +
                    '<use href="./assets/sprite/sprite.svg#drag-and-drop"></use>' +
                '</svg>' +
            '</ndw-svg-icon>';

        header.appendChild(headerTitle);
        header.appendChild(headerButtons);

        // Content with service rows
        var content = document.createElement('div');
        content.className = 'dashboard-card__content';
        content.id = 'entware-dash-content';

        SERVICE_APIS.forEach(function(svc) {
            content.appendChild(buildServiceRow(svc));
        });

        card.appendChild(header);
        card.appendChild(content);

        // Wrap card in ndw-drag-panel__row for grid integration
        var wrapper = document.createElement('div');
        wrapper.className = 'ndw-drag-panel__row';
        wrapper.id = 'entware-dashboard-wrapper';
        wrapper.appendChild(card);

        // Hide wrapper if card visibility is off
        if (!visible) {
            wrapper.style.display = 'none';
        }

        // Insert at position: before hidden placeholder row
        var placeholder = colEl.querySelector('.ndw-drag-panel__row--hidden');
        if (placeholder) {
            colEl.insertBefore(wrapper, placeholder);
        } else {
            colEl.appendChild(wrapper);
        }
        dashboardInjected = true;

        // Enable HTML5 drag for our dashboard card
        setupEntwareDrag(wrapper, function(colIdx, posIdx) {
            var p = getEntwareCardPosition() || { column: 0, position: 0, visible: true };
            p.column = colIdx;
            p.position = posIdx;
            saveEntwarePosition(p);
        });

        // Event delegation for update buttons (geo-split subnet/domain refresh)
        card.addEventListener('click', function(e) {
            var btn = e.target.closest('.ew-update-btn');
            if (!btn || btn.disabled) return;
            var actionUrl = btn.getAttribute('data-action');
            btn.classList.add('ew-update-btn--spinning');
            btn.disabled = true;
            fetch(actionUrl, { method: 'POST' })
                .then(function(r) { return r.json(); })
                .then(function() {
                    // Started in background. Fast polling picks up background=running
                    startGeoFastPolling();
                })
                .catch(function() {
                    btn.classList.remove('ew-update-btn--spinning');
                    btn.disabled = false;
                });
        });

        fetchDashboardStatuses();
        dashboardTimer = setInterval(fetchDashboardStatuses, DASH_POLL_INTERVAL);
        startUptimeTicker();
    }

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

    /** Start 1s ticker that updates all running chips with live uptime + freshness. */
    function startUptimeTicker() {
        if (uptimeTickTimer) return;
        uptimeTickTimer = setInterval(function() {
            var now = Date.now();
            // Update uptime chips
            for (var id in uptimeBaselines) {
                var bl = uptimeBaselines[id];
                var elapsed = Math.floor((now - bl.timestamp) / 1000);
                var currentSeconds = bl.seconds + elapsed;
                var row = document.getElementById('ew-dash-' + id);
                if (!row) continue;
                var chip = row.querySelector('.ew-chip');
                if (!chip) continue;
                // Tick both running and caution chips (both show uptime)
                if (!chip.classList.contains('ew-chip--running') && !chip.classList.contains('ew-chip--caution')) continue;
                chip.innerHTML = '<span class="ew-chip__dot"></span> RUNNING ' + formatUptimeStock(currentSeconds);
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

    /** Format detail key: snake_case → Title Case. */
    function formatKey(key) {
        return key.replace(/_/g, ' ').replace(/\b\w/g, function(c) { return c.toUpperCase(); });
    }

    /** Format boolean: true → "Ok", false → "Fail". */
    function formatBool(val) {
        return val ? 'Ok' : 'Fail';
    }

    // Updatable detail keys → POST action URL (only geo-split)
    var GEO_UPDATE_ACTIONS = {
        'geo_zone':       '/api/geo-split/update-subnets',
        'domain_sources': '/api/geo-split/update-domains'
    };

    /**
     * Render details grid HTML from data.details object.
     * Iterates keys in JSON order (matches status.sh text output).
     * Booleans rendered via formatBool() with red color for negative states.
     * Red highlighting suppressed when service is stopped (running=false).
     * @param {Object} details - data.details from status API
     * @param {boolean} isRunning - whether the service is running
     * @returns {string}
     */
    function renderDetailsGrid(details, isRunning) {
        if (!details) return '';
        var keys = Object.keys(details);
        var html = '';
        for (var i = 0; i < keys.length; i++) {
            var key = keys[i];
            if (DETAILS_SKIP_KEYS[key]) continue;
            // Keys starting with "_" → empty grid cell (spacer)
            if (key.charAt(0) === '_') { html += '<div class="ew-detail-item"></div>'; continue; }
            var val = details[key];
            if (val === '' || val === null || val === undefined) continue;
            var valStyle = '';
            if (typeof val === 'boolean') {
                if (!val && isRunning) valStyle = ' style="color:var(--error,#f44336)"';
                val = formatBool(val);
            } else if (typeof val === 'number' && val === 0 && isRunning) {
                valStyle = ' style="color:var(--error,#f44336)"';
            }
            // Timer fields: numeric seconds → formatted string
            if (typeof val === 'number' && TIMER_KEYS[key]) {
                val = formatUptimeStock(val);
            }
            val = String(val);
            // Multi-line values: split on \n, "!" prefix → red line
            if (val.indexOf('\n') !== -1) {
                val = val.split('\n').map(function(line) {
                    if (line.charAt(0) === '!' && isRunning) return '<span style="color:var(--error,#f44336)">' + line.substring(1) + '</span>';
                    if (line.charAt(0) === '!') return line.substring(1);
                    return line;
                }).join('<br>');
            } else if (val.indexOf(' ') !== -1 && val.indexOf(':') !== -1) {
                // Space-separated multi-values (e.g. ports)
                val = val.split(' ').join('<br>');
            }
            var updateBtn = '';
            if (GEO_UPDATE_ACTIONS[key]) {
                updateBtn = ' <button class="ew-update-btn" data-action="' + GEO_UPDATE_ACTIONS[key] + '" data-tooltip="Force Reload">' +
                    '<svg class="ndw-svg-icon svg-restart-dims" style="width:14px;height:14px;fill:currentColor"><use href="/assets/sprite/sprite.svg#restart"></use></svg></button>';
            }
            // Add data-freshness-key for live ticker on freshness fields
            var dataAttr = '';
            if (TIMER_KEYS[key]) {
                dataAttr = ' data-freshness-key="' + key + '"';
            }
            html += '<div class="ew-detail-item">' +
                '<div class="ew-detail-label">' + formatKey(key) + '</div>' +
                '<div class="ew-detail-value"' + valStyle + dataAttr + '>' + val + updateBtn + '</div></div>';
        }
        return html;
    }

    /** Start fast polling for geo-split card (3s). */
    function startGeoFastPolling() {
        if (geoFastPollTimer) return;
        geoFastPollTimer = setInterval(function() {
            fetchSingleServiceStatus('geo-split');
        }, GEO_FAST_POLL);
    }

    /** Stop fast polling, remove spinning indicators. */
    function stopGeoFastPolling() {
        if (!geoFastPollTimer) return;
        clearInterval(geoFastPollTimer);
        geoFastPollTimer = null;
        // Remove spinning from all update buttons
        var card = document.getElementById('entware-dashboard-card');
        if (card) {
            card.querySelectorAll('.ew-update-btn--spinning').forEach(function(btn) {
                btn.classList.remove('ew-update-btn--spinning');
                btn.disabled = false;
            });
        }
    }

    /**
     * Fetch status for a single service and update its row.
     * Used by geo-split fast polling (1s interval during background updates).
     * @param {string} serviceId - SERVICE_APIS entry id
     */
    function fetchSingleServiceStatus(serviceId) {
        var svc = null;
        for (var i = 0; i < SERVICE_APIS.length; i++) {
            if (SERVICE_APIS[i].id === serviceId) { svc = SERVICE_APIS[i]; break; }
        }
        if (!svc) return;
        fetch(svc.api, { cache: 'no-store' })
            .then(function(r) { return r.json(); })
            .then(function(data) { applyServiceData(svc, data); })
            .catch(function() {});
    }

    /**
     * Check if any detail field is boolean false.
     * @param {Object} details
     * @returns {boolean}
     */
    function hasFailField(details) {
        if (!details) return false;
        var keys = Object.keys(details);
        for (var i = 0; i < keys.length; i++) {
            if (details[keys[i]] === false) return true;
        }
        return false;
    }

    /**
     * Build status chip text from structured data.
     * Returns "caution" state if running but any detail is boolean false.
     * @param {Object} data - full API response
     * @returns {{state: string, text: string}}
     */
    function parseServiceStatus(data) {
        var state = data.running ? 'running' : 'stopped';
        // If running but at least one detail field is false → caution (yellow)
        if (data.running && hasFailField(data.details)) {
            state = 'caution';
        }
        var text = data.running ? 'RUNNING' : 'STOPPED';
        if (data.running && data.details && data.details.uptime) {
            text += ' ' + formatUptimeStock(data.details.uptime);
        }
        return { state: state, text: text };
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

        // Update toggle
        if (toggle) toggle.checked = data.running;

        // Update chip
        if (chip) {
            chip.className = 'ew-chip ew-chip--' + s.state;
            chip.innerHTML = '<span class="ew-chip__dot"></span> ' + s.text;
        }

        // Update expandable details grid
        if (detailsEl) {
            detailsEl.innerHTML = renderDetailsGrid(data.details, data.running);
        }

        // Update uptime baseline
        if (data.running && data.details && data.details.uptime) {
            uptimeBaselines[svc.id] = { seconds: data.details.uptime, timestamp: Date.now() };
        } else {
            delete uptimeBaselines[svc.id];
        }

        // Update freshness baselines (timer keys)
        if (data.details) {
            for (var tk in TIMER_KEYS) {
                if (data.details[tk]) {
                    freshnessBaselines[tk] = { seconds: data.details[tk], timestamp: Date.now() };
                }
            }
        }

        // Check geo-split background for fast polling
        if (svc.id === 'geo-split' && data.details) {
            if (data.details.background === 'running') {
                startGeoFastPolling();
            } else if (geoFastPollTimer) {
                stopGeoFastPolling();
            }
        }
    }

    /**
     * Fetch service statuses in parallel and update dashboard card rows.
     * Each service is fetched independently for maximum parallelism.
     */
    function fetchDashboardStatuses() {
        SERVICE_APIS.forEach(function(svc) {
            fetch(svc.api, { cache: 'no-store' })
                .then(function(r) { return r.json(); })
                .then(function(data) { applyServiceData(svc, data); })
                .catch(function() {
                    var chip = document.querySelector('#ew-dash-' + svc.id + ' .ew-chip');
                    if (chip) {
                        chip.className = 'ew-chip ew-chip--error';
                        chip.innerHTML = '<span class="ew-chip__dot"></span> ERROR';
                    }
                });
        });
    }

    // ── Sidebar injection ────────────────────────────────────────────────────

    /**
     * Try injecting sidebar section into ndw-menu.
     * @returns {boolean} true if injected
     */
    function tryInject() {
        if (injected) return true;
        var container = document.querySelector('ndw-menu .menu__contents');
        if (!container) return false;
        container.appendChild(buildSection());
        injected = true;
        setupRestore();
        setupCardsPositionDialog();
        return true;
    }

    /**
     * Schedule dashboard card injection (with dedup guard).
     */
    function tryDashboardCard() {
        if (dashboardInjected || dashboardPending) return;
        if (window.location.pathname === '/dashboard') {
            dashboardPending = true;
            if (!_entwareCardPosRead) {
                // First time: read position from RCI, then inject
                readEntwarePosition(function() {
                    setTimeout(injectDashboardCard, 1000);
                });
            } else {
                setTimeout(injectDashboardCard, 1500);
            }
        }
    }

    // ── Main observer — re-inject sidebar if Angular removes it ──────────────

    var observer = new MutationObserver(function() {
        if (!document.querySelector('.entware-menu-section')) {
            injected = false;
        }
        if (!injected) {
            if (tryInject()) {
                tryDashboardCard();
            }
        }
        // Check if Angular removed our wrapper (full dashboard re-render)
        if (dashboardInjected && !document.getElementById('entware-dashboard-wrapper')) {
            dashboardInjected = false;
            dashboardPending = false;
            if (dashboardTimer) { clearInterval(dashboardTimer); dashboardTimer = null; }
            if (geoFastPollTimer) { clearInterval(geoFastPollTimer); geoFastPollTimer = null; }
            stopUptimeTicker();
        }
        if (injected && !dashboardInjected) {
            tryDashboardCard();
        }
    });

    observer.observe(document.documentElement, { childList: true, subtree: true });

    // ── Route change watcher ─────────────────────────────────────────────────

    var lastPath = window.location.pathname;
    setInterval(function() {
        var currentPath = window.location.pathname;

        // Re-inject sidebar if Angular removed it
        if (!document.querySelector('.entware-menu-section')) {
            injected = false;
            if (tryInject()) {
                // Switch to menu-scoped observer for performance
                var menuEl = document.querySelector('ndw-menu');
                if (menuEl) {
                    observer.disconnect();
                    observer.observe(menuEl, { childList: true, subtree: true });
                }
            }
        }

        // Reset dashboard card on route change
        if (currentPath !== lastPath) {
            lastPath = currentPath;
            dashboardInjected = false;
            dashboardPending = false;
            if (dashboardTimer) {
                clearInterval(dashboardTimer);
                dashboardTimer = null;
            }
            if (geoFastPollTimer) {
                clearInterval(geoFastPollTimer);
                geoFastPollTimer = null;
            }
            stopUptimeTicker();
            var oldWrapper = document.getElementById('entware-dashboard-wrapper');
            if (oldWrapper) oldWrapper.remove();
            var oldCard = document.getElementById('entware-dashboard-card');
            if (oldCard) oldCard.remove();
            tryDashboardCard();
        }
    }, 2000);
})();
