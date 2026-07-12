#!/opt/bin/sh
# Patch set v1 — dashboard card integration for ENTWARE_EXTRAS
# Detection key: grep for .values(<PATCH_ENUM>)) in the stock bundle.
# shellcheck disable=SC2034  # read by sed in patch-stock-ui.sh
PATCH_ENUM="Po"
#
# Verified against stock bundles:
#   5.0.4  mipsel  main-ZYVOXYLQ.js  styles-AVEVNDW4.css
#   5.0.8  aarch64 main-XXXXXXXX.js  styles-J4CVWJOW.css
#   5.0.8  mipsel  main-4QPHZXFY.js  styles-D5VNMMPD.css
#   5.0.10 mipsel  main-TXLLNFBH.js  styles-DKYWR66I.css
#
# All 9 sed patterns target the same Angular minified constructs
# (Po.* enum refs for card layout). If a future firmware changes
# the minifier output, create v2.sh with new PATCH_ENUM.
#
# Each patch is a sed -i on the bundle file.
# Function apply_patches() is called by patch-stock-ui.sh with $1 = bundle path.

apply_patches() {
    _bundle="$1"

    # #6 Po enum -- register ENTWARE_EXTRAS as known card ID
    patch_sed "#6" 'ENTWARE_EXTRAS:"ENTWARE_EXTRAS"' \
        's|TELEPHONY:"TELEPHONY"}|TELEPHONY:"TELEPHONY",ENTWARE_EXTRAS:"ENTWARE_EXTRAS"}|' "$_bundle"

    # #6a SectionManager fix -- exclude ENTWARE_EXTRAS from dashboard init tracking.
    # .values(Po) gates isEveryInitialized$; ENTWARE_EXTRAS has no Angular component
    # → never registers → blocks SectionManager. Filter it out.
    patch_sed "#6a" '!=="ENTWARE_EXTRAS"' \
        's|\.values(Po))|.values(Po).filter(function(x){return x!=="ENTWARE_EXTRAS"}))|' "$_bundle"

    # #7 dXe title -- display name for ENTWARE_EXTRAS in Cards Position dialog
    patch_sed "#7" 'ENTWARE_EXTRAS:"ENTWARE EXTRAS"' \
        's|\[Po\.TELEPHONY\]:"dashboard\.card_nvox\.title"};|[Po.TELEPHONY]:"dashboard.card_nvox.title",ENTWARE_EXTRAS:"ENTWARE EXTRAS"};|' "$_bundle"

    # #8 dialog filter -- bypass isCardAvailable check for ENTWARE_EXTRAS
    patch_sed "#8" '"ENTWARE_EXTRAS"||this.viewService' \
        's#Object\.keys(Po)\.filter(a=>this\.viewService\.isCardAvailable(a))#Object.keys(Po).filter(a=>a==="ENTWARE_EXTRAS"||this.viewService.isCardAvailable(a))#' "$_bundle"

    # #QS default layout -- add ENTWARE_EXTRAS to default card order
    patch_sed "#QS" 'Po.ENTWARE_EXTRAS]' \
        's|Po\.INTERNET,Po\.USB,Po\.APPLICATIONS,Po\.SYSTEM,Po\.TELEPHONY\]|Po.INTERNET,Po.USB,Po.APPLICATIONS,Po.SYSTEM,Po.TELEPHONY,Po.ENTWARE_EXTRAS]|' "$_bundle"

    # #2-lite set order -- simplified injection into elementsOrder
    patch_sed "#2" '__ewLastOrder' \
        's|set order(e){this\.elementsOrder=e}|set order(e){try{var f=[].concat.apply([],e);if(f.indexOf("ENTWARE_EXTRAS")===-1)e[0].push("ENTWARE_EXTRAS")}catch(x){}window.__ewLastOrder=e;this.elementsOrder=e}|' "$_bundle"

    # #3 getTemplate -- return truthy placeholder for ENTWARE_EXTRAS
    patch_sed "#3" '{__ew:1}' \
        's#getTemplate(e){return this\.templateMap\.get(e)}#getTemplate(e){return this.templateMap.get(e)||(e==="ENTWARE_EXTRAS"?{__ew:1}:void 0)}#' "$_bundle"

    # #9 ngTemplateOutlet -- skip rendering for cards not in templateMap
    patch_sed "#9" 'i.templateMap.has(e)?i.getTemplate(e):null' \
        's|d("ngTemplateOutlet",i\.getTemplate(e))|d("ngTemplateOutlet",i.templateMap.has(e)?i.getTemplate(e):null)|' "$_bundle"

    # #4 predicates -- catch getControl errors for injected cards in CDK DragDrop
    patch_sed "#4" 'catch(_x){return!0}' \
        's|this\._dropListRef\.enterPredicate=(n,r)=>this\.enterPredicate(n\.data,r\.data),this\._dropListRef\.sortPredicate=(n,r,a)=>this\.sortPredicate(n,r\.data,a\.data)|this._dropListRef.enterPredicate=(n,r)=>{try{return this.enterPredicate(n.data,r.data)}catch(_x){return!0}},this._dropListRef.sortPredicate=(n,r,a)=>{try{return this.sortPredicate(n,r.data,a.data)}catch(_x){return!0}}|' "$_bundle"
}
