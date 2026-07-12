#!/opt/bin/sh
# Patch set v4 — dashboard card integration for ENTWARE_EXTRAS
# Detection key: content-based enum lookup in the stock bundle.
# shellcheck disable=SC2034  # read by sed in patch-stock-ui.sh
PATCH_ENUM="Oo"
#
# Verified against stock bundles:
#   5.2.x  mipsel  main-553997B.js  styles-553997B.css
#
# Difference from v3: Enum renamed Mo → Oo
#   - Same signal-based architecture as v3
#   - NdwDragPanel: `order=V([])` writable signal (unchanged)
#   - `getTemplate` uses signal call: `this.templateMap().get(e)??null`
#   - Default card layout split into desktop/mobile sub-arrays
#   - __ewLastOrder now set as side-effect in getTemplate (was in setter)
#
# Each patch is a sed -i on the bundle file.
# Function apply_patches() is called by patch-stock-ui.sh with $1 = bundle path.

apply_patches() {
    _bundle="$1"

    # #6 Oo enum -- register ENTWARE_EXTRAS as known card ID
    patch_sed "#6" 'ENTWARE_EXTRAS:"ENTWARE_EXTRAS"' \
        's|TELEPHONY:"TELEPHONY"}|TELEPHONY:"TELEPHONY",ENTWARE_EXTRAS:"ENTWARE_EXTRAS"}|' "$_bundle"

    # #6a SectionManager fix -- exclude ENTWARE_EXTRAS from dashboard init tracking.
    # .values(Oo) gates isEveryInitialized$; ENTWARE_EXTRAS has no Angular component
    # → never registers → blocks SectionManager. Filter it out.
    patch_sed "#6a" '!=="ENTWARE_EXTRAS"' \
        's|\.values(Oo))|.values(Oo).filter(function(x){return x!=="ENTWARE_EXTRAS"}))|' "$_bundle"

    # #7 title map -- display name for ENTWARE_EXTRAS in Cards Position dialog
    patch_sed "#7" 'ENTWARE_EXTRAS:"ENTWARE EXTRAS"' \
        's|\[Oo\.TELEPHONY\]:"dashboard\.card_nvox\.title"};|[Oo.TELEPHONY]:"dashboard.card_nvox.title",ENTWARE_EXTRAS:"ENTWARE EXTRAS"};|' "$_bundle"

    # #8 dialog filter -- bypass isCardAvailable check for ENTWARE_EXTRAS
    patch_sed "#8" '"ENTWARE_EXTRAS"||this.viewService' \
        's#Object\.keys(Oo)\.filter(a=>this\.viewService\.isCardAvailable(a))#Object.keys(Oo).filter(a=>a==="ENTWARE_EXTRAS"||this.viewService.isCardAvailable(a))#' "$_bundle"

    # #QS-desktop default layout -- add ENTWARE_EXTRAS to desktop first column
    # In 5.1.1 layout is {desktop:[[col1],[col2]], mobile:[[all]]}
    patch_sed "#QS-desktop" 'Oo.ENTWARE_EXTRAS],[' \
        's|Oo\.INTERNET,Oo\.USB,Oo\.APPLICATIONS,Oo\.SYSTEM,Oo\.TELEPHONY\],\[Oo\.SEGMENTS|Oo.INTERNET,Oo.USB,Oo.APPLICATIONS,Oo.SYSTEM,Oo.TELEPHONY,Oo.ENTWARE_EXTRAS],[Oo.SEGMENTS|' "$_bundle"

    # #QS-mobile default layout -- add ENTWARE_EXTRAS to mobile layout
    patch_sed "#QS-mobile" 'Oo.ENTWARE_EXTRAS]]' \
        's|Oo\.TRAFFIC_MONITOR,Oo\.TELEPHONY\]\]|Oo.TRAFFIC_MONITOR,Oo.TELEPHONY,Oo.ENTWARE_EXTRAS]]|' "$_bundle"

    # #2+3 getTemplate + __ewLastOrder -- combined hook for signal architecture.
    # getTemplate sets window.__ewLastOrder from order() signal as side-effect,
    # returns truthy placeholder {__ew:1} for ENTWARE_EXTRAS (not in real templateMap).
    patch_sed "#2+3" '__ewLastOrder' \
        's#getTemplate(e){return this\.templateMap()\.get(e)??null}#getTemplate(e){try{window.__ewLastOrder=this.order()}catch(x){}return this.templateMap().get(e)??(e==="ENTWARE_EXTRAS"?{__ew:1}:null)}#' "$_bundle"

    # #9 ngTemplateOutlet -- skip rendering for cards not in templateMap.
    # Signal architecture: templateMap is a computed signal → templateMap().has(e).
    patch_sed "#9" 'i.templateMap().has(e)?i.getTemplate(e):null' \
        's|d("ngTemplateOutlet",i\.getTemplate(e))|d("ngTemplateOutlet",i.templateMap().has(e)?i.getTemplate(e):null)|' "$_bundle"

    # #4 predicates -- catch getControl errors for injected cards in CDK DragDrop
    patch_sed "#4" 'catch(_x){return!0}' \
        's|this\._dropListRef\.enterPredicate=(n,r)=>this\.enterPredicate(n\.data,r\.data),this\._dropListRef\.sortPredicate=(n,r,a)=>this\.sortPredicate(n,r\.data,a\.data)|this._dropListRef.enterPredicate=(n,r)=>{try{return this.enterPredicate(n.data,r.data)}catch(_x){return!0}},this._dropListRef.sortPredicate=(n,r,a)=>{try{return this.sortPredicate(n,r.data,a.data)}catch(_x){return!0}}|' "$_bundle"
}
