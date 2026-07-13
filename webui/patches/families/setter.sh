# Setter-family patch logic for ENTWARE_EXTRAS dashboard card integration.
# Sourced by v1.sh, v2.sh — do NOT execute directly.
#
# Setter-based Angular architecture (KeeneticOS 5.0.x–5.1 Beta):
#   set order(e){this.elementsOrder=e}
#   getTemplate(e){return this.templateMap.get(e)}
#   Single default layout array (no desktop/mobile split)
#
# Patches: #6, #6a, #7, #8, #QS, #2, #3, #9, #4

# Apply all setter-family patches to a stock Angular bundle.
# Usage: _apply_setter_patches <enum> <bundle_path>
#   $1 — DashboardSection enum name (e.g. Po, Vo)
#   $2 — path to main-*.js bundle file
_apply_setter_patches() {
    _E="$1"
    _bundle="$2"

    # #6 enum -- register ENTWARE_EXTRAS as known card ID
    patch_sed "#6" 'ENTWARE_EXTRAS:"ENTWARE_EXTRAS"' \
        's|TELEPHONY:"TELEPHONY"}|TELEPHONY:"TELEPHONY",ENTWARE_EXTRAS:"ENTWARE_EXTRAS"}|' "$_bundle"

    # #6a SectionManager fix -- exclude ENTWARE_EXTRAS from dashboard init tracking.
    # .values($_E) gates isEveryInitialized$; ENTWARE_EXTRAS has no Angular component
    # → never registers → blocks SectionManager. Filter it out.
    patch_sed "#6a" '!=="ENTWARE_EXTRAS"' \
        's|\.values('"$_E"'))|.values('"$_E"').filter(function(x){return x!=="ENTWARE_EXTRAS"}))|' "$_bundle"

    # #7 title map -- display name for ENTWARE_EXTRAS in Cards Position dialog
    patch_sed "#7" 'ENTWARE_EXTRAS:"ENTWARE EXTRAS"' \
        's|\['"$_E"'\.TELEPHONY\]:"dashboard\.card_nvox\.title"};|['"$_E"'.TELEPHONY]:"dashboard.card_nvox.title",ENTWARE_EXTRAS:"ENTWARE EXTRAS"};|' "$_bundle"

    # #8 dialog filter -- bypass isCardAvailable check for ENTWARE_EXTRAS
    patch_sed "#8" '"ENTWARE_EXTRAS"||this.viewService' \
        's#Object\.keys('"$_E"')\.filter(a=>this\.viewService\.isCardAvailable(a))#Object.keys('"$_E"').filter(a=>a==="ENTWARE_EXTRAS"||this.viewService.isCardAvailable(a))#' "$_bundle"

    # #QS default layout -- add ENTWARE_EXTRAS to default card order
    patch_sed "#QS" "$_E"'.ENTWARE_EXTRAS]' \
        's|'"$_E"'\.INTERNET,'"$_E"'\.USB,'"$_E"'\.APPLICATIONS,'"$_E"'\.SYSTEM,'"$_E"'\.TELEPHONY\]|'"$_E"'.INTERNET,'"$_E"'.USB,'"$_E"'.APPLICATIONS,'"$_E"'.SYSTEM,'"$_E"'.TELEPHONY,'"$_E"'.ENTWARE_EXTRAS]|' "$_bundle"

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
