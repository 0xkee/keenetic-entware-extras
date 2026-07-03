// inject.js — Keenetic NDMS WebUI sidebar + dashboard integration for Entware extras.
// Injected via nginx sub_filter into every proxied Keenetic page.
// Uses stock Keenetic DOM classes (dashboard-card, ndw-status, ndw-router-link).
// Reconciler model: nginx patches Angular bundle (set order + getTemplate);
// this script reconciles Angular-created rows by order index from __ewLastOrder.
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
    var DETAILS_SKIP_KEYS = { uptime: 1, version: 1, pid: 1, background: 1, cache: 1 };
    var DASH_SKELETON_COUNTS = { 'geo-split': 16, 'smartdns': 9, 'smartdns-redirect': 8, 'webui': 8 };

    var injected = false;
    var dashboardInjected = false;
    var activeItem = null;
    var insertingIframe = false;
    var dashboardTimer = null;
    var TOGGLE_FAST_POLL = 1000;      // 1s fast polling after toggle / background update (ms)
    var TOGGLE_POLL_TIMEOUT = 10000;  // Max fast-poll duration after toggle (ms)
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
        function() { fetchSingleServiceStatus('geo-split'); },
        TOGGLE_FAST_POLL,
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

    /** Per-service toggle pollers — fast-poll until state settles or timeout. */
    var togglePollers = {};

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
            ewStopDashboardPolling();
            return;
        }

        // Patch the target row
        var patched = ewPatchDashboardRow(targetRow);

        if (patched) {
            // Ensure dashboard polling is started
            if (!dashboardInjected && window.location.pathname === '/dashboard') {
                dashboardInjected = true;
                fetchDashboardStatuses();
                if (!dashboardTimer) {
                    dashboardTimer = setInterval(fetchDashboardStatuses, DASH_POLL_INTERVAL);
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
            '<div class="dashboard-card__header-link">' +
                '<span class="text-card-heading" role="heading" aria-level="2" style="cursor:default">ENTWARE EXTRAS</span>' +
            '</div>' +
            '<div class="dashboard-card__header-buttons">' +
                '<ndw-svg-icon class="ndw-drag-handle dashboard-card__drag-icon">' +
                    '<svg class="ndw-svg-icon" style="width:20px;height:20px;fill:currentColor">' +
                        '<use href="/assets/sprite/sprite.svg#drag-and-drop"></use>' +
                    '</svg>' +
                '</ndw-svg-icon>' +
            '</div>';

        // Content area — populated by fetchDashboardStatuses()
        var content = document.createElement('div');
        content.className = 'dashboard-card__content';
        content.appendChild(buildEntwareDashboardContent());

        card.appendChild(header);
        card.appendChild(content);
        inner.appendChild(card);

        // Event delegation for update buttons (geo-split subnet/domain refresh)
        card.addEventListener('click', function(e) {
            var btn = e.target.closest('.ew-update-btn');
            if (!btn || btn.disabled) return;
            var actionUrl = btn.getAttribute('data-action');
            btn.classList.add('ew-update-btn--spinning');
            btn.disabled = true;
            fetch(actionUrl, { method: 'POST' })
                .then(function(r) { return r.json(); })
                .then(function() { geoPoller.start(); })
                .catch(function() {
                    btn.classList.remove('ew-update-btn--spinning');
                    btn.disabled = false;
                });
        });

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
        EW.SERVICE_APIS.forEach(function(svc) {
            wrapper.appendChild(buildServiceRow(svc));
        });
        return wrapper;
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
    // §5. STATUS & POLLING — data fetching, details, live updates
    //     Service rows, status parsing, fast polling, fetch logic.
    // ═══════════════════════════════════════════════════════════════════

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
                var targetRunning = cb.checked;
                cb.disabled = true;
                bar.style.opacity = '0.5';
                fetch('/api/' + svc.id + '/' + action, { method: 'POST' })
                    .then(function(r) { return r.json(); })
                    .then(function(data) {
                        cb.disabled = false;
                        bar.style.opacity = '';
                        if (!data.ok) {
                            cb.checked = !cb.checked;
                        } else {
                            startTogglePoller(svc.id, targetRunning);
                        }
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

        // Pre-fill skeleton placeholders (replaced on first fetch)
        var skelCount = DASH_SKELETON_COUNTS[svc.id] || 9;
        var skelHtml = '';
        for (var si = 0; si < skelCount; si++) {
            skelHtml += '<div class="ew-detail-item"><div class="ew-skeleton ew-skeleton--short"></div><div class="ew-skeleton ew-skeleton--medium" style="margin-top:4px"></div></div>';
        }
        details.innerHTML = skelHtml;

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
     * Stop all dashboard polling (status, geo fast-poll, uptime ticker).
     * Called when the card is hidden via Cards Position toggle.
     * Resets dashboardInjected so polling restarts if card becomes visible again.
     */
    function ewStopDashboardPolling() {
        dashboardInjected = false;
        if (dashboardTimer) {
            clearInterval(dashboardTimer);
            dashboardTimer = null;
        }
        geoPoller.stop();
        stopAllTogglePollers();
        ticker.stop();
    }

    /**
     * Render details grid HTML from data.details object.
     * Uses EW.parseDetails() for parsing, wraps entries in grid cells.
     * @param {Object} details - data.details from status API
     * @param {boolean} isRunning - whether the service is running
     * @param {Object} [checks] - checks map from backend (ok/warn/fail per key)
     * @returns {string}
     */
    function renderDetailsGrid(details, isRunning, checks, dnsServerChecks, svcId) {
        if (!details) return '';
        var entries = EW.parseDetails(details, { skipKeys: DETAILS_SKIP_KEYS, isRunning: isRunning, checks: checks, serviceId: svcId });
        var html = '';
        for (var i = 0; i < entries.length; i++) {
            var e = entries[i];
            if (e.isSpacer) { html += '<div class="ew-detail-item"></div>'; continue; }
            var valStyle = e.isError ? ' style="color:var(--error,#f44336)"'
                : e.isWarning ? ' style="color:var(--status-caution-text,#ffbb57)"' : '';
            var val = e.value;
            if (e.lines) {
                val = e.lines.map(function(l) {
                    return l.isError ? '<span style="color:var(--error,#f44336)">' + l.text + '</span>' : l.text;
                }).join('<br>');
            } else if (/_provider$/.test(e.key) && dnsServerChecks && dnsServerChecks.length) {
                var provArr = val.split(' ').map(function(prov) {
                    var chk = null;
                    for (var ci = 0; ci < dnsServerChecks.length; ci++) {
                        if (dnsServerChecks[ci].provider === prov) { chk = dnsServerChecks[ci]; break; }
                    }
                    if (chk) {
                        var cIcon = chk.ok ? '\u2713' : '\u2717';
                        var cCls = chk.ok ? 'ew-bool-icon--ok' : 'ew-bool-icon--fail';
                        return '<span class="ew-bool-icon ' + cCls + '">' + cIcon + '</span> ' +
                            '<a class="ew-dns-link" href="https://' + chk.host + '" target="_blank" rel="noopener" data-tooltip="' + chk.host + '">' + chk.provider + '</a>';
                    }
                    return prov;
                });
                val = '<div class="ew-dns-line">' + provArr.join('</div><div class="ew-dns-line">') + '</div>';
            } else if (val.indexOf(' ') !== -1 && !e.isTimer && (val.indexOf(':') !== -1 || /_provider$/.test(e.key))) {
                val = val.split(' ').join('<br>');
            }
            var updateBtn = '';
            if (e.updateAction) {
                updateBtn = ' <button class="ew-update-btn" data-action="' + e.updateAction + '" data-tooltip="Force Reload">' +
                    '<svg class="ndw-svg-icon svg-restart-dims" style="width:14px;height:14px;fill:currentColor"><use href="/assets/sprite/sprite.svg#restart"></use></svg></button>';
            }
            var dataAttr = e.freshnessKey ? ' data-freshness-key="' + e.freshnessKey + '"' : '';
            html += '<div class="ew-detail-item">' +
                '<div class="ew-detail-label">' + e.label + '</div>' +
                '<div class="ew-detail-value"' + valStyle + dataAttr + '>' + val + updateBtn + '</div></div>';
        }
        return html;
    }

    /**
     * Fetch status for a single service and update its row.
     * Used by fast polling (geo-split background updates, toggle polling).
     * @param {string} serviceId - SERVICE_APIS entry id
     */
    function fetchSingleServiceStatus(serviceId) {
        var svc = null;
        for (var i = 0; i < EW.SERVICE_APIS.length; i++) {
            if (EW.SERVICE_APIS[i].id === serviceId) { svc = EW.SERVICE_APIS[i]; break; }
        }
        if (!svc) return;
        fetch(svc.api, { cache: 'no-store' })
            .then(function(r) { return r.json(); })
            .then(function(data) { applyServiceData(svc, data); })
            .catch(function() {});
    }

    /**
     * Start fast polling for a service after toggle until state settles.
     * Polls every TOGGLE_FAST_POLL ms; stops when running matches target or TOGGLE_POLL_TIMEOUT.
     * @param {string} serviceId - SERVICE_APIS entry id
     * @param {boolean} targetRunning - expected state after toggle
     */
    function startTogglePoller(serviceId, targetRunning) {
        stopTogglePoller(serviceId);
        var svc = null;
        for (var i = 0; i < EW.SERVICE_APIS.length; i++) {
            if (EW.SERVICE_APIS[i].id === serviceId) { svc = EW.SERVICE_APIS[i]; break; }
        }
        if (!svc) return;

        var startTime = Date.now();
        var timerId = setInterval(function() {
            // Timeout guard
            if (Date.now() - startTime > TOGGLE_POLL_TIMEOUT) {
                stopTogglePoller(serviceId);
                return;
            }
            fetch(svc.api, { cache: 'no-store' })
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    applyServiceData(svc, data);
                    // Stop when state matches target
                    if (data.running === targetRunning) {
                        stopTogglePoller(serviceId);
                    }
                })
                .catch(function() {
                    stopTogglePoller(serviceId);
                });
        }, TOGGLE_FAST_POLL);

        togglePollers[serviceId] = timerId;
    }

    /**
     * Stop fast polling for a specific service.
     * @param {string} serviceId
     */
    function stopTogglePoller(serviceId) {
        if (togglePollers[serviceId]) {
            clearInterval(togglePollers[serviceId]);
            delete togglePollers[serviceId];
        }
    }

    /**
     * Stop all active toggle pollers (used on route change or card hide).
     */
    function stopAllTogglePollers() {
        for (var id in togglePollers) {
            clearInterval(togglePollers[id]);
        }
        togglePollers = {};
    }

    /**
     * Check if any detail field is boolean false (fallback when checks absent).
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
     * Determine fail/warn from checks map.
     * @param {Object} checks - checks map {key: "ok"|"warn"|"fail"}
     * @returns {{hasFail: boolean, hasWarn: boolean}}
     */
    function checksSummary(checks) {
        var hasFail = false, hasWarn = false;
        if (!checks) return { hasFail: false, hasWarn: false };
        var keys = Object.keys(checks);
        for (var i = 0; i < keys.length; i++) {
            if (checks[keys[i]] === 'fail') hasFail = true;
            else if (checks[keys[i]] === 'warn') hasWarn = true;
        }
        return { hasFail: hasFail, hasWarn: hasWarn };
    }

    /**
     * Build status chip text from structured data.
     * Returns "caution" state if running but any check is fail/warn.
     * Uses data.checks if available, falls back to detail field === false.
     * @param {Object} data - full API response
     * @returns {{state: string, text: string}}
     */
    function parseServiceStatus(data) {
        // Pending response (cache warming) — signal to not update chip
        if (data.status === "pending" && data.running === undefined) {
            return { state: 'pending', text: '' };
        }
        var state = data.running ? 'running' : 'stopped';
        // Distinguish: service crashed (enabled but not running) vs user disabled
        if (!data.running && !data.error) {
            if (typeof data.enabled === 'boolean' && data.enabled) {
                state = 'error';  // Should be running but isn't → red
            }
            // else: stopped (gray) — default from line above
        }
        // Handle error/unknown response from api-router
        if (!data.running && data.error) {
            state = 'stale';  // Unknown state, not a real "error"
        }
        // Determine chip state from checks or fallback
        if (data.running) {
            if (data.checks) {
                var cs = checksSummary(data.checks);
                if (cs.hasFail || cs.hasWarn) {
                    state = 'caution';
                }
            } else if (hasFailField(data.details)) {
                state = 'caution';
            }
        }
        // Services with "enabled" field: running but disabled → grey "Disabled"
        if (data.running && typeof data.enabled === 'boolean' && !data.enabled) {
            state = 'stopped';
        }
        var text = data.running ? 'RUNNING' : 'STOPPED';
        if (data.running && typeof data.enabled === 'boolean' && !data.enabled) {
            text = 'DISABLED';
        }
        if (data.running && !(typeof data.enabled === 'boolean' && !data.enabled) && data.details && data.details.uptime) {
            text += ' ' + EW.formatUptimeStock(data.details.uptime);
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
        // Pending: don't update chip (data is not real yet)
        if (s.state === 'pending') return;

        // Update toggle: services with "enabled" field use it; others use "running"
        if (toggle) {
            toggle.checked = (typeof data.enabled === 'boolean') ? data.enabled : data.running;
        }

        // Update chip
        if (chip) {
            chip.className = 'ew-chip ew-chip--' + s.state;
            chip.innerHTML = '<span class="ew-chip__dot"></span> ' + s.text;
        }

        // Update expandable details grid
        if (detailsEl) {
            var detailsHtml = renderDetailsGrid(data.details, data.running, data.checks, data.dns_server_checks, svc.id);
            // Insert DNS test results before cache (concise: ✓/✗ domain)
            if (data.dns_tests && data.dns_tests.length) {
                var dnsLines = [];
                for (var di = 0; di < data.dns_tests.length; di++) {
                    var dt = data.dns_tests[di];
                    var dtOk = dt.result && dt.result !== 'FAILED';
                    var dtIcon = dtOk ? '\u2713' : '\u2717';
                    var dtClass = dtOk ? 'ew-bool-icon--ok' : 'ew-bool-icon--fail';
                    dnsLines.push('<span class="ew-bool-icon ' + dtClass + '">' + dtIcon + '</span> ' +
                        '<a class="ew-dns-link" href="https://' + dt.domain + '" target="_blank" rel="noopener">' + dt.domain + '</a>');
                }
                var dnsBlock = '<div class="ew-detail-item">' +
                    '<div class="ew-detail-label">DNS Tests</div>' +
                    '<div class="ew-detail-value">' + dnsLines.join('<br>') + '</div></div>';
                var cacheIdx = detailsHtml.indexOf('ew-detail-label">Cache<');
                if (cacheIdx !== -1) {
                    var insIdx = detailsHtml.lastIndexOf('<div class="ew-detail-item"', cacheIdx);
                    if (insIdx !== -1) {
                        detailsHtml = detailsHtml.substring(0, insIdx) + dnsBlock + detailsHtml.substring(insIdx);
                    } else {
                        detailsHtml += dnsBlock;
                    }
                } else {
                    detailsHtml += dnsBlock;
                }
            }
            detailsEl.innerHTML = detailsHtml;
        }

        // Update uptime baseline
        if (data.running && data.details && data.details.uptime) {
            ticker.setUptimeBaseline(svc.id, data.details.uptime);
        } else {
            ticker.removeUptimeBaseline(svc.id);
        }

        // Update freshness baselines (timer keys)
        if (data.details) {
            for (var tk in EW.TIMER_KEYS) {
                if (data.details[tk]) {
                    ticker.setFreshnessBaseline(tk, data.details[tk]);
                }
            }
        }

        // Check geo-split background for fast polling
        if (svc.id === 'geo-split' && data.details) {
            if (data.details.background === 'running') {
                geoPoller.start();
            } else if (geoPoller.isRunning()) {
                geoPoller.stop();
            }
        }
    }

    /**
     * Fetch service statuses in parallel and update dashboard card rows.
     * Each service is fetched independently for maximum parallelism.
     */
    function fetchDashboardStatuses() {
        EW.SERVICE_APIS.forEach(function(svc) {
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
                    // Stale-while-revalidate: don't overwrite chip if it already has real data.
                    // Only show "stale" if chip is still in initial LOADING state.
                    var chip = document.querySelector('#ew-dash-' + svc.id + ' .ew-chip');
                    if (chip && chip.textContent.indexOf('LOADING') !== -1) {
                        chip.className = 'ew-chip ew-chip--stale';
                        chip.innerHTML = '<span class="ew-chip__dot"></span> NO DATA';
                    }
                    // Remove shimmer on error (first load failed)
                    var content = document.getElementById('entware-dash-content');
                    if (content && content.classList.contains('ew-loading')) {
                        content.classList.remove('ew-loading');
                    }
                });
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    // §6. BOOTSTRAP — sidebar injection + tryInject
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
    // §7. EVENT HANDLERS & INITIALIZATION
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
            dashboardInjected = false;
            if (dashboardTimer) {
                clearInterval(dashboardTimer);
                dashboardTimer = null;
            }
            geoPoller.stop();
            stopAllTogglePollers();
            ticker.stop();
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
