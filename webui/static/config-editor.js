// config-editor.js — Config Editor modal dialog for Entware Extras WebUI.
// Extracted from app.js for maintainability.
// Depends on: shared.js (EW namespace), config-schemas.js (CONFIG_SCHEMAS, CONFIG_LABELS),
//   config-form.js (renderDropdown, renderModalForm), app.js (refreshAll).
"use strict";

// Config schemas → moved to config-schemas.js (CONFIG_SCHEMAS, CONFIG_LABELS)

// ── Config Editor (Modal Dialog) ─────────────────────────────────────────────

/** Cached defaults for comparison (populated on first load). */
var configDefaults = {};

/**
 * Open config editor modal for a service.
 * @param {string} svcId - service id
 */
function toggleConfigEditor(svcId) {
    var schema = CONFIG_SCHEMAS[svcId];
    if (!schema) return;
    openConfigModal(svcId);
}

/**
 * Create and show modal dialog with loading spinner, then load data.
 * @param {string} svcId
 */
function openConfigModal(svcId) {
    // Remove any existing modal
    closeConfigModal();

    var label = CONFIG_LABELS[svcId] || svcId;
    var backdrop = document.createElement('div');
    backdrop.className = 'ew-modal-backdrop';
    backdrop.id = 'config-modal';
    backdrop.innerHTML =
        '<div class="ew-modal">' +
            '<div class="ew-modal__header">' +
                '<h2 class="ew-modal__title"><span style="display:inline-block;transform:scaleX(-1)">\u270f\ufe0f</span> ' + EW.escapeHtml(label) + ' Settings</h2>' +
                '<button class="ew-modal__close" data-modal-close>&times;</button>' +
            '</div>' +
            '<div class="ew-modal__body" id="modal-body">' +
                '<div class="ew-modal__spinner"><div class="ew-spinner"></div></div>' +
            '</div>' +
            '<div class="ew-modal__footer" id="modal-footer" style="display:none">' +
                '<button class="ndw-button ndw-button--toggle ndw-button--small ew-modal__reset-all" data-reset-all="' + svcId + '">Reset All</button>' +
                '<span class="ew-modal__footer-spacer"></span>' +
                '<button class="ndw-button ndw-button--toggle ndw-button--small" data-modal-close>Cancel</button>' +
                '<button class="ndw-button ndw-button--toggle ndw-button--toggle-enabled ndw-button--small" data-save-config="' + svcId + '">Save & Restart</button>' +
            '</div>' +
        '</div>';

    document.body.appendChild(backdrop);

    // Close on backdrop click
    backdrop.addEventListener('click', function(e) {
        if (e.target === backdrop) closeConfigModal();
    });

    // Close on Escape key
    document.addEventListener('keydown', modalEscHandler);

    // Load data
    loadConfigModal(svcId);
}

/** Close modal on Escape. */
function modalEscHandler(e) {
    if (e.key !== 'Escape') return;
    // If any dropdown panel is open, close it instead of the modal
    var modal = document.getElementById('config-modal');
    if (modal) {
        var openPanels = modal.querySelectorAll('.ew-modal__iface-select-panel:not(.ew-hidden)');
        if (openPanels.length > 0) {
            for (var i = 0; i < openPanels.length; i++) {
                openPanels[i].classList.add('ew-hidden');
            }
            e.stopPropagation();
            return;
        }
    }
    closeConfigModal();
}

/** Remove config modal from DOM. */
function closeConfigModal() {
    var existing = document.getElementById('config-modal');
    if (existing) existing.remove();
    document.removeEventListener('keydown', modalEscHandler);
}

/**
 * Load config + interfaces and render form inside modal body.
 * @param {string} svcId
 */
function loadConfigModal(svcId) {
    var body = document.getElementById('modal-body');
    var footer = document.getElementById('modal-footer');
    if (!body) return;

    var schema = CONFIG_SCHEMAS[svcId];
    var configPromise = fetch('/api/' + svcId + '/config').then(function(r) { return r.json(); });
    var ifacesPromise = fetch('/api/system/interfaces').then(function(r) { return r.json(); });
    // Fetch zone data for services with zone_selector fields (smartdns + geo-split)
    var zonesPromise = (svcId === 'smartdns' || svcId === 'geo-split')
        ? fetch('/api/system/zones').then(function(r) { return r.json(); })
        : Promise.resolve(null);
    // Fetch DNS providers list dynamically (smartdns config editor)
    var providersPromise = (svcId === 'smartdns')
        ? fetch('/api/system/dns-providers').then(function(r) { return r.json(); })
        : Promise.resolve(null);

    Promise.all([configPromise, ifacesPromise, zonesPromise, providersPromise])
        .then(function(results) {
            var configData = results[0];
            var ifacesData = results[1];
            var zonesData = results[2];
            var providersData = results[3];

            if (!configData.ok) {
                body.innerHTML = '<div class="ew-editor-msg ew-editor-msg--error">Failed: ' + EW.escapeHtml(configData.error || 'unknown') + '</div>';
                return;
            }

            // Cache defaults for reset and diff-save
            configDefaults[svcId] = configData.defaults || {};

            renderModalForm(body, svcId, schema, configData.config, configData.defaults || {}, ifacesData.interfaces || [], zonesData, providersData);
            if (footer) footer.style.display = '';
        })
        .catch(function(err) {
            body.innerHTML = '<div class="ew-editor-msg ew-editor-msg--error">Error: ' + EW.escapeHtml(err.message) + '</div>';
        });
}

/**
 * Collect form data, diff against defaults, POST only changed values.
 * @param {string} svcId
 */
function saveConfig(svcId) {
    var modal = document.getElementById('config-modal');
    if (!modal) return;

    var schema = CONFIG_SCHEMAS[svcId];
    if (!schema) return;

    var defaults = configDefaults[svcId] || {};
    var config = {};
    var hasChanges = false;

    for (var i = 0; i < schema.length; i++) {
        var field = schema[i];
        var val;
        if (field.type === 'toggle') {
            var cb = modal.querySelector('[data-config-key="' + field.key + '"]');
            val = cb && cb.checked ? (field.on || 'yes') : (field.off || 'no');
        } else if (field.type === 'radio_text') {
            var rtContainer = modal.querySelector('[data-config-key="' + field.key + '"]');
            var selRadio = rtContainer ? rtContainer.querySelector('input[type="radio"]:checked') : null;
            if (selRadio && selRadio.value === '__custom__') {
                var txtInput = rtContainer.querySelector('.ew-modal__radio-input');
                val = txtInput ? txtInput.value : '';
            } else {
                val = selRadio ? selRadio.value : '';
            }
        } else if (field.type === 'zone_selector') {
            var zsContainer = modal.querySelector('[data-config-key="' + field.key + '"]');
            if (zsContainer) {
                var zsMode = zsContainer.querySelector('input[name^="zs-mode-"]:checked');
                var panelType = (zsMode && zsMode.value) || 'zone';
                var activePanel = zsContainer.querySelector('[data-zone-panel="' + panelType + '"]');
                if (panelType === 'zone') {
                    // Multi-select zones: collect checked checkboxes
                    var zChecked = activePanel ? activePanel.querySelectorAll('.ew-modal__iface-select-panel input:checked') : [];
                    var zVals = [];
                    for (var zvi = 0; zvi < zChecked.length; zvi++) zVals.push(zChecked[zvi].value);
                    val = zVals.join(' ');
                } else {
                    // Union: single select (radio buttons)
                    var unionRadio = activePanel ? activePanel.querySelector('input[type="radio"]:checked') : null;
                    val = unionRadio ? unionRadio.value : '';
                }
            } else {
                val = '';
            }
        } else if (field.type === 'iface_select') {
            var isContainer = modal.querySelector('[data-config-key="' + field.key + '"]');
            if (field.multi === false) {
                // Single-select: read checked radio
                var ifRadio = isContainer ? isContainer.querySelector('input[type="radio"]:checked') : null;
                val = ifRadio ? ifRadio.value : '';
            } else {
                val = isContainer ? (isContainer.dataset.selectionOrder || '') : '';
            }
        } else if (field.type === 'select') {
            // Custom dropdown with radio buttons (single-select)
            var selContainer = modal.querySelector('[data-config-key="' + field.key + '"]');
            var selRadio = selContainer ? selContainer.querySelector('input[type="radio"]:checked') : null;
            val = selRadio ? selRadio.value : '';
        } else if (field.type === 'multi_select') {
            // Custom dropdown with checkboxes (multi-select) — preserves selection order
            var msContainer = modal.querySelector('[data-config-key="' + field.key + '"]');
            val = msContainer ? (msContainer.dataset.selectionOrder || '') : '';
        } else {
            var input = modal.querySelector('[data-config-key="' + field.key + '"]');
            val = input ? input.value : '';
        }
        // Only include if different from default
        if (String(val) !== String(defaults[field.key] || '')) {
            config[field.key] = val;
            hasChanges = true;
        }
    }

    var saveBtn = modal.querySelector('[data-save-config]');
    var statusEl = modal.querySelector('.ew-modal__status');
    if (!statusEl) {
        // Add status span next to save button
        var footer = document.getElementById('modal-footer');
        if (footer) {
            var span = document.createElement('span');
            span.className = 'ew-modal__status';
            footer.appendChild(span);
            statusEl = span;
        }
    }

    if (saveBtn) saveBtn.disabled = true;
    if (statusEl) { statusEl.textContent = 'Saving...'; statusEl.className = 'ew-modal__status'; }

    fetch('/api/' + svcId + '/config', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(config)
    })
    .then(function(r) { return r.json(); })
    .then(function(data) {
        if (saveBtn) saveBtn.disabled = false;
        if (data.ok) {
            // webui self-restart: keep modal open, poll until back online
            if (data.output === 'restarting') {
                if (statusEl) {
                    statusEl.textContent = 'Restarting...';
                    statusEl.className = 'ew-modal__status';
                }
                if (saveBtn) saveBtn.disabled = true;
                var pollTimer = setInterval(function() {
                    fetch('/api/' + svcId + '/status', { signal: AbortSignal.timeout(2000) })
                        .then(function(r) { return r.json(); })
                        .then(function() {
                            clearInterval(pollTimer);
                            if (statusEl) {
                                statusEl.textContent = '\u2713 Restarted';
                                statusEl.className = 'ew-modal__status ew-modal__status--ok';
                            }
                            setTimeout(function() {
                                closeConfigModal();
                                fetchStatus('/api/' + svcId + '/status', svcId, true);
                            }, 800);
                        })
                        .catch(function() { /* still restarting, keep polling */ });
                }, 1500);
                return;
            }
            if (statusEl) {
                statusEl.textContent = '\u2713 Saved';
                statusEl.className = 'ew-modal__status ew-modal__status--ok';
            }
            setTimeout(function() {
                closeConfigModal();
                fetchStatus('/api/' + svcId + '/status', svcId, true);
            }, 1200);
        } else {
            if (statusEl) {
                statusEl.textContent = 'Error: ' + (data.error || 'failed');
                statusEl.className = 'ew-modal__status ew-modal__status--error';
            }
        }
    })
    .catch(function(err) {
        if (saveBtn) saveBtn.disabled = false;
        if (statusEl) {
            statusEl.textContent = err.message;
            statusEl.className = 'ew-modal__status ew-modal__status--error';
        }
    });
}

/**
 * Handle reset button click: restore field to default value.
 * @param {HTMLElement} btn - reset button
 */
function handleResetField(btn) {
    var key = btn.getAttribute('data-reset-key');
    var defVal = btn.getAttribute('data-reset-val');
    var modal = document.getElementById('config-modal');
    if (!modal || !key) return;

    var el = modal.querySelector('[data-config-key="' + key + '"]');
    if (!el) return;

    if (el.type === 'checkbox') {
        var onVal = el.getAttribute('data-on-val') || 'yes';
        el.checked = (defVal === onVal);
    } else if (el.tagName === 'DIV' && el.classList.contains('ew-modal__radio-text')) {
        // Radio + text (presets)
        var rtRadios = el.querySelectorAll('input[type="radio"]');
        var rtInput = el.querySelector('.ew-modal__radio-input');
        var isPresetVal = false;
        for (var i = 0; i < rtRadios.length; i++) {
            if (rtRadios[i].value !== '__custom__' && rtRadios[i].value === defVal) {
                rtRadios[i].checked = true;
                isPresetVal = true;
            } else if (rtRadios[i].value === '__custom__' && !isPresetVal) {
                // Will be handled after loop
            } else {
                rtRadios[i].checked = false;
            }
        }
        if (!isPresetVal) {
            var customRadio = el.querySelector('input[value="__custom__"]');
            if (customRadio) customRadio.checked = true;
            if (rtInput) { rtInput.value = defVal; rtInput.disabled = false; }
        } else {
            if (rtInput) { rtInput.value = ''; rtInput.disabled = true; }
        }
    } else if (el.tagName === 'DIV' && el.classList.contains('ew-modal__zone-selector')) {
        // Zone selector: find which panel has the default value, switch to it
        var zsPanels = el.querySelectorAll('[data-zone-panel]');
        var zsRadios = el.querySelectorAll('input[name^="zs-mode-"]');
        var found = false;
        for (var pi = 0; pi < zsPanels.length; pi++) {
            // Check union panel (radio buttons)
            var unionRadios = zsPanels[pi].querySelectorAll('input[type="radio"][name^="zs-union-"]');
            for (var uri = 0; uri < unionRadios.length; uri++) {
                if (unionRadios[uri].value === defVal) {
                    unionRadios[uri].checked = true;
                    // Update trigger text
                    var uLabel = unionRadios[uri].closest('.ew-modal__iface-select-option');
                    var uTrigger = zsPanels[pi].querySelector('.ew-modal__iface-select-text');
                    if (uTrigger && uLabel) uTrigger.textContent = uLabel.textContent.trim();
                    // Show this panel, hide others
                    var panelType = zsPanels[pi].getAttribute('data-zone-panel');
                    for (var r = 0; r < zsRadios.length; r++) {
                        zsRadios[r].checked = (zsRadios[r].value === panelType);
                    }
                    for (var q = 0; q < zsPanels.length; q++) {
                        zsPanels[q].classList.toggle('ew-hidden', zsPanels[q] !== zsPanels[pi]);
                    }
                    found = true;
                    break;
                }
            }
            if (found) break;
            // Check zone panel (checkboxes) — defVal is space-separated zone codes
            var zoneCheckboxes = zsPanels[pi].querySelectorAll('.ew-modal__iface-select-panel input[type="checkbox"]');
            if (zoneCheckboxes.length > 0) {
                var defZones = defVal ? defVal.split(/\s+/) : [];
                var anyMatch = defZones.length > 0 && defZones.every(function(dz) {
                    for (var ci = 0; ci < zoneCheckboxes.length; ci++) {
                        if (zoneCheckboxes[ci].value === dz) return true;
                    }
                    return false;
                });
                if (anyMatch) {
                    for (var ci2 = 0; ci2 < zoneCheckboxes.length; ci2++) {
                        zoneCheckboxes[ci2].checked = defZones.indexOf(zoneCheckboxes[ci2].value) !== -1;
                    }
                    var zTrigger = zsPanels[pi].querySelector('.ew-modal__iface-select-text');
                    if (zTrigger) zTrigger.textContent = defZones.length ? defZones.join(', ') : 'None';
                    var panelType2 = zsPanels[pi].getAttribute('data-zone-panel');
                    for (var r2 = 0; r2 < zsRadios.length; r2++) {
                        zsRadios[r2].checked = (zsRadios[r2].value === panelType2);
                    }
                    for (var q2 = 0; q2 < zsPanels.length; q2++) {
                        zsPanels[q2].classList.toggle('ew-hidden', zsPanels[q2] !== zsPanels[pi]);
                    }
                    found = true;
                }
            }
            if (found) break;
        }
    } else if (el.tagName === 'DIV' && el.classList.contains('ew-modal__iface-select')) {
        var radios = el.querySelectorAll('.ew-modal__iface-select-panel input[type="radio"]');
        if (radios.length > 0) {
            // Single-select (select/union type): check matching radio
            for (var ri = 0; ri < radios.length; ri++) {
                radios[ri].checked = (radios[ri].value === defVal);
            }
            var trigger = el.querySelector('.ew-modal__iface-select-text');
            if (trigger) {
                var checkedLabel = el.querySelector('input[type="radio"]:checked');
                var labelEl = checkedLabel ? checkedLabel.closest('.ew-modal__iface-select-option') : null;
                var spanEls = labelEl ? labelEl.querySelectorAll('span') : [];
                var spanEl = spanEls.length > 0 ? spanEls[spanEls.length - 1] : null;
                trigger.textContent = spanEl ? spanEl.textContent : (defVal || 'Default route');
            }
        } else {
            // Multi-select (iface_select): check/uncheck based on defVal (space-separated)
            var defIfs = defVal ? defVal.split(/\s+/) : [];
            var isBoxes = el.querySelectorAll('.ew-modal__iface-select-panel input[type="checkbox"]');
            for (var i = 0; i < isBoxes.length; i++) {
                isBoxes[i].checked = defIfs.indexOf(isBoxes[i].value) !== -1;
            }
            el.dataset.selectionOrder = defIfs.join(' ');
            var trigger2 = el.querySelector('.ew-modal__iface-select-text');
            if (trigger2) trigger2.textContent = defIfs.length ? defIfs.map(function(n) { return EW.ifaceLabelFull(n); }).join(', ') : 'Default route';
        }
    } else {
        el.value = defVal;
    }
    btn.classList.add('ew-modal__reset--default');
}

/**
 * Reset ALL fields to their default values.
 * @param {string} svcId
 */
function handleResetAll(svcId) {
    var modal = document.getElementById('config-modal');
    if (!modal) return;
    var resetBtns = modal.querySelectorAll('[data-reset-key]');
    for (var i = 0; i < resetBtns.length; i++) {
        handleResetField(resetBtns[i]);
    }
}

// ── Config Editor Event Delegation ───────────────────────────────────────────

/**
 * Register all config-editor-related event handlers via document-level delegation.
 * Called once from app.js DOMContentLoaded.
 */
function initConfigEditorEvents() {
    // radio_text: enable/disable custom input on radio change
    document.addEventListener('change', function(e) {
        var radio = e.target;
        if (radio.type !== 'radio') return;
        var rtWrap = radio.closest('.ew-modal__radio-text');
        if (!rtWrap) return;
        var txtInput = rtWrap.querySelector('.ew-modal__radio-input');
        if (txtInput) {
            txtInput.disabled = (radio.value !== '__custom__');
            if (radio.value === '__custom__') txtInput.focus();
        }
    });

    // zone_selector: toggle panels on radio change
    document.addEventListener('change', function(e) {
        var radio = e.target;
        if (radio.type !== 'radio' || !radio.name || !radio.name.match(/^zs-mode-/)) return;
        var zsWrap = radio.closest('.ew-modal__zone-selector');
        if (!zsWrap) return;
        var panels = zsWrap.querySelectorAll('[data-zone-panel]');
        for (var i = 0; i < panels.length; i++) {
            panels[i].classList.toggle('ew-hidden', panels[i].getAttribute('data-zone-panel') !== radio.value);
        }
    });

    // iface_select: toggle dropdown panel on trigger click
    document.addEventListener('click', function(e) {
        var trigger = e.target.closest('.ew-modal__iface-select-trigger');
        if (trigger) {
            var wrap = trigger.closest('.ew-modal__iface-select');
            var panel = wrap && wrap.querySelector('.ew-modal__iface-select-panel');
            if (panel) {
                var isOpening = panel.classList.contains('ew-hidden');
                // Close all other open panels first
                var allOpen = document.querySelectorAll('.ew-modal__iface-select-panel:not(.ew-hidden)');
                for (var ap = 0; ap < allOpen.length; ap++) {
                    if (allOpen[ap] !== panel) allOpen[ap].classList.add('ew-hidden');
                }
                panel.classList.toggle('ew-hidden');
                // Position panel fixed to overlay modal
                if (isOpening) {
                    var rect = trigger.getBoundingClientRect();
                    var availHeight = window.innerHeight - rect.bottom - 12;
                    panel.style.position = 'fixed';
                    panel.style.top = rect.bottom + 4 + 'px';
                    panel.style.left = rect.left + 'px';
                    panel.style.right = 'auto';
                    panel.style.width = rect.width + 'px';
                    panel.style.maxHeight = Math.min(availHeight, window.innerHeight * 0.6) + 'px';
                    // Auto-focus filter input and reset filter
                    var filterInput = panel.querySelector('.ew-modal__iface-filter');
                    if (filterInput) {
                        filterInput.value = '';
                        var opts = panel.querySelectorAll('.ew-modal__iface-select-option');
                        for (var fi = 0; fi < opts.length; fi++) opts[fi].style.display = '';
                        var grps = panel.querySelectorAll('.ew-modal__iface-select-group');
                        for (var gi = 0; gi < grps.length; gi++) grps[gi].style.display = '';
                        var countEl = panel.querySelector('.ew-modal__iface-filter-count');
                        if (countEl) countEl.textContent = '';
                        setTimeout(function() { filterInput.focus(); }, 0);
                    }
                }
            }
            e.stopPropagation();
            return;
        }
        // Close all open iface_select panels on outside click
        if (!e.target.closest('.ew-modal__iface-select')) {
            var openPanels = document.querySelectorAll('.ew-modal__iface-select-panel:not(.ew-hidden)');
            for (var i = 0; i < openPanels.length; i++) openPanels[i].classList.add('ew-hidden');
        }
    });

    // iface_select: update display text on checkbox/radio change
    document.addEventListener('change', function(e) {
        var wrap = e.target.closest('.ew-modal__iface-select');
        if (!wrap) return;
        if (e.target.type === 'radio') {
            // Union single-select: update text and close panel
            var label = e.target.closest('.ew-modal__iface-select-option');
            var textEl = wrap.querySelector('.ew-modal__iface-select-text');
            if (textEl && label) {
                var spans = label.querySelectorAll('span');
                var spanText = spans.length > 0 ? spans[spans.length - 1] : null;
                textEl.textContent = spanText ? spanText.textContent : e.target.value;
            }
            var panel = wrap.querySelector('.ew-modal__iface-select-panel');
            if (panel) setTimeout(function() { panel.classList.add('ew-hidden'); }, 150);
        } else if (e.target.type === 'checkbox') {
            // Multi-select: preserve selection order (add to end / remove in place)
            var currentOrder = (wrap.dataset.selectionOrder || '').split(' ').filter(Boolean);
            var changedVal = e.target.value;
            if (e.target.checked) {
                if (currentOrder.indexOf(changedVal) === -1) currentOrder.push(changedVal);
            } else {
                var idx = currentOrder.indexOf(changedVal);
                if (idx !== -1) currentOrder.splice(idx, 1);
            }
            wrap.dataset.selectionOrder = currentOrder.join(' ');
            var textEl2 = wrap.querySelector('.ew-modal__iface-select-text');
            if (textEl2) textEl2.textContent = currentOrder.length ? currentOrder.map(function(n) { return EW.ifaceLabelFull(n); }).join(', ') : 'Default route';
        }
    });

    // iface_select/zone_selector: filter options by typing in search input
    document.addEventListener('input', function(e) {
        if (!e.target.classList.contains('ew-modal__iface-filter')) return;
        var query = e.target.value.toLowerCase();
        var panel = e.target.closest('.ew-modal__iface-select-panel');
        if (!panel) return;
        var options = panel.querySelectorAll('.ew-modal__iface-select-option');
        for (var i = 0; i < options.length; i++) {
            var text = options[i].textContent.toLowerCase();
            options[i].style.display = (!query || text.indexOf(query) !== -1) ? '' : 'none';
        }
        // Hide group headers that have no visible items below them
        var groups = panel.querySelectorAll('.ew-modal__iface-select-group');
        for (var g = 0; g < groups.length; g++) {
            var hasVisible = false;
            var next = groups[g].nextElementSibling;
            while (next && !next.classList.contains('ew-modal__iface-select-group')) {
                if (next.style.display !== 'none' && next.classList.contains('ew-modal__iface-select-option')) {
                    hasVisible = true;
                    break;
                }
                next = next.nextElementSibling;
            }
            groups[g].style.display = (!query || hasVisible) ? '' : 'none';
        }
        // Update count badge
        var countSpan = panel.querySelector('.ew-modal__iface-filter-count');
        if (countSpan) {
            if (query) {
                var visibleCount = 0;
                for (var vc = 0; vc < options.length; vc++) {
                    if (options[vc].style.display !== 'none') visibleCount++;
                }
                countSpan.textContent = visibleCount + '/' + options.length;
            } else {
                countSpan.textContent = options.length > 8 ? options.length : '';
            }
        }
    });

    // radio_text: clicking on disabled IP input passes through (CSS pointer-events:none)
    // to the <label>, which natively checks the __custom__ radio.
    // The 'change' handler above then enables + focuses the text input.
}
