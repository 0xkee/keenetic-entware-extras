// inject.js — Keenetic NDMS WebUI sidebar + dashboard integration for Entware extras.
// Injected via nginx sub_filter into every proxied Keenetic page.
// Uses stock Keenetic DOM classes (dashboard-card, ndw-status, ndw-router-link).
// Reconciler model: nginx patches Angular bundle (set order + getTemplate);
// this script reconciles Angular-created rows by order index from __ewLastOrder.
(function() {
    'use strict';

    // ── Sync position from localStorage for set order() patch ────────────────
    // Must be sync, before Angular renders — set order() reads window.__ewPos
    try {
        var _p = localStorage.getItem('ew-card-pos');
        if (_p) window.__ewPos = JSON.parse(_p);
        else window.__ewPos = { c: 0, i: 999 };
    } catch(_e) {
        window.__ewPos = { c: 0, i: 999 };
    }

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
                            var wp = window.__ewPos;
                            var pos = wp ? { column: wp.c, position: wp.i } : getEntwareCardPosition();
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
     * Persist card position to RCI env variable + sync to localStorage
     * for next page load (sync read by set order() nginx patch).
     * @param {{column:number, position:number, visible:boolean}} pos
     */
    function saveEntwarePosition(pos) {
        _entwareCardPos = pos;
        // Sync to localStorage for set order() patch (sync read on page load)
        try { localStorage.setItem('ew-card-pos', JSON.stringify({c: pos.column, i: pos.position})); } catch(e) {}
        window.__ewPos = { c: pos.column, i: pos.position };
        // Async to RCI for cross-device persistence
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

    // ── Reconciler: patch Angular-created rows by order index ─────────
    var EW_KEY = 'ENTWARE_EXTRAS';
    var EW_ATTR = 'data-ew-key';

    var ewScheduled = false;
    var ewInDrag = false;

    /** Schedule deferred reconcile — 2x rAF ensures Angular render complete. */
    function ewScheduleReconcile(reason) {
        if (ewScheduled) return;
        ewScheduled = true;
        requestAnimationFrame(function() {
            requestAnimationFrame(function() {
                ewScheduled = false;
                ewReconcile(reason);
            });
        });
    }

    /** Check element is visible (connected + has dimensions). */
    function ewVisible(el) {
        if (!el || !el.isConnected) return false;
        var r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
    }

    /** Filter out CDK drag previews/placeholders (transient clones). */
    function ewIsCdkNoise(el) {
        return el.classList.contains('cdk-drag-preview') ||
               el.classList.contains('cdk-drag-placeholder') ||
               !!el.closest('.cdk-drag-preview') ||
               !!el.closest('.cdk-drag-placeholder');
    }

    /** Find the panel root — Cards Position dialog overlay OR dashboard panel. */
    function ewFindPanelRoot() {
        return document.querySelector('.cdk-overlay-pane ndw-cards-position-dialog') ||
               document.querySelector('ndw-drag-panel') ||
               null;
    }

    /** Get live Angular-created rows in a column, excluding CDK noise. */
    function ewGetColRows(col) {
        return [].slice.call(col.querySelectorAll(
            ':scope > .cdk-drag.ndw-drag-panel__row'
        )).filter(function(row) { return !ewIsCdkNoise(row); });
    }

    /**
     * Main reconcile — find ENTWARE_EXTRAS row by order index, patch it.
     * Source of truth: window.__ewLastOrder ONLY.
     * Never creates/moves CDK rows. Idempotent.
     */
    function ewReconcile(reason) {
        if (ewInDrag) {
            ewScheduleReconcile('drag-active');
            return;
        }

        var order = window.__ewLastOrder;
        if (!Array.isArray(order)) return;

        // Flatten order to find ENTWARE_EXTRAS
        var flat = [].concat.apply([], order);
        var entwareCount = 0;
        for (var i = 0; i < flat.length; i++) {
            if (flat[i] === EW_KEY) entwareCount++;
        }
        if (entwareCount !== 1) return;

        // Find column and index of ENTWARE_EXTRAS in order
        var entwareCol = -1, entwareIdx = -1;
        for (var ci = 0; ci < order.length; ci++) {
            var idx = order[ci].indexOf(EW_KEY);
            if (idx >= 0) {
                entwareCol = ci;
                entwareIdx = idx;
                break;
            }
        }
        if (entwareCol < 0) return;

        var root = ewFindPanelRoot();
        if (!root) return;

        // Find column containers
        var columns = root.querySelectorAll('.ndw-drag-panel__column');
        var col = columns[entwareCol];
        if (!col) return;

        // Get rows in this column (excluding CDK noise)
        var rows = ewGetColRows(col);

        if (rows.length <= entwareIdx) {
            ewScheduleReconcile('rows-not-ready');
            return;
        }

        var targetRow = rows[entwareIdx];

        // Remove stale ENTWARE marks from ALL rows across ALL columns
        var allMarked = root.querySelectorAll('[' + EW_ATTR + ']');
        for (var mi = 0; mi < allMarked.length; mi++) {
            if (allMarked[mi] !== targetRow) {
                ewUnpatchRow(allMarked[mi]);
            }
        }

        // Patch the target row
        var patched = ewPatchDashboardRow(targetRow);

        if (patched) {
            // Track position for saveEntwarePosition
            ewTrackPosition(entwareCol, entwareIdx);

            // Ensure dashboard polling is started
            if (!dashboardInjected && window.location.pathname === '/dashboard') {
                dashboardInjected = true;
                fetchDashboardStatuses();
                if (!dashboardTimer) {
                    dashboardTimer = setInterval(fetchDashboardStatuses, DASH_POLL_INTERVAL);
                }
                startUptimeTicker();
                if (!_entwareCardPosRead) {
                    readEntwarePosition(function() {});
                }
            }
        }
    }

    /**
     * Remove our injected content and restore Angular-managed DOM.
     * Removing .ew-dash-card deactivates the CSS rule that hides Angular
     * stub content, so original children become visible automatically.
     */
    function ewUnpatchRow(row) {
        row.removeAttribute(EW_ATTR);
        row.classList.remove('ew-row');
        // Remove our injected content
        var ewContent = row.querySelector('#entware-dash-content');
        if (ewContent) ewContent.remove();
        // Remove card-level marker — deactivates CSS hiding rule,
        // Angular stub content becomes visible automatically
        var card = row.querySelector('.ew-dash-card');
        if (card) card.classList.remove('ew-dash-card');
        // Restore original title from saved data
        var title = row.querySelector('.dashboard-card__header-link a') ||
                    row.querySelector('.dashboard-card__header-link') ||
                    row.querySelector('.text-card-heading');
        if (title && row.dataset.ewOrigTitle) {
            title.textContent = row.dataset.ewOrigTitle;
            if (row.dataset.ewOrigHref && title.tagName === 'A') {
                title.setAttribute('href', row.dataset.ewOrigHref);
            }
        }
        delete row.dataset.ewOrigTitle;
        delete row.dataset.ewOrigHref;
    }

    /**
     * Patch an Angular-created row IN-PLACE — modify header + content
     * inside the existing .dashboard-card, preserving Angular component shell
     * (ndw-*-card, ndw-dashboard-card wrappers).
     * Does NOT create/move .cdk-drag elements. Idempotent.
     */
    function ewPatchDashboardRow(row) {
        if (!row || !row.isConnected) return false;

        // Mark the row
        row.setAttribute(EW_ATTR, 'entware-extras');
        row.classList.add('ew-row');

        // Apply visibility from saved position
        var pos = getEntwareCardPosition();
        if (pos && pos.visible === false) {
            row.style.display = 'none';
        } else {
            row.style.display = '';
        }

        // Find the existing .dashboard-card inside Angular component shell
        var card = row.querySelector('.dashboard-card');
        if (!card) return false;

        // Already patched — nothing to do (idempotent)
        if (card.classList.contains('ew-dash-card') &&
            card.querySelector('#entware-dash-content')) return true;

        // Mark the card
        card.classList.add('ew-dash-card');

        // Patch header: replace link text with "ENTWARE EXTRAS"
        var title =
            card.querySelector('.dashboard-card__header-link a') ||
            card.querySelector('.dashboard-card__header-link') ||
            card.querySelector('.text-card-heading');
        if (title) {
            // Save original title/href for reversible unpatch
            row.dataset.ewOrigTitle = title.textContent;
            row.dataset.ewOrigHref = title.getAttribute('href') || '';
            title.textContent = 'ENTWARE EXTRAS';
            if (title.tagName === 'A') {
                title.removeAttribute('href');
                title.removeAttribute('tabindex');
                title.style.cursor = 'default';
                title.setAttribute('role', 'heading');
                title.setAttribute('aria-level', '2');
            }
        }

        // Patch content: append our content alongside Angular-managed children.
        // CSS rule (.ew-dash-card .dashboard-card__content > :not(#entware-dash-content))
        // hides Angular stub content automatically — handles re-renders too.
        var content = card.querySelector('.dashboard-card__content');
        if (content && !content.querySelector('#entware-dash-content')) {
            content.appendChild(buildEntwareDashboardContent());
        }

        // Event delegation for update buttons (geo-split subnet/domain refresh)
        // Attach to card so it survives content re-patches
        if (!card._ewClickHandler) {
            card._ewClickHandler = true;
            card.addEventListener('click', function(e) {
                var btn = e.target.closest('.ew-update-btn');
                if (!btn || btn.disabled) return;
                var actionUrl = btn.getAttribute('data-action');
                btn.classList.add('ew-update-btn--spinning');
                btn.disabled = true;
                fetch(actionUrl, { method: 'POST' })
                    .then(function(r) { return r.json(); })
                    .then(function() {
                        startGeoFastPolling();
                    })
                    .catch(function() {
                        btn.classList.remove('ew-update-btn--spinning');
                        btn.disabled = false;
                    });
            });
        }

        return true;
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
        SERVICE_APIS.forEach(function(svc) {
            wrapper.appendChild(buildServiceRow(svc));
        });
        return wrapper;
    }

    /** Track position changes and persist to RCI. */
    function ewTrackPosition(colIdx, posIdx) {
        var p = getEntwareCardPosition() || { column: 0, position: 0, visible: true };
        if (p.column !== colIdx || p.position !== posIdx) {
            p.column = colIdx;
            p.position = posIdx;
            saveEntwarePosition(p);
        }
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
                // Detect dialog CLOSE: overlay pane removed → clear flag
                var removed = mutations[mi].removedNodes;
                for (var ri = 0; ri < removed.length; ri++) {
                    var rn = removed[ri];
                    if (rn.nodeType === 1 && rn.classList &&
                        rn.classList.contains('cdk-overlay-pane') &&
                        rn.querySelector && rn.querySelector('.ndw-drag-panel__column-wrapper')) {
                        window.__ewDialogOpen = false;
                        if (_dialogRepatchObserver) { _dialogRepatchObserver.disconnect(); _dialogRepatchObserver = null; }
                    }
                }
                // Detect dialog OPEN: new nodes → poll for column-wrapper
                var added = mutations[mi].addedNodes;
                for (var ni = 0; ni < added.length; ni++) {
                    var node = added[ni];
                    if (node.nodeType !== 1) continue;
                    _tryInjectCardsDialog();
                    return; // one fire per batch is enough
                }
            }
        }).observe(container, { childList: true, subtree: true });
    }

    var _cardsDialogPending = false;
    /**
     * Poll overlay panes for Cards Position dialog and inject our row.
     * Retries if injectIntoCardsDialog cannot reliably identify the ENTWARE row
     * (e.g. __ewLastOrder still stale from dashboard's set order() call).
     */
    function _tryInjectCardsDialog() {
        if (_cardsDialogPending) return;
        _cardsDialogPending = true;
        var attempts = 0;
        var timer = setInterval(function() {
            attempts++;
            // Dialog has SEPARATE column-wrapper per column, possibly in same pane.
            // Use querySelectorAll to find ALL wrappers across ALL panes.
            var allWrappers = document.querySelectorAll('.cdk-overlay-pane .ndw-drag-panel__column-wrapper');
            var anyPatched = false;
            for (var i = 0; i < allWrappers.length; i++) {
                var wrapper = allWrappers[i];
                if (wrapper.querySelector('.entware-dialog-patched')) {
                    anyPatched = true;
                    continue;
                }
                var isLastAttempt = attempts > 15;
                if (injectIntoCardsDialog(wrapper, isLastAttempt)) {
                    anyPatched = true;
                }
            }
            if (anyPatched) {
                window.__ewDialogOpen = true;
                clearInterval(timer);
                _cardsDialogPending = false;
                return;
            }
            if (attempts > 15) {
                clearInterval(timer);
                _cardsDialogPending = false;
            }
        }, 200);
    }

    /**
     * Inject ENTWARE EXTRAS content into the Cards Position dialog.
     * Uses __ewLastOrder key→DOM mapping to reliably identify the ENTWARE row
     * by card ID name (not position or text matching).
     *
     * Returns false if the ENTWARE row cannot be reliably identified
     * (e.g. __ewLastOrder is stale from dashboard) — caller should retry.
     *
     * @param {HTMLElement} dialogWrapper - .ndw-drag-panel__column-wrapper element
     * @param {boolean} lastAttempt - if true, use DOM fallback instead of retrying
     * @returns {boolean} true if patched (or already patched), false to retry
     */
    function injectIntoCardsDialog(dialogWrapper, lastAttempt) {
        if (dialogWrapper.querySelector('.entware-dialog-patched')) return true;
        var pos = getEntwareCardPosition();
        var colIdx = pos ? pos.column : 0;
        var isVisible = pos ? pos.visible !== false : true;
        var cols = dialogWrapper.querySelectorAll('.ndw-drag-panel__column');
        var col = cols[colIdx] || cols[0];
        if (!col) return false;

        // ── Primary: find ENTWARE row via __ewLastOrder key→DOM mapping ───────
        // __ewLastOrder stores full order arrays with card ID strings, set by
        // each NdwDragPanel's set order() nginx patch.  We search for
        // ENTWARE_CARD_ID by KEY NAME — no position guessing.
        // Validation: DOM row count must equal order column length to confirm
        // __ewLastOrder belongs to THIS dialog panel (not stale dashboard data).
        // If validation fails → return false → caller retries on next poll
        // (dialog's set order() will have updated __ewLastOrder by then).
        var targetRow = null;
        var order = window.__ewLastOrder;
        // Dialog uses SEPARATE column-wrapper per column (cols.length always 1).
        // Search ALL order columns; validate by matching row count with cols[0].
        if (order && cols[0]) {
            var wrapperRows = cols[0].querySelectorAll(
                ':scope > .cdk-drag.ndw-drag-panel__row:not(.cdk-drag-placeholder):not(.cdk-drag-preview)'
            );
            for (var oi = 0; oi < order.length; oi++) {
                var ewIdx = order[oi].indexOf(ENTWARE_CARD_ID);
                if (ewIdx < 0) continue;
                // Validate: this wrapper's row count must match this order column
                if (wrapperRows.length === order[oi].length && ewIdx < wrapperRows.length) {
                    targetRow = wrapperRows[ewIdx];
                    col = cols[0];
                }
                break;
            }
        }

        // If __ewLastOrder lookup failed and this is NOT the last attempt,
        // signal caller to retry — __ewLastOrder will update on next cycle.
        if (!targetRow && !lastAttempt) {
            return false;
        }

        // Strategy: duplicate header-text detection — ENTWARE row uses stub
        // template that duplicates another card's name (e.g. "INTERNET")
        if (!targetRow) {
            var allDialogRows = [].slice.call(
                dialogWrapper.querySelectorAll('.cdk-drag.ndw-drag-panel__row:not(.cdk-drag-placeholder):not(.cdk-drag-preview)')
            );
            var textCounts = {};
            for (var dri = 0; dri < allDialogRows.length; dri++) {
                var h = allDialogRows[dri].querySelector('.dashboard-card__header-text');
                if (!h) continue;
                var t = h.textContent.trim();
                if (!textCounts[t]) textCounts[t] = [];
                textCounts[t].push(allDialogRows[dri]);
            }
            for (var tk in textCounts) {
                if (textCounts[tk].length > 1) {
                    targetRow = textCounts[tk][textCounts[tk].length - 1];
                    break;
                }
            }
        }

        if (!targetRow) return false;

        // Mark row with data attribute for idempotent identity
        targetRow.dataset.ewKey = ENTWARE_CARD_ID;
        targetRow.classList.add('entware-dialog-patched', 'entware-dialog-row');
        if (!isVisible) targetRow.classList.add('entware-dialog-row--off');

        // ── In-place patch: modify header + toggle inside existing Angular row ──
        // Patch header text — Angular fallback renders "Internet" or other stock card
        var heading = targetRow.querySelector('.dashboard-card__header-text') ||
                      targetRow.querySelector('.text-card-heading');
        if (heading) {
            heading.textContent = 'ENTWARE EXTRAS';
        }

        // Patch toggle: Angular already binds it to cardStates["ENTWARE_EXTRAS"]
        // (from order array). We just fix aria-label, initial state, and add
        // our handler for RCI persistence + dashboard sync.
        var toggle = targetRow.querySelector('input[role="switch"]');
        if (toggle) {
            toggle.setAttribute('aria-label', ENTWARE_CARD_ID);
            toggle.checked = isVisible;
            var barEl = targetRow.querySelector('.ndw-toggle__toggle-bar');
            if (barEl) {
                barEl.classList.toggle('ndw-toggle__toggle-bar--on', isVisible);
                barEl.classList.toggle('ndw-toggle__toggle-bar--off', !isVisible);
            }
            if (!toggle._ewHandlerSet) {
                toggle._ewHandlerSet = true;
                toggle.addEventListener('change', function(e) {
                    var visible = e.target.checked;
                    targetRow.classList.toggle('entware-dialog-row--off', !visible);
                    var p = getEntwareCardPosition() || { column: 0, position: 999, visible: true };
                    p.visible = visible;
                    saveEntwarePosition(p);
                    var ewRow = document.querySelector('[' + EW_ATTR + '="entware-extras"]');
                    if (ewRow) ewRow.style.display = visible ? '' : 'none';
                });
            }
        }

        // ── MutationObserver: re-patch after Angular re-renders (CDK drag/drop) ──
        _setupDialogRepatcher(dialogWrapper);

        return true;
    }

    /** @type {MutationObserver|null} */
    var _dialogRepatchObserver = null;

    /**
     * Set up MutationObserver on dialog wrapper to re-patch ENTWARE row
     * when Angular re-renders it (CDK drag/drop, change detection).
     * Reads CURRENT visibility from getEntwareCardPosition() each time
     * (not stale closure value — fixes toggle snap-back bug).
     * @param {HTMLElement} dialogWrapper
     */
    function _setupDialogRepatcher(dialogWrapper) {
        if (_dialogRepatchObserver) _dialogRepatchObserver.disconnect();
        _dialogRepatchObserver = new MutationObserver(function() {
            requestAnimationFrame(function() {
                var curPos = getEntwareCardPosition();
                var curVisible = curPos ? curPos.visible !== false : true;
                _repatchDialogEntwareRow(dialogWrapper, curVisible);
            });
        });
        _dialogRepatchObserver.observe(dialogWrapper, { childList: true, subtree: true });
    }

    /**
     * Minimal re-patch: fix header-text and aria-label on the ENTWARE row
     * if Angular reverted them to fallback template content.
     * @param {HTMLElement} dialogWrapper
     * @param {boolean} isVisible
     */
    function _repatchDialogEntwareRow(dialogWrapper, isVisible) {
        // Strategy 1: find by data-ew-key (survives Angular inner re-render)
        var row = dialogWrapper.querySelector('[data-ew-key="' + ENTWARE_CARD_ID + '"]');

        // Strategy 2: if row lost data-ew-key (full Angular re-create),
        // re-map via __ewLastOrder
        // Strategy 2: re-map via __ewLastOrder (separate wrapper per column)
        if (!row) {
            var cols = dialogWrapper.querySelectorAll('.ndw-drag-panel__column');
            var order = window.__ewLastOrder;
            if (order && cols[0]) {
                var wRows = cols[0].querySelectorAll(
                    ':scope > .cdk-drag.ndw-drag-panel__row:not(.cdk-drag-placeholder):not(.cdk-drag-preview)'
                );
                for (var oi = 0; oi < order.length; oi++) {
                    var ewIdx = order[oi].indexOf(ENTWARE_CARD_ID);
                    if (ewIdx < 0) continue;
                    if (wRows.length === order[oi].length && ewIdx < wRows.length) {
                        row = wRows[ewIdx];
                        row.dataset.ewKey = ENTWARE_CARD_ID;
                    }
                    break;
                }
            }
        }

        // Strategy 3: duplicate header-text detection (stub template duplicates another card)
        if (!row) {
            var allDialogRows2 = [].slice.call(
                dialogWrapper.querySelectorAll('.cdk-drag.ndw-drag-panel__row:not(.cdk-drag-placeholder):not(.cdk-drag-preview)')
            );
            var textCounts2 = {};
            for (var dri2 = 0; dri2 < allDialogRows2.length; dri2++) {
                var h2 = allDialogRows2[dri2].querySelector('.dashboard-card__header-text');
                if (!h2) continue;
                var t2 = h2.textContent.trim();
                if (!textCounts2[t2]) textCounts2[t2] = [];
                textCounts2[t2].push(allDialogRows2[dri2]);
            }
            for (var tk2 in textCounts2) {
                if (textCounts2[tk2].length > 1) {
                    row = textCounts2[tk2][textCounts2[tk2].length - 1];
                    row.dataset.ewKey = ENTWARE_CARD_ID;
                    break;
                }
            }
        }
        if (!row) return;

        // Fix header text (Angular fallback renders "Internet" or other stock card)
        var heading = row.querySelector('.dashboard-card__header-text');
        if (heading && heading.textContent !== 'ENTWARE EXTRAS') {
            heading.textContent = 'ENTWARE EXTRAS';
        }

        // Fix toggle aria-label (Angular binds to ENTWARE_EXTRAS from order,
        // but renders INTERNET label from stub template)
        var input = row.querySelector('input[role="switch"]');
        if (input && input.getAttribute('aria-label') !== ENTWARE_CARD_ID) {
            input.setAttribute('aria-label', ENTWARE_CARD_ID);
        }

        // Ensure patched classes are present
        if (!row.classList.contains('entware-dialog-patched')) {
            row.classList.add('entware-dialog-patched', 'entware-dialog-row');
        }
    }

    // ── Inject dashboard card CSS ────────────────────────────────────────────

    /**
     * Inject external CSS stylesheets for dashboard card layout (once).
     * Loads common.css (shared styles) and inject.css (stock page styles)
     * via <link> elements instead of inline <style>.
     */
    function injectDashStyles() {
        if (document.getElementById('entware-dash-styles')) return;
        var marker = document.createElement('meta');
        marker.id = 'entware-dash-styles';
        document.head.appendChild(marker);
        ['common.css', 'inject.css'].forEach(function(file) {
            var link = document.createElement('link');
            link.rel = 'stylesheet';
            link.href = '/custom/' + file;
            document.head.appendChild(link);
        });
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


    // ── Dashboard card injection (reconciler-driven) ─────────────────────────

    /**
     * Trigger reconciler to patch Angular-created ENTWARE_EXTRAS row.
     * All CDK row management removed — reconciler finds row by order index.
     */
    function injectDashboardCard() {
        dashboardPending = false;
        ewScheduleReconcile('injectDashboardCard');
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
        var card = document.querySelector('.ew-dash-card');
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
                .then(function(data) {
                    applyServiceData(svc, data);
                    // Remove skeleton shimmer after first successful fetch
                    var content = document.getElementById('entware-dash-content');
                    if (content && content.classList.contains('ew-loading')) {
                        content.classList.remove('ew-loading');
                    }
                })
                .catch(function() {
                    var chip = document.querySelector('#ew-dash-' + svc.id + ' .ew-chip');
                    if (chip) {
                        chip.className = 'ew-chip ew-chip--error';
                        chip.innerHTML = '<span class="ew-chip__dot"></span> ERROR';
                    }
                    // Also remove shimmer on error
                    var content = document.getElementById('entware-dash-content');
                    if (content && content.classList.contains('ew-loading')) {
                        content.classList.remove('ew-loading');
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
        injectDashStyles();
        setupRestore();
        setupCardsPositionDialog();
        ewScheduleReconcile('after-sidebar');
        return true;
    }

    // ── Drag lifecycle — suppress reconcile during active drag ────────
    document.addEventListener('pointerdown', function(e) {
        if (e.target.closest('.cdk-drag.ndw-drag-panel__row')) {
            ewInDrag = true;
        }
    }, true);

    document.addEventListener('pointerup', function() {
        if (ewInDrag) {
            ewInDrag = false;
            ewScheduleReconcile('pointerup');
        }
    }, true);

    document.addEventListener('drop', function() {
        ewInDrag = false;
        ewScheduleReconcile('drop');
    }, true);

    // ── Single MutationObserver — sidebar + reconcile ─────────────────
    var observer = new MutationObserver(function() {
        // Sidebar re-injection
        if (!document.querySelector('.entware-menu-section')) {
            injected = false;
        }
        if (!injected) {
            tryInject();
        }
        // Dashboard reconcile (coalesced via ewScheduled flag)
        ewScheduleReconcile('mutation');
    });
    observer.observe(document.documentElement, { childList: true, subtree: true });

    // ── Route change watcher ─────────────────────────────────────────
    var lastPath = window.location.pathname;
    setInterval(function() {
        var currentPath = window.location.pathname;

        // Re-inject sidebar if Angular removed it
        if (!document.querySelector('.entware-menu-section')) {
            injected = false;
            tryInject();
        }

        // Reset dashboard state on route change
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
            // Clear our markers — let Angular manage its own rows
            var marked = document.querySelectorAll('[' + EW_ATTR + ']');
            for (var i = 0; i < marked.length; i++) {
                ewUnpatchRow(marked[i]);
            }
            // Trigger reconcile for new route
            if (currentPath === '/dashboard') {
                ewScheduleReconcile('route-change');
            }
        }
    }, 2000);
})();
