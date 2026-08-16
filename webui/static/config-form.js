// config-form.js — Form rendering for Config Editor modal.
// Extracted from config-editor.js for maintainability.
// Depends on: shared.js (EW namespace), config-schemas.js (CONFIG_SCHEMAS).
// Used by: config-editor.js (loadConfigModal calls renderModalForm).
"use strict";

/**
 * Render a unified dropdown component (single-select or multi-select).
 * Handles search bar, grouped options, pre-items with dot indicators.
 * @param {Object} opts
 * @param {string} opts.mode - 'single' (radio) or 'multi' (checkbox)
 * @param {string} opts.configKey - data-config-key attribute value
 * @param {string} opts.displayText - text shown in the trigger button
 * @param {Array} opts.options - [{value, label, desc?}] flat options
 * @param {Array} [opts.groups] - [{group, items:[{value, label, desc?}]}] grouped options (overrides opts.options)
 * @param {Array} [opts.preItems] - [{value, label}] special items before main list (with dot indicator)
 * @param {string} [opts.radioName] - name attribute for radio inputs (required for single mode)
 * @param {string|Array} [opts.selected] - current value(s): string for single, array for multi
 * @param {boolean} [opts.dots] - show up/down dot indicators on options
 * @param {Array} [opts.ifaces] - [{name, label?, up}] interface data (when dots=true)
 * @returns {string} HTML string
 */
function renderDropdown(opts) {
    var mode = opts.mode || 'single';
    var isMulti = (mode === 'multi');
    var selected = opts.selected || (isMulti ? [] : '');
    var selArray = isMulti ? (Array.isArray(selected) ? selected : String(selected).split(/\s+/).filter(Boolean)) : [];
    var selVal = isMulti ? '' : String(selected);
    var displayText = opts.displayText || (isMulti ? (selArray.length ? selArray.join(', ') : 'None') : selVal);

    var html = '';
    // Container
    var keyAttr = opts.configKey ? ' data-config-key="' + EW.escapeHtml(opts.configKey) + '"' : '';
    if (isMulti) {
        html += '<div class="ew-modal__iface-select"' + keyAttr + ' data-selection-order="' + EW.escapeHtml(selArray.join(' ')) + '">';
    } else {
        html += '<div class="ew-modal__iface-select"' + keyAttr + '>';
    }
    // Trigger button
    html += '<button type="button" class="ew-modal__iface-select-trigger">' +
        '<span class="ew-modal__iface-select-text">' + EW.escapeHtml(displayText) + '</span>' +
        '<svg class="ew-modal__select-arrow" width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M7 10l5 5 5-5z"/></svg></button>';
    // Panel
    html += '<div class="ew-modal__iface-select-panel ew-hidden">';
    // Search bar (always present)
    html += '<div class="ew-modal__iface-filter-wrap"><input type="text" class="ew-modal__iface-filter" placeholder="Search..." autocomplete="off"><span class="ew-modal__iface-filter-count"></span></div>';

    // Pre-items (special options with dot indicators, e.g. "Default route", "All VPNs")
    if (opts.preItems) {
        for (var pi = 0; pi < opts.preItems.length; pi++) {
            var pre = opts.preItems[pi];
            if (isMulti) {
                var preChk = selArray.indexOf(pre.value) !== -1;
                html += '<label class="ew-modal__iface-select-option">' +
                    '<input type="checkbox" value="' + EW.escapeHtml(pre.value) + '"' + (preChk ? ' checked' : '') + '>' +
                    '<span class="ew-modal__iface-dot ew-modal__iface-dot--up"></span>' +
                    '<span>' + EW.escapeHtml(pre.label) + '</span></label>';
            } else {
                var preRChk = (pre.value === selVal);
                html += '<label class="ew-modal__iface-select-option">' +
                    '<input type="radio" name="' + EW.escapeHtml(opts.radioName || '') + '" value="' + EW.escapeHtml(pre.value) + '"' + (preRChk ? ' checked' : '') + '>' +
                    '<span class="ew-modal__iface-dot ew-modal__iface-dot--up"></span>' +
                    '<span>' + EW.escapeHtml(pre.label) + '</span></label>';
            }
        }
    }

    // Grouped options (for unions)
    if (opts.groups) {
        for (var gi = 0; gi < opts.groups.length; gi++) {
            var grp = opts.groups[gi];
            html += '<div class="ew-modal__iface-select-group">' + EW.escapeHtml(grp.group) + '</div>';
            var items = grp.items || [];
            for (var ui = 0; ui < items.length; ui++) {
                var u = items[ui];
                var uChk = (u.value === selVal);
                html += '<label class="ew-modal__iface-select-option">' +
                    '<input type="radio" name="' + EW.escapeHtml(opts.radioName || '') + '" value="' + EW.escapeHtml(u.value) + '"' + (uChk ? ' checked' : '') + '>' +
                    '<span>' + EW.escapeHtml(u.label) + (u.desc ? ' (' + EW.escapeHtml(u.desc) + ')' : '') + '</span></label>';
            }
        }
    } else {
        // Flat options
        var optionsList = opts.options || [];
        for (var oi = 0; oi < optionsList.length; oi++) {
            var opt = optionsList[oi];
            if (isMulti) {
                var mChk = selArray.indexOf(opt.value) !== -1;
                html += '<label class="ew-modal__iface-select-option">';
                html += '<input type="checkbox" value="' + EW.escapeHtml(opt.value) + '"' + (mChk ? ' checked' : '') + '>';
                if (opts.dots && opts.ifaces) {
                    var ifc = null;
                    for (var ii = 0; ii < opts.ifaces.length; ii++) {
                        if (opts.ifaces[ii].name === opt.value) { ifc = opts.ifaces[ii]; break; }
                    }
                    var dotState = (ifc && ifc.up) ? 'up' : 'down';
                    html += '<span class="ew-modal__iface-dot ew-modal__iface-dot--' + dotState + '"></span>';
                }
                html += '<span>' + EW.escapeHtml(opt.label) + (opt.desc ? ' \u2014 ' + EW.escapeHtml(opt.desc) : '') + '</span></label>';
            } else {
                var sChk = (opt.value === selVal);
                html += '<label class="ew-modal__iface-select-option">' +
                    '<input type="radio" name="' + EW.escapeHtml(opts.radioName || '') + '" value="' + EW.escapeHtml(opt.value) + '"' + (sChk ? ' checked' : '') + '>';
                if (opts.dots && opts.ifaces) {
                    var sIfc = null;
                    for (var si2 = 0; si2 < opts.ifaces.length; si2++) {
                        if (opts.ifaces[si2].name === opt.value) { sIfc = opts.ifaces[si2]; break; }
                    }
                    var sDotState = (sIfc && sIfc.up) ? 'up' : 'down';
                    html += '<span class="ew-modal__iface-dot ew-modal__iface-dot--' + sDotState + '"></span>';
                }
                html += '<span>' + EW.escapeHtml(opt.label) + (opt.desc ? ' \u2014 ' + EW.escapeHtml(opt.desc) : '') + '</span></label>';
            }
        }
    }

    html += '</div></div>';
    return html;
}

/**
 * Render form fields inside modal body.
 * @param {HTMLElement} body
 * @param {string} svcId
 * @param {Array} schema
 * @param {Object} config - current merged values
 * @param {Object} defaults - default values
 * @param {Array} interfaces
 * @param {Object|null} zonesData - zone selector data (for smartdns)
 * @param {Object|null} providersData - DNS providers from /api/system/dns-providers
 */
function renderModalForm(body, svcId, schema, config, defaults, interfaces, zonesData, providersData) {
    var html = '';

    for (var i = 0; i < schema.length; i++) {
        var field = schema[i];
        var val = config[field.key] !== undefined ? config[field.key] : '';
        var defVal = defaults[field.key] !== undefined ? defaults[field.key] : '';
        var isDefault = (String(val) === String(defVal));

        var fieldClass = field.type === 'toggle' ? 'ew-modal__field ew-modal__field--toggle' : 'ew-modal__field';
        html += '<div class="' + fieldClass + '">';

        // Help icon (?) with CSS tooltip — rendered inline right after label
        var helpHtml = '';
        if (field.desc) {
            helpHtml = '<span class="ew-modal__help" data-tooltip="' + EW.escapeHtml(field.desc) + '">?</span>';
        }

        if (field.type === 'toggle') {
            // Toggle: row=[switch, label, help, reset], hint below
            var onVal = field.on || 'yes';
            var checked = (val === onVal || val === true) ? ' checked' : '';
            var toggleId = 'cfg-' + field.key;
            html += '<div class="ew-modal__toggle-row">';
            html += '<label class="ew-toggle ew-modal__toggle">' +
                '<input type="checkbox" id="' + toggleId + '" data-config-key="' + field.key + '" data-on-val="' + EW.escapeHtml(field.on || 'yes') + '"' + checked + '>' +
                '<span class="ew-toggle__bar"></span></label>';
            html += '<label class="ew-modal__label ew-modal__label--clickable" for="' + toggleId + '">' + EW.escapeHtml(field.label) + '</label>';
            html += helpHtml;
            html += '<button class="ew-modal__reset' + (isDefault ? ' ew-modal__reset--default' : '') + '" data-reset-key="' + field.key + '" data-reset-val="' + EW.escapeHtml(String(defVal)) + '" data-tooltip="Reset to default:\n' + EW.escapeHtml(String(defVal)) + '">' +
                '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M12.5 8c-2.65 0-5.05 1.04-6.83 2.73L3 8v8h8l-2.81-2.81C9.59 11.82 10.96 11 12.5 11c2.76 0 5.07 1.75 5.94 4.2l2.37-.78C19.63 10.96 16.35 8 12.5 8z"/></svg>' +
                '</button>';
            html += '</div>';
        } else {
            // Other fields: [header with label + help + reset] then input below
            html += '<div class="ew-modal__field-header">';
            html += '<label class="ew-modal__label">' + EW.escapeHtml(field.label) + '</label>';
            html += helpHtml;
            html += '<button class="ew-modal__reset' + (isDefault ? ' ew-modal__reset--default' : '') + '" data-reset-key="' + field.key + '" data-reset-val="' + EW.escapeHtml(String(defVal)) + '" data-tooltip="Reset to default:\n' + EW.escapeHtml(String(defVal)) + '">' +
                '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M12.5 8c-2.65 0-5.05 1.04-6.83 2.73L3 8v8h8l-2.81-2.81C9.59 11.82 10.96 11 12.5 11c2.76 0 5.07 1.75 5.94 4.2l2.37-.78C19.63 10.96 16.35 8 12.5 8z"/></svg>' +
                '</button>';
            html += '</div>';
        }

        if (field.type === 'number') {
            html += '<input type="number" class="ew-modal__input" ' +
                'data-config-key="' + field.key + '" ' +
                'value="' + EW.escapeHtml(String(val)) + '" ' +
                (field.min !== undefined ? 'min="' + field.min + '" ' : '') +
                (field.max !== undefined ? 'max="' + field.max + '" ' : '') + '>';
        } else if (field.type === 'text') {
            html += '<input type="text" class="ew-modal__input" ' +
                'data-config-key="' + field.key + '" ' +
                'value="' + EW.escapeHtml(String(val)) + '">';
        } else if (field.type === 'radio_text') {
            // Radio presets + custom text input
            var presets = field.presets || [];
            var isPreset = false;
            html += '<div class="ew-modal__radio-text" data-config-key="' + field.key + '">';
            for (var p = 0; p < presets.length; p++) {
                var pr = presets[p];
                var prChecked = (val === pr.value) ? ' checked' : '';
                if (val === pr.value) isPreset = true;
                html += '<label class="ew-modal__radio-item">' +
                    '<input type="radio" name="rt-' + field.key + '" value="' + EW.escapeHtml(pr.value) + '"' + prChecked + '>' +
                    '<span class="ew-modal__radio-label">' + EW.escapeHtml(pr.label) + '</span>' +
                    '</label>';
            }
            var customChecked = !isPreset ? ' checked' : '';
            var customVal = !isPreset ? EW.escapeHtml(String(val)) : '';
            html += '<label class="ew-modal__radio-item ew-modal__radio-item--custom">' +
                '<input type="radio" name="rt-' + field.key + '" value="__custom__"' + customChecked + '>' +
                '<span class="ew-modal__radio-label">IP:</span>' +
                '<input type="text" class="ew-modal__radio-input" placeholder="e.g. 176.65.44.1" value="' + customVal + '"' + (isPreset ? ' disabled' : '') + '>' +
                '</label>';
            html += '</div>';
        } else if (field.type === 'select') {
            // Single-select dropdown (radio buttons)
            var selDisplayText = String(val);
            for (var sd = 0; sd < field.options.length; sd++) {
                if (field.options[sd].value === String(val)) { selDisplayText = field.options[sd].label; break; }
            }
            html += renderDropdown({
                mode: 'single',
                configKey: field.key,
                displayText: selDisplayText,
                radioName: 'sel-' + field.key,
                selected: String(val),
                options: field.options
            });
        } else if (field.type === 'multi_select') {
            // Multi-select dropdown (checkboxes) with dynamic options from API
            var msOptions = field.options || [];
            if (field.dynamicOptions && providersData && providersData[field.dynamicOptions]) {
                msOptions = providersData[field.dynamicOptions];
            }
            html += renderDropdown({
                mode: 'multi',
                configKey: field.key,
                selected: val,
                options: msOptions
            });
        } else if (field.type === 'zone_selector' && zonesData) {
            // Zone selector: wrapper with radio pills + two dropdown panels
            var zones = zonesData.zones || [];
            var unions = zonesData.unions || [];
            var valParts = String(val).split(/\s+/).filter(function(s) { return s; });
            var zoneValues = {};
            for (var zi = 0; zi < zones.length; zi++) { zoneValues[zones[zi].value] = true; }
            var isZone = valParts.length > 0 && valParts.every(function(v) { return zoneValues[v]; });
            var isUnion = !isZone;
            var zsRadioName = 'zs-mode-' + field.key;

            html += '<div class="ew-modal__zone-selector" data-config-key="' + field.key + '">';
            // Radio pills: Zone / Union
            html += '<div class="ew-modal__zone-radio">';
            html += '<label class="ew-modal__radio-item' + (isZone ? ' ew-modal__radio-item--active' : '') + '">' +
                '<input type="radio" name="' + zsRadioName + '" value="zone"' + (isZone ? ' checked' : '') + '>' +
                '<span class="ew-modal__radio-label">Zone</span></label>';
            html += '<label class="ew-modal__radio-item' + (isUnion ? ' ew-modal__radio-item--active' : '') + '">' +
                '<input type="radio" name="' + zsRadioName + '" value="union"' + (isUnion ? ' checked' : '') + '>' +
                '<span class="ew-modal__radio-label">Union</span></label>';
            html += '</div>';

            // Zone panel: multi-select countries
            var selectedZones = isZone ? valParts : [];
            html += '<div class="ew-modal__zone-panel' + (isZone ? '' : ' ew-hidden') + '" data-zone-panel="zone">';
            html += renderDropdown({
                mode: 'multi',
                configKey: '',
                selected: selectedZones,
                options: zones
            });
            html += '</div>';

            // Union panel: single-select grouped unions
            // Pre-compute display text for union
            var unionDisplayText = 'None';
            for (var ugi = 0; ugi < unions.length; ugi++) {
                var uitems = unions[ugi].items || [];
                for (var uii = 0; uii < uitems.length; uii++) {
                    if (uitems[uii].value === val) {
                        unionDisplayText = uitems[uii].label + ' (' + uitems[uii].desc + ')';
                    }
                }
            }
            html += '<div class="ew-modal__zone-panel' + (isUnion ? '' : ' ew-hidden') + '" data-zone-panel="union">';
            html += renderDropdown({
                mode: 'single',
                configKey: '',
                displayText: unionDisplayText,
                radioName: 'zs-union-' + field.key,
                selected: String(val),
                groups: unions
            });
            html += '</div>';
            html += '</div>';
        } else if (field.type === 'iface_select') {
            // Interface selector (sorted: up first, then down, alphabetically)
            var isIfaceMulti = field.multi !== false;
            var sortedIfaces = interfaces.slice().sort(function(a, b) {
                if (a.up !== b.up) return a.up ? -1 : 1;
                return (a.name || '').localeCompare(b.name || '');
            });
            var ifaceOpts = [];
            for (var si = 0; si < sortedIfaces.length; si++) {
                ifaceOpts.push({ value: sortedIfaces[si].name, label: sortedIfaces[si].label || sortedIfaces[si].name });
            }
            if (isIfaceMulti) {
                // Multi-select (checkboxes, space-separated values)
                var selectedIfs = String(val).split(/\s+/).filter(function(s) { return s; });
                var _preMap = {};
                if (field.preItems) { for (var pi = 0; pi < field.preItems.length; pi++) _preMap[field.preItems[pi].value] = field.preItems[pi].label; }
                var ifDisplayText = selectedIfs.length ? selectedIfs.map(function(n) { return _preMap[n] || EW.ifaceLabelFull(n); }).join(', ') : (field.preItems ? field.preItems[0].label : 'Default route');
                html += renderDropdown({
                    mode: 'multi',
                    configKey: field.key,
                    displayText: ifDisplayText,
                    selected: selectedIfs,
                    preItems: field.preItems || [{ value: 'default', label: 'Default route' }],
                    options: ifaceOpts,
                    dots: true,
                    ifaces: sortedIfaces
                });
            } else {
                // Single-select (radio buttons, one value)
                var selIfVal = String(val);
                var singlePreItems = field.preItems || [{ value: '', label: 'Default route' }];
                var ifSingleDisplay = '';
                for (var spi = 0; spi < singlePreItems.length; spi++) {
                    if (singlePreItems[spi].value === selIfVal) { ifSingleDisplay = singlePreItems[spi].label; break; }
                }
                if (!ifSingleDisplay) {
                    ifSingleDisplay = selIfVal ? EW.ifaceLabelFull(selIfVal) : singlePreItems[0].label;
                }
                html += renderDropdown({
                    mode: 'single',
                    configKey: field.key,
                    displayText: ifSingleDisplay,
                    radioName: 'iface-' + field.key,
                    selected: selIfVal,
                    preItems: singlePreItems,
                    options: ifaceOpts,
                    dots: true,
                    ifaces: sortedIfaces
                });
            }
        }

        if (field.hint) {
            html += '<span class="ew-modal__hint">' + EW.escapeHtml(field.hint) + '</span>';
        }
        html += '</div>';
    }

    body.innerHTML = html;
}
