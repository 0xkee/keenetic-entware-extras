#!/opt/bin/sh
# Patch set v2 — dashboard card integration for ENTWARE_EXTRAS
# Detection key: grep for .values(<PATCH_ENUM>)) in the stock bundle.
# shellcheck disable=SC2034  # read by sed in patch-stock-ui.sh
PATCH_ENUM="Vo"
#
# Verified against stock bundles:
#   5.1 Beta 3  mipsel  main-3FF05DF.js  styles-3FF05DF.css
#
# Difference from v1: Angular minifier renamed enum Po → Vo in 5.1.
# All sed patterns updated accordingly (both search and replace).
# The patch LOGIC is identical to v1.
#
# Each patch is a sed -i on the bundle file.
# Function apply_patches() is called by patch-stock-ui.sh with $1 = bundle path.

apply_patches() {
    _bundle="$1"

    # #6 Vo enum -- register ENTWARE_EXTRAS as known card ID
    patch_sed "#6" 'ENTWARE_EXTRAS:"ENTWARE_EXTRAS"' \
        's|TELEPHONY:"TELEPHONY"}|TELEPHONY:"TELEPHONY",ENTWARE_EXTRAS:"ENTWARE_EXTRAS"}|' "$_bundle"

    # #6a SectionManager fix -- exclude ENTWARE_EXTRAS from dashboard init tracking.
    # .values(Vo) gates isEveryInitialized$; ENTWARE_EXTRAS has no Angular component
    # → never registers → blocks SectionManager. Filter it out.
    patch_sed "#6a" '!=="ENTWARE_EXTRAS"' \
        's|\.values(Vo))|.values(Vo).filter(function(x){return x!=="ENTWARE_EXTRAS"}))|' "$_bundle"

    # #7 dXe title -- display name for ENTWARE_EXTRAS in Cards Position dialog
    patch_sed "#7" 'ENTWARE_EXTRAS:"ENTWARE EXTRAS"' \
        's|\[Vo\.TELEPHONY\]:"dashboard\.card_nvox\.title"};|[Vo.TELEPHONY]:"dashboard.card_nvox.title",ENTWARE_EXTRAS:"ENTWARE EXTRAS"};|' "$_bundle"

    # #8 dialog filter -- bypass isCardAvailable check for ENTWARE_EXTRAS
    patch_sed "#8" '"ENTWARE_EXTRAS"||this.viewService' \
        's#Object\.keys(Vo)\.filter(a=>this\.viewService\.isCardAvailable(a))#Object.keys(Vo).filter(a=>a==="ENTWARE_EXTRAS"||this.viewService.isCardAvailable(a))#' "$_bundle"

    # #QS default layout -- add ENTWARE_EXTRAS to default card order
    patch_sed "#QS" 'Vo.ENTWARE_EXTRAS]' \
        's|Vo\.INTERNET,Vo\.USB,Vo\.APPLICATIONS,Vo\.SYSTEM,Vo\.TELEPHONY\]|Vo.INTERNET,Vo.USB,Vo.APPLICATIONS,Vo.SYSTEM,Vo.TELEPHONY,Vo.ENTWARE_EXTRAS]|' "$_bundle"

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
