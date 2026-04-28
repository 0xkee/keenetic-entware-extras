// inject.js — Keenetic NDMS WebUI sidebar + dashboard integration for Entware extras.
// Injected via nginx sub_filter into every proxied Keenetic page.
// Uses stock Keenetic DOM classes (dashboard-card, ndw-status, ndw-router-link).
// Reconciler model: nginx patches Angular bundle (set order + getTemplate);
// this script reconciles Angular-created rows by order index from __ewLastOrder.
(function() {
    'use strict';

    var __cfg = window.__ewConfig || {};

    var CUSTOM_ITEMS = [
        { id: 'dashboard',          label: 'Dashboard',    url: '/custom/' },
        { id: 'geo-split',          label: 'Geo Split',    url: '/custom/#geo-split' },
        { id: 'smartdns',           label: 'SmartDNS Config', url: '/custom/#smartdns' },
        { id: 'smartdns-redirect',  label: 'DNS Redirect', url: '/custom/#smartdns-redirect' },
        { id: 'webui',              label: 'WebUI',        url: '/custom/#webui' },
    ];

    var SERVICE_APIS = [
        { id: 'geo-split',         label: 'Geo-Split',    desc: 'Policy-based geographic split routing',     url: '/custom/#geo-split',         api: '/api/geo-split/status' },
        { id: 'smartdns',          label: 'SmartDNS Config', desc: 'RU zone DNS splitting (.ru/.рф/.su)',        url: '/custom/#smartdns',           api: '/api/smartdns/status' },
        { id: 'smartdns-redirect', label: 'DNS Redirect', desc: 'Transparent DNS redirect for local networks', url: '/custom/#smartdns-redirect',  api: '/api/smartdns-redirect/status' },
        { id: 'webui',             label: 'WebUI',        desc: 'Entware Extras web dashboard',               url: '/custom/#webui',              api: '/api/webui/status' },
    ];

    var DASH_POLL_INTERVAL = (__cfg.pollInterval > 0) ? __cfg.pollInterval : 30000;
    var DETAILS_SKIP_KEYS = { uptime: 1, version: 1, pid: 1, background: 1 };
    /** Detail keys whose numeric values are seconds — formatted via formatUptimeStock() and live-ticked. */
    var TIMER_KEYS = { subnet_freshness: 1, domain_freshness: 1 };

    var injected = false;
    var dashboardInjected = false;
    var activeItem = null;
    var insertingIframe = false;
    var dashboardTimer = null;
    var geoFastPollTimer = null;
    var GEO_FAST_POLL = 1000;  // 1s when background update is running
    var uptimeBaselines = {};  // { 'geo-split': { seconds: 12345, timestamp: Date.now() }, ... }
    var freshnessBaselines = {};  // { 'subnet_freshness': {seconds, timestamp}, 'domain_freshness': ... }
    var uptimeTickTimer = null;

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
                startUptimeTicker();
            }
        }
    }

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
                .then(function() { startGeoFastPolling(); })
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
        SERVICE_APIS.forEach(function(svc) {
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
                // Preserve chip prefix: "DEFAULT MODE" for caution (disabled service), "RUNNING" otherwise
                var chipPrefix = chip.classList.contains('ew-chip--caution') && chip.textContent.indexOf('DEFAULT') !== -1 ? 'DEFAULT MODE' : 'RUNNING';
                chip.innerHTML = '<span class="ew-chip__dot"></span> ' + chipPrefix + ' ' + formatUptimeStock(currentSeconds);
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
        if (geoFastPollTimer) {
            clearInterval(geoFastPollTimer);
            geoFastPollTimer = null;
        }
        stopUptimeTicker();
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
            } else if (val.indexOf(' ') !== -1 && val.indexOf(':') !== -1 && !TIMER_KEYS[key]) {
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
        // Services with "enabled" field: running but disabled → "default mode" (yellow)
        if (data.running && typeof data.enabled === 'boolean' && !data.enabled) {
            state = 'caution';
        }
        var text = data.running ? 'RUNNING' : 'STOPPED';
        if (data.running && typeof data.enabled === 'boolean' && !data.enabled) {
            text = 'DEFAULT MODE';
        }
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
        // Config guard: skip sidebar injection when disabled
        if (!__cfg.injectSidebar) {
            injected = true;
            injectDashStyles();
            ewScheduleReconcile('no-sidebar');
            return true;
        }
        var container = document.querySelector('ndw-menu .menu__contents');
        if (!container) return false;
        container.appendChild(buildSection());
        injected = true;
        injectDashStyles();
        setupRestore();
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
            // Delay reconcile to let CDK drop animation finish (~250ms).
            // Immediate reconcile would find stale/transitional DOM.
            setTimeout(function() {
                ewScheduleReconcile('pointerup-delayed');
            }, 300);
        }
    }, true);

    document.addEventListener('drop', function() {
        ewInDrag = false;
        ewScheduleReconcile('drop');
    }, true);

    // ── Single MutationObserver — sidebar + reconcile ─────────────────
    var observer = new MutationObserver(function() {
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
            dashboardInjected = false;
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
