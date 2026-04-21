// inject.js — Keenetic NDMS WebUI sidebar + dashboard integration for Entware extras.
// Injected via nginx sub_filter into every proxied Keenetic page.
// Uses stock Keenetic DOM classes (dashboard-card, ndw-status, ndw-router-link).
(function() {
    'use strict';

    var CUSTOM_ITEMS = [
        { id: 'dashboard',          label: 'Dashboard',    url: '/custom/' },
        { id: 'geo-split',          label: 'Geo Split',    url: '/custom/#geo-split' },
        { id: 'smartdns',           label: 'SmartDNS',     url: '/custom/#smartdns' },
        { id: 'smartdns-redirect',  label: 'DNS Redirect', url: '/custom/#smartdns-redirect' },
    ];

    var SERVICE_APIS = [
        { id: 'geo-split',         label: 'Geo-Split',    desc: 'Policy-based geographic split routing',     url: '/custom/#geo-split',         api: '/api/geo-split/status' },
        { id: 'smartdns',          label: 'SmartDNS',     desc: 'DNS resolver with geographic routing rules', url: '/custom/#smartdns',           api: '/api/smartdns/status' },
        { id: 'smartdns-redirect', label: 'DNS Redirect', desc: 'Transparent DNS redirect for local networks', url: '/custom/#smartdns-redirect',  api: '/api/smartdns-redirect/status' },
    ];

    var DASH_POLL_INTERVAL = 30000;

    var injected = false;
    var dashboardInjected = false;
    var dashboardPending = false;  // guard against multiple setTimeout queues
    var activeItem = null;
    var insertingIframe = false;
    var dashboardTimer = null;

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
            '#entware-dashboard-card{' +
                'display:flex;flex-direction:column;' +
                'border:1px solid var(--dashboard-card-border,#4d545f);' +
                'border-radius:8px;' +
                'background:var(--background,#1b2434);' +
                'box-sizing:border-box;margin-top:16px;}' +
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
            '.ew-dash-row+.ew-dash-row{border-top:1px solid var(--stroke,#4d545f);}' +
            '.ew-dash-info{flex:1;min-width:0;}' +
            '.ew-dash-title{font-size:16px;font-weight:500;color:var(--primary-text,#c2c2c2);' +
                'cursor:pointer;line-height:1.3;}' +
            '.ew-dash-title:hover{text-decoration:underline;}' +
            '.ew-dash-desc{color:var(--text-gray,#949b9f);font-size:13px;margin-top:2px;}' +
            '.ew-dash-meta{color:var(--text-gray,#949b9f);font-size:12px;margin-top:2px;' +
                'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}' +
            /* Toggle switch (cosmetic — no backend yet) */
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
            /* Status chip — stock-like with background */
            '.ew-chip{display:inline-flex;align-items:center;gap:6px;' +
                'padding:4px 12px;border-radius:12px;font-size:12px;font-weight:500;' +
                'text-transform:uppercase;letter-spacing:.5px;margin-top:6px;}' +
            '.ew-chip__dot{width:6px;height:6px;border-radius:50%;flex-shrink:0;}' +
            '.ew-chip--running{background:rgba(125,206,112,.12);color:var(--indicator-online,#7dce70);}' +
            '.ew-chip--running .ew-chip__dot{background:var(--indicator-online,#7dce70);}' +
            '.ew-chip--stopped{background:var(--disabled,#2f3745);color:var(--text-gray,#949b9f);}' +
            '.ew-chip--stopped .ew-chip__dot{background:var(--text-gray,#949b9f);}' +
            '.ew-chip--error{background:rgba(222,61,61,.12);color:var(--error,#de3d3d);}' +
            '.ew-chip--error .ew-chip__dot{background:var(--error,#de3d3d);}' +
            /* Expand button — stock computed: hover bg=border=rgba(105,201,155,.15), active border=#03825a */
            '.ew-expand-btn{' +
                'background:transparent;' +
                'border:1px solid var(--stroke,#4d545f);' +
                'border-radius:4px;' +
                'color:var(--text-gray,#949b9f);' +
                'cursor:pointer;width:32px;height:32px;' +
                'display:flex;align-items:center;justify-content:center;' +
                'flex-shrink:0;align-self:flex-start;padding:0;outline:none;' +
                'transition:border-color .15s,color .15s,background .15s;}' +
            /* Hover: border = bg = same semi-transparent green (stock pattern) */
            '.ew-expand-btn:hover{' +
                'border-color:rgba(105,201,155,.15);' +
                'background:rgba(105,201,155,.15);}' +
            /* Active/expanded: solid green border + same bg */
            '.ew-expand-btn--active,.ew-expand-btn:active{' +
                'border-color:#03825a;' +
                'background:rgba(105,201,155,.15);}' +
            '.ew-expand-btn svg{width:16px;height:16px;stroke:currentColor;fill:none;}' +
            /* Expandable details — stock wan-info-property pattern */
            '.ew-details{display:none;padding:12px 0 4px 52px;' +
                'column-count:3;column-gap:24px;}' +
            '.ew-details--open{display:block;}' +
            '.ew-detail-item{break-inside:avoid;margin-bottom:12px;overflow-wrap:anywhere;}' +
            '.ew-detail-label{color:var(--text-gray,#949b9f);font-size:14px;' +
                'line-height:22px;padding-right:24px;}' +
            '.ew-detail-value{color:var(--primary-text,#c2c2c2);font-size:14px;' +
                'line-height:22px;min-height:16px;display:flex;' +
                'flex-direction:row;align-items:flex-start;}';
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

        // Toggle switch (cosmetic, no backend)
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
        chip.innerHTML = '<span class="ew-chip__dot"></span> \u2014';

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
     * Uses stock dashboard-card classes. Finds the grid container
     * via ndw-dashboard-card.parentElement.
     */
    function injectDashboardCard() {
        dashboardPending = false;
        if (dashboardInjected) return;
        if (window.location.pathname !== '/dashboard') return;

        // Find grid via existing stock dashboard cards
        var grid = null;
        var firstCard = document.querySelector('ndw-dashboard-card');
        if (firstCard) {
            grid = firstCard.parentElement;
        } else {
            // Fallback: layout content area
            var menu = document.querySelector('ndw-menu');
            if (menu && menu.parentElement) {
                grid = menu.parentElement.querySelector('[class*="layout__content"]');
            }
            if (!grid) grid = document.querySelector('[class*="layout__content"]');
        }
        if (!grid) return;

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
        grid.appendChild(card);
        dashboardInjected = true;

        fetchDashboardStatuses();
        dashboardTimer = setInterval(fetchDashboardStatuses, DASH_POLL_INTERVAL);
    }

    /** Format detail key: snake_case → Title Case. */
    function formatKey(key) {
        return key.replace(/_/g, ' ').replace(/\b\w/g, function(c) { return c.toUpperCase(); });
    }

    /**
     * Render details grid HTML from data object.
     * Includes top-level fields (pid, memory_kb, uptime) + all details.* fields.
     * @param {{running: boolean, pid?: string, memory_kb?: string, uptime?: string, details?: Object}} data
     * @returns {string}
     */
    function renderDetailsGrid(data) {
        var items = [];

        if (data.uptime) items.push({ k: 'Uptime', v: data.uptime });
        if (data.pid) items.push({ k: 'PID', v: data.pid });
        if (data.memory_kb && data.memory_kb !== '0') items.push({ k: 'Memory', v: data.memory_kb + ' kB' });

        if (data.details) {
            var keys = Object.keys(data.details);
            for (var i = 0; i < keys.length; i++) {
                var val = data.details[keys[i]];
                if (val === '' || val === null || val === undefined) continue;
                // Format boolean values
                if (val === true) val = 'Yes';
                if (val === false) val = 'No';
                items.push({ k: formatKey(keys[i]), v: String(val) });
            }
        }

        var html = '';
        for (var j = 0; j < items.length; j++) {
            html += '<div class="ew-detail-item">' +
                '<div class="ew-detail-label">' + items[j].k + '</div>' +
                '<div class="ew-detail-value">' + items[j].v + '</div></div>';
        }
        return html;
    }

    /**
     * Build status chip text from structured data.
     * @param {{running: boolean, uptime?: string}} data
     * @returns {{state: string, text: string}}
     */
    function parseServiceStatus(data) {
        var state = data.running ? 'running' : 'stopped';
        var text = data.running ? 'RUNNING' : 'STOPPED';
        if (data.running && data.uptime) {
            text += ' ' + data.uptime;
        }
        return { state: state, text: text };
    }

    /**
     * Fetch service statuses and update dashboard card rows.
     * Updates toggle, status chip, and expandable details grid.
     */
    function fetchDashboardStatuses() {
        SERVICE_APIS.forEach(function(svc) {
            var row = document.getElementById('ew-dash-' + svc.id);
            if (!row) return;

            var toggle = row.querySelector('.ew-toggle input');
            var chip = row.querySelector('.ew-chip');
            var detailsEl = document.getElementById('ew-details-' + svc.id);

            fetch(svc.api, { cache: 'no-store' })
                .then(function(r) { return r.json(); })
                .then(function(data) {
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
                        detailsEl.innerHTML = renderDetailsGrid(data);
                    }
                })
                .catch(function() {
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
        return true;
    }

    /**
     * Schedule dashboard card injection (with dedup guard).
     */
    function tryDashboardCard() {
        if (dashboardInjected || dashboardPending) return;
        if (window.location.pathname === '/dashboard') {
            dashboardPending = true;
            setTimeout(injectDashboardCard, 1500);
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
            var oldCard = document.getElementById('entware-dashboard-card');
            if (oldCard) oldCard.remove();
            tryDashboardCard();
        }
    }, 2000);
})();
