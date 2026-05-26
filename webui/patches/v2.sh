#!/opt/bin/sh
# Patch set v2 — dashboard card integration for ENTWARE_EXTRAS
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
    sed -i 's|TELEPHONY:"TELEPHONY"}|TELEPHONY:"TELEPHONY",ENTWARE_EXTRAS:"ENTWARE_EXTRAS"}|' "$_bundle"

    # #6a SectionManager fix -- exclude ENTWARE_EXTRAS from dashboard init tracking.
    # Dashboard SectionManager tracks all Vo values via .values(Vo). Its
    # isEveryInitialized$ and other observables gate real-time polling
    # (charts, Internet card data, availability checks).
    # ENTWARE_EXTRAS has no Angular component → never initializes/registers →
    # blocks SectionManager state machine for all dependent cards.
    # Fix: filter it out so SectionManager doesn't track it at all.
    # Our card rendering is handled by inject.js via __ewLastOrder + DOM —
    # completely independent of SectionManager.
    # Pattern ".values(Vo))" appears exactly 1× in all tested bundles.
    sed -i 's|\.values(Vo))|.values(Vo).filter(function(x){return x!=="ENTWARE_EXTRAS"}))|' "$_bundle"

    # #7 dXe title -- display name for ENTWARE_EXTRAS in Cards Position dialog
    sed -i 's|\[Vo\.TELEPHONY\]:"dashboard\.card_nvox\.title"};|[Vo.TELEPHONY]:"dashboard.card_nvox.title",ENTWARE_EXTRAS:"ENTWARE EXTRAS"};|' "$_bundle"

    # #8 dialog filter -- bypass isCardAvailable check for ENTWARE_EXTRAS
    # Uses # delimiter because replacement contains || (JS logical OR)
    sed -i 's#Object\.keys(Vo)\.filter(a=>this\.viewService\.isCardAvailable(a))#Object.keys(Vo).filter(a=>a==="ENTWARE_EXTRAS"||this.viewService.isCardAvailable(a))#' "$_bundle"

    # #QS default layout -- add ENTWARE_EXTRAS to default card order
    sed -i 's|Vo\.INTERNET,Vo\.USB,Vo\.APPLICATIONS,Vo\.SYSTEM,Vo\.TELEPHONY\]|Vo.INTERNET,Vo.USB,Vo.APPLICATIONS,Vo.SYSTEM,Vo.TELEPHONY,Vo.ENTWARE_EXTRAS]|' "$_bundle"

    # #2-lite set order -- simplified injection into elementsOrder
    sed -i 's|set order(e){this\.elementsOrder=e}|set order(e){try{var f=[].concat.apply([],e);if(f.indexOf("ENTWARE_EXTRAS")===-1)e[0].push("ENTWARE_EXTRAS")}catch(x){}window.__ewLastOrder=e;this.elementsOrder=e}|' "$_bundle"

    # #3 getTemplate -- return truthy placeholder for ENTWARE_EXTRAS
    # Uses # delimiter because replacement contains || (JS logical OR)
    sed -i 's#getTemplate(e){return this\.templateMap\.get(e)}#getTemplate(e){return this.templateMap.get(e)||(e==="ENTWARE_EXTRAS"?{__ew:1}:void 0)}#' "$_bundle"

    # #9 ngTemplateOutlet -- skip rendering for cards not in templateMap
    sed -i 's|d("ngTemplateOutlet",i\.getTemplate(e))|d("ngTemplateOutlet",i.templateMap.has(e)?i.getTemplate(e):null)|' "$_bundle"

    # #4 predicates -- catch getControl errors for injected cards in CDK DragDrop
    sed -i 's|this\._dropListRef\.enterPredicate=(n,r)=>this\.enterPredicate(n\.data,r\.data),this\._dropListRef\.sortPredicate=(n,r,a)=>this\.sortPredicate(n,r\.data,a\.data)|this._dropListRef.enterPredicate=(n,r)=>{try{return this.enterPredicate(n.data,r.data)}catch(_x){return!0}},this._dropListRef.sortPredicate=(n,r,a)=>{try{return this.sortPredicate(n,r.data,a.data)}catch(_x){return!0}}|' "$_bundle"
}
