#!/opt/bin/sh
# lib/geo.sh — shared geo-zone library: country lists, unions, resolve functions.
# Used by: geo-split, smartdns-geo-conf, webui API.
# Source: . "$SCRIPT_DIR/../../lib/geo.sh"
# shellcheck disable=SC2034  # all variables are used by sourcing scripts
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
set -eu

# ===================================================================
# 🗺️ Continents / Регионы
# ===================================================================

# 🌍 Europe (all countries with known ccTLDs)
UNION_europe="al ad at by be ba bg hr cy cz dk ee fi fr de gr hu is ie it lv li lt lu mt md mc me nl mk no pl pt ro ru sm rs sk si es se ch tr ua gb va"

# 🌏 Asia (major countries)
UNION_asia="af am az bh bd bt bn kh cn cy ge in id ir iq il jp jo kz kw kg la lb my mv mn mm np kp om pk ph qa sa sg kr lk sy tw tj th tl tm ae uz vn ye"

# 🌎 North America
UNION_namerica="us ca mx gt hn sv ni cr pa cu jm ht do tt bs bb"

# 🌎 South America
UNION_samerica="br ar cl co pe ve ec uy py bo gy sr"

# 🌍 Africa (major countries)
UNION_africa="za eg ng ke et gh tz dz ma tn ly sd ug rw sn ci cm ao mz mg zm zw bw na mu"

# 🌊 Oceania
UNION_oceania="au nz fj pg ws to vu sb ki"

# ===================================================================
# 🏛️ Post-Soviet / Eurasia
# ===================================================================

# 🤝 EAEU / ЕАЭС (Eurasian Economic Union)
UNION_eas="ru by kz am kg"

# 🤝 CIS / СНГ (Commonwealth of Independent States)
UNION_cis="ru by kz am kg uz tj md az"

# 🏛️ Post-Soviet / Постсоветское пространство (all 15 ex-USSR)
UNION_postsov="ru by kz am kg uz tj tm md az ua ge ee lv lt"

# 🛡️ CSTO / ОДКБ (Collective Security Treaty Organization)
UNION_csto="ru by kz am kg tj"

# 🇷🇺🇧🇾 Union State / Союзное государство (Russia + Belarus)
UNION_soyuz="ru by"

# ===================================================================
# 🌐 Global alliances & economic
# ===================================================================

# 🌍 BRICS+ (2024 expansion)
UNION_brics="ru br in cn za eg et ae sa ir"

# 🌏 SCO / ШОС (Shanghai Cooperation Organisation)
UNION_sco="ru cn in kz kg pk tj uz ir by"

# 💰 G7 (Group of Seven)
UNION_g7="us gb fr de it ca jp"

# 💰 G20 (Group of Twenty)
UNION_g20="us gb fr de it ca jp au br cn in id kr mx ru sa tr za ar"

# 🏛️ OECD (Organisation for Economic Co-operation and Development — 38 members)
UNION_oecd="us gb fr de it ca jp au at be cl co cr cz dk ee fi gr hu is ie il kr lv lt lu mx nl nz no pl pt sk si es se ch tr"

# 📈 APEC (Asia-Pacific Economic Cooperation)
UNION_apec="au bn ca cl cn id jp kr my mx nz pe ph ru sg th us vn"

# 📦 RCEP (Regional Comprehensive Economic Partnership)
UNION_rcep="au bn kh cn id jp kr la my mm nz ph sg th vn"

# 🏦 FATF (Financial Action Task Force — 40 members, anti-money laundering)
UNION_fatf="us gb fr de it ca jp au at be br cn dk fi gr hk ie il in kr lu mx nl nz no pt ru sa sg es se ch tr za ar id"

# 🏦 AIIB (Asian Infrastructure Investment Bank — major shareholders)
UNION_aiib="cn in ru de kr au gb fr id br tr sa ae eg"

# 🏦 NDB / Банк BRICS (New Development Bank)
UNION_ndb="ru br in cn za eg ae bd uy"

# 🏝️ Offshore / Tax havens (major financial centers)
UNION_offshore="ky vg bm pa bs gg je im gi mc li lu sg hk ch ie nl mt cy"

# 🛢️ OPEC (Organization of the Petroleum Exporting Countries — 13 members)
UNION_opec="sa ir iq kw ae ve dz ng ly ao cg gq ga"

# 🛢️ OPEC+ (OPEC + allies — full production pact)
UNION_opec_plus="sa ir iq kw ae ve dz ng ly ao cg gq ga ru kz az my bn om bh mx sd"

# 👑 Commonwealth / Содружество наций (major members)
UNION_commonwealth="gb au ca nz in za ng ke gh sg my pk bd jm tt"

# 🗣️ Francophonie / Франкофония (major French-speaking)
UNION_francophonie="fr be ch ca ci sn cm cd mg ml bf ne tg bj ga"

# 🗣️ Lusophone / CPLP (Portuguese-speaking)
UNION_lusophone="pt br ao mz cv gw st tl"

# 🏳️ Non-Aligned / Глобальный Юг (key members)
UNION_global_south="in br za eg id ng mx ar co ke et vn bd pk"

# ===================================================================
# 🇪🇺 Europe
# ===================================================================

# 🇪🇺 EU (European Union — 27 members)
UNION_eu="de fr it es nl be at pt gr fi ie lu se pl cz dk hr ro bg hu sk si ee lv lt mt cy"

# 🛂 Schengen Area (27 countries, free movement zone)
UNION_schengen="at be ch cz de dk ee es fi fr gr hr hu is it li lt lu lv mt nl no pl pt se si sk"

# 🛂 EEA (European Economic Area = EU + EFTA minus Switzerland)
UNION_eea="de fr it es nl be at pt gr fi ie lu se pl cz dk hr ro bg hu sk si ee lv lt mt cy no is li"

# 🇪🇺 EFTA (European Free Trade Association)
UNION_efta="ch no is li"

# 🏪 EU Customs Union (EU + Turkey + microstates)
UNION_eu_customs="de fr it es nl be at pt gr fi ie lu se pl cz dk hr ro bg hu sk si ee lv lt mt cy tr"

# 💶 Eurozone (countries using EUR)
UNION_eurozone="de fr it es nl be at pt gr fi ie lu sk si ee lv lt mt cy hr"

# 🏛️ NATO (all 32 members)
UNION_nato="us ca gb fr de it es nl be pt gr pl cz dk no hr ro bg hu sk si ee lv lt al me mk is lu tr fi se"

# 🏛️ NATO European members only
UNION_nato_eu="gb fr de it es nl be pt gr pl cz dk no hr ro bg hu sk si ee lv lt al me mk is lu tr fi se"

# 🌊 Baltic states / Прибалтика
UNION_baltic="ee lv lt"

# 🏰 Visegrad Group / V4
UNION_v4="pl cz sk hu"

# 🇧🇪 Benelux
UNION_benelux="be nl lu"

# 🏔️ DACH (German-speaking)
UNION_dach="de at ch"

# ❄️ Nordic (Nordic countries)
UNION_nordic="se no dk fi is"

# ❄️ Nordic + Baltic
UNION_nordbalt="se no dk fi is ee lv lt"

# ⚔️ Western Balkans (EU candidates)
UNION_balkans="al ba me mk rs"

# 🇬🇧 British Isles
UNION_british="gb ie"

# ☀️ Iberian Peninsula
UNION_iberia="es pt"

# 🏖️ Mediterranean (EU coastal states)
UNION_mediterranean="es fr it gr hr si mt cy pt"

# ===================================================================
# 🌏 Asia-Pacific
# ===================================================================

# 🌏 ASEAN (Association of Southeast Asian Nations)
UNION_asean="id my ph sg th vn bn kh la mm"

# 👁️ Five Eyes / FVEY (intelligence alliance)
UNION_fvey="us gb ca au nz"

# 🔱 AUKUS (security pact)
UNION_aukus="au gb us"

# 🔷 QUAD (Quadrilateral Security Dialogue)
UNION_quad="us in au jp"

# 📦 CPTPP (Trans-Pacific trade)
UNION_cptpp="au bn ca cl jp my mx nz pe sg vn gb"

# 🐺 Turkic States / Тюркские государства (OTS)
UNION_turkic="tr az kz kg uz"

# 🕌 SAARC (South Asian Association for Regional Cooperation)
UNION_saarc="in pk bd lk np bt mv af"

# 🏯 East Asia / CJK
UNION_eastasia="cn jp kr"

# 🐉 Greater China (CN + HK + TW + MO)
UNION_china_plus="cn hk tw mo"

# 🎌 East Asia + ASEAN
UNION_eastasia_plus="cn jp kr id my ph sg th vn bn kh la mm"

# ===================================================================
# 🌎 Americas
# ===================================================================

# 🌎 USMCA / NAFTA (US-Mexico-Canada)
UNION_usmca="us ca mx"

# 🌎 MERCOSUR (Southern Common Market)
UNION_mercosur="br ar uy py"

# 🌋 Pacific Alliance / Alianza del Pacífico
UNION_pacific_alliance="mx co cl pe"

# 🏔️ Andean Community / CAN
UNION_andean="co ec pe bo"

# 🏝️ CARICOM (Caribbean Community)
UNION_caricom="jm tt bs bb gy sr"

# ✊ ALBA (Bolivarian Alliance)
UNION_alba="ve cu bo ni hn"

# 🌎 CELAC / ЛАКБ (Community of Latin American and Caribbean States — major)
UNION_celac="br mx ar co cl pe ve ec uy py bo cu"

# ===================================================================
# 🌍 Middle East / Africa
# ===================================================================

# 🏜️ GCC (Gulf Cooperation Council)
UNION_gcc="sa ae qa kw bh om"

# ☪️ Arab League (major members)
UNION_arab="sa ae qa kw bh om eg iq jo lb ly ma dz tn sd"

# 🌾 ECOWAS (Economic Community of West African States)
UNION_ecowas="ng gh sn ci ml bf ne tg bj gn sl lr gm gw cv"

# 🦁 EAC (East African Community)
UNION_eac="ke tz ug rw"

# 💎 SACU (Southern African Customs Union)
UNION_sacu="za bw na sz ls"

# 🌍 SADC (Southern African Development Community)
UNION_sadc="za bw na sz ls mz zm zw ao mg mu tz"

# 🌍 African Union — major economies
UNION_au_africa="za eg ng ke et gh tz dz ma"

# ===================================================================
# 🚫 Sanctions & restrictions
# ===================================================================

# 🚫 US-sanctioned countries (OFAC major sanctions programs, 2024)
UNION_us_sanctioned="cu ir kp sy ru by ve"

# 🚫 EU-sanctioned countries (major restrictive measures)
UNION_eu_sanctioned="ru by ir kp sy ve"

# 🚫 SWIFT-disconnected (countries cut from SWIFT, 2024)
UNION_swift_cut="ru by ir kp cu sy"

# 🔒 Internet-restricted (heavy network filtering / firewall)
UNION_internet_restricted="cn ir kp ru tm"

# ===================================================================
# Functions
# ===================================================================

# Resolve geo zone name to list of country codes.
# If zone matches a UNION_xxx variable, returns its value (space-separated CCs).
# Otherwise treats zone as a single country code.
# Args: $1 — zone name (e.g. "eas", "ru", "eu")
# stdout: space-separated country codes
resolve_geo_zone() {
  local zone="${1:-}"
  local union_var="UNION_${zone}"
  local union_val=""
  eval "union_val=\"\${${union_var}:-}\""
  if [ -n "$union_val" ]; then
    printf '%s' "$union_val"
  else
    printf '%s' "$zone"
  fi
}

# Check if a zone name is a union (has UNION_xxx defined).
# Args: $1 — zone name
# Returns: 0 if union, 1 if single country
is_geo_union() {
  local zone="${1:-}"
  local union_var="UNION_${zone}"
  local union_val=""
  eval "union_val=\"\${${union_var}:-}\""
  [ -n "$union_val" ]
}
