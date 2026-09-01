// inject.js — Keenetic NDMS WebUI sidebar + dashboard integration for Entware extras.
// Injected via nginx sub_filter into every proxied Keenetic page.
// Uses stock Keenetic DOM classes (dashboard-card, ndw-status, ndw-router-link).
// Reconciler model: nginx patches Angular bundle (set order + getTemplate);
// this script reconciles Angular-created rows by order index from __ewLastOrder.
// Dashboard card rendering delegated to inject-dashboard.js (EW._dash namespace).
(function() {
    'use strict';
    try {

    // ═══════════════════════════════════════════════════════════════════
    // §1. CONFIGURATION & STATE
    // ═══════════════════════════════════════════════════════════════════

    var __cfg = window.__ewConfig || {};

    var CUSTOM_ITEMS = [
        { id: 'dashboard',          label: 'Dashboard',    url: '/custom/' },
        { id: 'geo-split',          label: 'Geo Split',    url: '/custom/#geo-split' },
        { id: 'smartdns',           label: 'SmartDNS Geo-Config', url: '/custom/#smartdns' },
        { id: 'smartdns-redirect',  label: 'DNS Redirect', url: '/custom/#smartdns-redirect' },
        { id: 'webui',              label: 'WebUI',        url: '/custom/#webui' },
    ];

    var DASH_POLL_INTERVAL = (__cfg.pollInterval > 0) ? __cfg.pollInterval : 30000;

    var injected = false;
    var activeItem = null;
    var insertingIframe = false;
    var ROUTE_POLL_INTERVAL = 2000;   // Route change detection interval (ms)
    var DRAG_SETTLE_DELAY = 300;      // Delay after drag to let CDK animation finish (ms)
    var RESTORE_OBSERVER_DELAY = 3000; // Delay before setting up content restore observer (ms)
    var IFRAME_INSERT_GUARD = 100;    // Guard delay after iframe insertion (ms)

    /** Ticker for live uptime/freshness counters — updates dashboard chip DOM. */
    var ticker = EW.createTicker(function(id, currentSeconds) {
        var row = document.getElementById('ew-dash-' + id);
        if (!row) return;
        var chip = row.querySelector('.ew-chip');
        if (!chip) return;
        if (!chip.classList.contains('ew-chip--running') && !chip.classList.contains('ew-chip--caution')) return;
        var chipPrefix = chip.classList.contains('ew-chip--caution') && chip.textContent.indexOf('DEFAULT') !== -1 ? 'DEFAULT MODE' : 'RUNNING';
        chip.innerHTML = '<span class="ew-chip__dot"></span> ' + chipPrefix + ' ' + EW.formatUptimeStock(currentSeconds);
    });

    /** Fast poller for geo-split during background updates. */
    var geoPoller = EW.createPoller(
        function() { EW._dash.fetchSingleServiceStatus('geo-split'); },
        EW._dash.TOGGLE_FAST_POLL,
        function() {
            var card = document.querySelector('.ew-dash-card');
            if (card) {
                card.querySelectorAll('.ew-update-btn--spinning').forEach(function(btn) {
                    btn.classList.remove('ew-update-btn--spinning');
                    btn.disabled = false;
                });
            }
        }
    );

    /** Per-service toggle poller — fast-poll until state settles or timeout. */
    var togglePoller = EW.createTogglePoller({ interval: EW._dash.TOGGLE_FAST_POLL });

    // Initialize dashboard module with shared pollers and callbacks
    EW._dash.init({
        ticker: ticker,
        geoPoller: geoPoller,
        togglePoller: togglePoller,
        showInContent: showInContent,
        pollInterval: DASH_POLL_INTERVAL
    });

    // ═══════════════════════════════════════════════════════════════════
    // §2. RECONCILER — Angular CDK row patching
    //     Finds ENTWARE_EXTRAS in __ewLastOrder, patches empty CDK row.
    // ═══════════════════════════════════════════════════════════════════
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

    /** Find the dashboard drag panel root. */
    function ewFindPanelRoot() {
        return document.querySelector('ndw-drag-panel');
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

        // DOM consistency: row count must match order column length.
        // During CDK drag animation, DOM may have stale/transitional rows.
        if (rows.length !== order[entwareCol].length) {
            ewScheduleReconcile('dom-inconsistent');
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

        // ── Card visibility: respect cardStates toggle from Cards Position dialog.
        // Angular applies ndw-drag-panel__row--hidden when cardStates.ENTWARE_EXTRAS = false.
        // We must honour this — unpatch our content and stop polling.
        if (targetRow.classList.contains('ndw-drag-panel__row--hidden')) {
            if (targetRow.hasAttribute(EW_ATTR)) {
                ewUnpatchRow(targetRow);
            }
            EW._dash.stopPolling();
            return;
        }

        // Patch the target row
        var patched = ewPatchDashboardRow(targetRow);

        if (patched) {
            // Ensure dashboard polling is started
            if (!EW._dash.getDashboardInjected() && window.location.pathname === '/dashboard') {
                EW._dash.setDashboardInjected(true);
                EW.loadIfaceMap().then(function() {
                    EW._dash.fetchDashboardStatuses();
                });
                if (!EW._dash.getDashboardTimer()) {
                    EW._dash.setDashboardTimer(setInterval(EW._dash.fetchDashboardStatuses, DASH_POLL_INTERVAL));
                }
                ticker.start();
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // §3. DASHBOARD CARD — DOM construction
    //     Creates/removes Entware card inside Angular CDK rows.
    // ═══════════════════════════════════════════════════════════════════

    /**
     * Remove our injected content from a CDK row.
     * With sub_filter #9 (null ngTemplateOutlet), the row is empty —
     * just remove our card DOM. Angular CDK wrapper stays untouched.
     */
    function ewUnpatchRow(row) {
        row.removeAttribute(EW_ATTR);
        row.classList.remove('ew-row');
        var card = row.querySelector('.ew-dash-card');
        if (card) card.remove();
    }

    /**
     * Patch an Angular-created EMPTY CDK row — create full card DOM inside.
     * Sub_filter #9 renders ngTemplateOutlet=null → inner div is empty.
     * We create the complete dashboard-card structure with header + content.
     * Does NOT create/move .cdk-drag elements. Idempotent.
     */
    function ewPatchDashboardRow(row) {
        if (!row || !row.isConnected) return false;

        // Mark the row
        row.setAttribute(EW_ATTR, 'entware-extras');
        row.classList.add('ew-row');

        // Already patched — nothing to do (idempotent)
        if (row.querySelector('.ew-dash-card') &&
            row.querySelector('#entware-dash-content')) return true;

        // Find Angular's inner div (ngTemplateOutlet container)
        var inner = row.querySelector(':scope > div');
        if (!inner) return false;

        // Create full card structure inside empty Angular container
        var card = document.createElement('div');
        card.className = 'dashboard-card ew-dash-card';

        // Header — stock Keenetic structure
        var header = document.createElement('div');
        header.className = 'dashboard-card__header';
        header.innerHTML =
            '<div class="dashboard-card__header-link" style="cursor:pointer">' +
                '<span class="text-card-heading" role="heading" aria-level="2">ENTWARE EXTRAS</span>' +
            '</div>' +
            '<div class="dashboard-card__header-buttons">' +
                '<ndw-svg-icon class="ndw-drag-handle dashboard-card__drag-icon">' +
                    '<svg class="ndw-svg-icon" style="width:20px;height:20px;fill:currentColor">' +
                        '<use href="/assets/sprite/sprite.svg#drag-and-drop"></use>' +
                    '</svg>' +
                '</ndw-svg-icon>' +
            '</div>';

        // Content area — populated by EW._dash.fetchDashboardStatuses()
        var content = document.createElement('div');
        content.className = 'dashboard-card__content';
        content.appendChild(EW._dash.buildEntwareDashboardContent());

        card.appendChild(header);
        card.appendChild(content);
        inner.appendChild(card);

        var headerLink = header.querySelector('.dashboard-card__header-link');
        if (headerLink) {
            headerLink.addEventListener('click', function(e) {
                e.preventDefault();
                showInContent({ id: 'dashboard', url: '/custom/' });
            });
        }

        // Event delegation for update buttons (geo-split refresh, cache flush)
        card.addEventListener('click', function(e) {
            var btn = e.target.closest('.ew-update-btn');
            if (!btn || btn.disabled) return;
            var actionUrl = btn.getAttribute('data-action');
            btn.classList.add('ew-update-btn--spinning');
            btn.disabled = true;
            fetch(actionUrl, { method: 'POST' })
                .then(function(r) { return r.json(); })
                .then(function() {
                    btn.classList.remove('ew-update-btn--spinning');
                    btn.disabled = false;
                    var _label = actionUrl.indexOf('flush') !== -1 ? '\u2713 Flushed ' : '\u2713 Updating\u2026 ';
                    var _p = btn.parentNode;
                    if (_p) { for (var _n = _p.firstChild; _n; _n = _n.nextSibling) {
                        if (_n !== btn && (_n.nodeType === 3 || _n.nodeType === 1)) { _n.textContent = _label; break; }
                    }}
                    if (actionUrl.indexOf('geo-split') !== -1) {
                        geoPoller.start();
                    } else {
                        EW._dash.fetchDashboardStatuses();
                    }
                })
                .catch(function() {
                    btn.classList.remove('ew-update-btn--spinning');
                    btn.disabled = false;
                });
        });

        return true;
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

    // ═══════════════════════════════════════════════════════════════════
    // §4. SIDEBAR — menu section + iframe navigation
    //     Sidebar DOM, iframe loading, restore on stock menu click.
    // ═══════════════════════════════════════════════════════════════════

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
     * Uses pushState (same URL) for browser Back support. The popstate handler
     * only removes the iframe on Back (exit-only) — does NOT re-show on Forward.
     * This avoids conflicts with Angular's router which ignores same-URL popstate.
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

        // Push history entry for browser Back button (same URL — Angular ignores same-URL popstate)
        history.pushState({ __ew: item.id }, '');

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

        setTimeout(function() { insertingIframe = false; }, IFRAME_INSERT_GUARD);
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

    /**
     * Remove the custom iframe, restore hidden Angular content, reset menu state.
     * Restores display of children hidden by showInContent().
     */
    function removeIframe() {
        activeItem = null;
        document.querySelectorAll('.entware-menu-section .page-link__link').forEach(function(el) {
            el.classList.remove('page-link__link--active');
        });
        var iframe = document.getElementById('entware-iframe');
        if (iframe) {
            var content = iframe.parentElement;
            iframe.remove();
            // Restore Angular children that were hidden by showInContent()
            if (content) {
                for (var i = 0; i < content.children.length; i++) {
                    var child = content.children[i];
                    if ('entwareHidden' in child.dataset) {
                        child.style.display = child.dataset.entwareHidden || '';
                        delete child.dataset.entwareHidden;
                    }
                }
            }
        }
    }

    // ── Restore on stock menu click + Angular navigation ─────────────────────

    /**
     * Set up listeners to remove iframe when user navigates via stock menu.
     * No popstate handler here — Angular owns the browser history.
     * Back/forward within the custom page is iframe-internal (app.js).
     */
    function setupRestore() {
        // Capture-phase click: detect stock sidebar navigation
        document.addEventListener('click', function(e) {
            var item = e.target.closest('.menu__item, .page-link__link');
            if (item && !item.closest('.entware-menu-section') && activeItem) {
                removeIframe();
            }
        }, true);

        // Browser Back button: exit-only popstate handler.
        // When user presses Back while custom page is shown, we remove iframe.
        // We do NOT re-show iframe on Forward — that avoids Angular router conflicts.
        // Angular also receives this popstate but ignores it (same-URL = no navigation).
        window.addEventListener('popstate', function(e) {
            if (activeItem && !(e.state && e.state.__ew)) {
                removeIframe();
            }
        });

        // MutationObserver: catch Angular's own navigation (route change replaces content)
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
        }, RESTORE_OBSERVER_DELAY);
    }

    // ═══════════════════════════════════════════════════════════════════
    // §5. BOOTSTRAP — sidebar injection + tryInject
    // ═══════════════════════════════════════════════════════════════════

    /**
     * Try injecting sidebar section into ndw-menu.
     * @returns {boolean} true if injected
     */
    function tryInject() {
        if (injected) return true;
        // Config guard: skip sidebar injection when disabled
        if (!__cfg.injectSidebar) {
            injected = true;
            injectDashStyles();
            setupRestore(); // Always needed: showInContent() is reachable via dashboard card click
            ewScheduleReconcile('no-sidebar');
            return true;
        }
        var container = document.querySelector('ndw-menu .menu__contents');
        if (!container) return false;
        // DOM-level dedupe: section already present (Angular kept it)
        if (container.querySelector('.entware-menu-section')) {
            injected = true;
            return true;
        }
        container.appendChild(buildSection());
        injected = true;
        injectDashStyles();
        setupRestore();
        ewScheduleReconcile('after-sidebar');
        return true;
    }

    // ═══════════════════════════════════════════════════════════════════
    // §6. EVENT HANDLERS & INITIALIZATION
    //     Drag lifecycle, MutationObserver, route change watcher.
    // ═══════════════════════════════════════════════════════════════════
    document.addEventListener('pointerdown', function(e) {
        try {
        if (e.target.closest('.cdk-drag.ndw-drag-panel__row')) {
            ewInDrag = true;
        }
        } catch (_) {}
    }, true);

    document.addEventListener('pointerup', function() {
        try {
        if (ewInDrag) {
            ewInDrag = false;
            // Delay reconcile to let CDK drop animation finish (~250ms).
            // Immediate reconcile would find stale/transitional DOM.
            setTimeout(function() {
                ewScheduleReconcile('pointerup-delayed');
            }, DRAG_SETTLE_DELAY);
        }
        } catch (_) {}
    }, true);

    document.addEventListener('drop', function() {
        try {
        ewInDrag = false;
        ewScheduleReconcile('drop');
        } catch (_) {}
    }, true);

    // ── Single MutationObserver — sidebar + reconcile ─────────────────
    var observer = new MutationObserver(function() {
        try {
        // Sidebar re-injection (only when enabled)
        if (__cfg.injectSidebar) {
            if (!document.querySelector('.entware-menu-section')) {
                injected = false;
            }
        }
        if (!injected) {
            tryInject();
        }
        // Dashboard reconcile (coalesced via ewScheduled flag)
        ewScheduleReconcile('mutation');
        } catch (_) {}
    });
    observer.observe(document.documentElement, {
        childList: true, subtree: true,
        attributes: true, attributeFilter: ['class']
    });

    // ── Route change watcher ─────────────────────────────────────────
    var lastPath = window.location.pathname;
    setInterval(function() {
        var currentPath = window.location.pathname;

        // Re-inject sidebar if Angular removed it (only when enabled)
        if (__cfg.injectSidebar && !document.querySelector('.entware-menu-section')) {
            injected = false;
            tryInject();
        }

        // Reset dashboard state on route change
        if (currentPath !== lastPath) {
            lastPath = currentPath;
            // Safety net: remove iframe if Angular navigated while it was showing
            if (activeItem) removeIframe();
            EW._dash.stopPolling();
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
    }, ROUTE_POLL_INTERVAL);

    } catch (e) {
        // Error boundary: never break stock Keenetic UI
        console.error('[Entware Extras] inject.js failed:', e);
    }
})();
