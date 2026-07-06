#!/opt/bin/sh
# Patch set v3 — dashboard card integration for ENTWARE_EXTRAS
#
# Verified against stock bundles:
#   5.1.0  mipsel  main-8787931.js  styles-8787931.css
#
# Difference from v2: Angular moved to signal-based architecture in 5.1.0.
#   - Enum renamed Vo → Mo
#   - NdwDragPanel: `set order(e){this.elementsOrder=e}` removed
#     (order is now a writable signal: `order=V([])`)
#   - `getTemplate` uses signal call: `this.templateMap().get(e)??null`
#   - Default card layout split into desktop/mobile sub-arrays
#   - __ewLastOrder now set as side-effect in getTemplate (was in setter)
#
# Each patch is a sed -i on the bundle file.
# Function apply_patches() is called by patch-stock-ui.sh with $1 = bundle path.

apply_patches() {
    _bundle="$1"

    # #6 Mo enum -- register ENTWARE_EXTRAS as known card ID
    sed -i 's|TELEPHONY:"TELEPHONY"}|TELEPHONY:"TELEPHONY",ENTWARE_EXTRAS:"ENTWARE_EXTRAS"}|' "$_bundle"

    # #6a SectionManager fix -- exclude ENTWARE_EXTRAS from dashboard init tracking.
    # Dashboard SectionManager tracks all Mo values via .values(Mo). Its
    # isEveryInitialized$ and other observables gate real-time polling
    # (charts, Internet card data, availability checks).
    # ENTWARE_EXTRAS has no Angular component → never initializes/registers →
    # blocks SectionManager state machine for all dependent cards.
    # Fix: filter it out so SectionManager doesn't track it at all.
    # Our card rendering is handled by inject.js via __ewLastOrder + DOM —
    # completely independent of SectionManager.
    # Pattern ".values(Mo))" appears exactly 1× in tested bundles.
    sed -i 's|\.values(Mo))|.values(Mo).filter(function(x){return x!=="ENTWARE_EXTRAS"}))|' "$_bundle"

    # #7 title map -- display name for ENTWARE_EXTRAS in Cards Position dialog
    sed -i 's|\[Mo\.TELEPHONY\]:"dashboard\.card_nvox\.title"};|[Mo.TELEPHONY]:"dashboard.card_nvox.title",ENTWARE_EXTRAS:"ENTWARE EXTRAS"};|' "$_bundle"

    # #8 dialog filter -- bypass isCardAvailable check for ENTWARE_EXTRAS
    # Uses # delimiter because replacement contains || (JS logical OR)
    sed -i 's#Object\.keys(Mo)\.filter(a=>this\.viewService\.isCardAvailable(a))#Object.keys(Mo).filter(a=>a==="ENTWARE_EXTRAS"||this.viewService.isCardAvailable(a))#' "$_bundle"

    # #QS-desktop default layout -- add ENTWARE_EXTRAS to desktop first column
    # In 5.1.0 layout is {desktop:[[col1],[col2]], mobile:[[all]]}
    sed -i 's|Mo\.INTERNET,Mo\.USB,Mo\.APPLICATIONS,Mo\.SYSTEM,Mo\.TELEPHONY\],\[Mo\.SEGMENTS|Mo.INTERNET,Mo.USB,Mo.APPLICATIONS,Mo.SYSTEM,Mo.TELEPHONY,Mo.ENTWARE_EXTRAS],[Mo.SEGMENTS|' "$_bundle"

    # #QS-mobile default layout -- add ENTWARE_EXTRAS to mobile layout
    sed -i 's|Mo\.TRAFFIC_MONITOR,Mo\.TELEPHONY\]\]|Mo.TRAFFIC_MONITOR,Mo.TELEPHONY,Mo.ENTWARE_EXTRAS]]|' "$_bundle"

    # #2+3 getTemplate + __ewLastOrder -- combined hook for signal architecture.
    # Old #2-lite hooked `set order(e)` setter (removed in 5.1.0 signals).
    # Old #3 checked `this.templateMap.get(e)` (now signal: `this.templateMap()`).
    # New: getTemplate sets window.__ewLastOrder from order() signal as side-effect,
    # returns truthy placeholder {__ew:1} for ENTWARE_EXTRAS (not in real templateMap).
    # Uses # delimiter because replacement contains || and ??
    # Note: ? is literal in BRE (no backslash needed); \? would be a quantifier
    sed -i 's#getTemplate(e){return this\.templateMap()\.get(e)??null}#getTemplate(e){try{window.__ewLastOrder=this.order()}catch(x){}return this.templateMap().get(e)??(e==="ENTWARE_EXTRAS"?{__ew:1}:null)}#' "$_bundle"

    # #9 ngTemplateOutlet -- skip rendering for cards not in templateMap.
    # Updated for signal architecture: templateMap is now a computed signal,
    # so .has() requires calling templateMap() first.
    sed -i 's|d("ngTemplateOutlet",i\.getTemplate(e))|d("ngTemplateOutlet",i.templateMap().has(e)?i.getTemplate(e):null)|' "$_bundle"

    # #4 predicates -- catch getControl errors for injected cards in CDK DragDrop
    sed -i 's|this\._dropListRef\.enterPredicate=(n,r)=>this\.enterPredicate(n\.data,r\.data),this\._dropListRef\.sortPredicate=(n,r,a)=>this\.sortPredicate(n,r\.data,a\.data)|this._dropListRef.enterPredicate=(n,r)=>{try{return this.enterPredicate(n.data,r.data)}catch(_x){return!0}},this._dropListRef.sortPredicate=(n,r,a)=>{try{return this.sortPredicate(n,r.data,a.data)}catch(_x){return!0}}|' "$_bundle"
}
