#!/bin/bash
# =============================================================================
#  rapport-run.sh — rapport complet d'un run Calypso, avec les PREUVES
# =============================================================================
#  POURQUOI CET OUTIL. Les compteurs seuls mentent. Un `grep -c` qui rend 0 ne
#  distingue pas « l'evenement n'a pas eu lieu » de « le motif est faux ». Ce
#  rapport donne donc pour chaque grandeur la VALEUR et une LIGNE TEMOIN quand
#  elle est non nulle ; un zero est annonce comme « motif jamais vu », jamais
#  comme une absence prouvee.
#
#  ⚠️ LEÇON PAYEE A L'ECRITURE DE CE SCRIPT (2026-08-24). La v1 rendait « camp=0 »
#  sur un run qui campait 19 fois : le motif etait faux (`camping` au lieu de
#  `camping (normal)` / `camped normally`), et un prefixe `-i` colle au motif
#  etait pris comme litteral. Tous les motifs ci-dessous sont donc DERIVES des
#  journaux, pas devines — et la comparaison est insensible a la casse.
#
#  ⚠️ SECONDE LEÇON. Sur une photo archivee, lire /proc/<qemu>/environ decrit le
#  run VIVANT, pas celui qu'on analyse. L'identite vient donc du manifeste du
#  run (qemu-manifest.log) ; le processus n'est consulte que si l'on regarde
#  bien le repertoire du run en cours.
#
#  USAGE
#      tools/rapport-run.sh                        # run courant
#      tools/rapport-run.sh /tmp/ref-shunt-legit   # une photo archivee
#      tools/rapport-run.sh <dir> <sortie.txt>     # ecrit aussi dans un fichier
#
#  Lecture seule : n'ecrit rien dans le run, ne le redemarre pas, ne l'interrompt
#  pas. Peut tourner pendant que la pile tourne.
# -----------------------------------------------------------------------------
set -u

# ⚠️ TROISIEME LEÇON (2026-08-24). Les deux bancs n ecrivent PAS au meme endroit :
#   run.sh          -> RUN_DIR=/tmp/calypso     LOG_DIR=/tmp/calypso/logs
#   start-direct.sh -> RUN_DIR=/tmp/osmo-nitb   LOG_DIR=/tmp/osmo-nitb/logs
# Supposer /tmp/calypso/logs a produit un rapport qui croisait le manifeste d un
# run avec les journaux d un AUTRE, fige depuis six minutes. On demande donc son
# LOG_DIR au processus vivant ; on ne le devine plus.
_pid_qemu="$(pgrep -x qemu-system-arm 2>/dev/null | head -1)"
_live=""
if [ -n "$_pid_qemu" ] && [ -r "/proc/$_pid_qemu/environ" ]; then
    _live="$(tr '\0' '\n' < "/proc/$_pid_qemu/environ" 2>/dev/null | sed -n 's/^LOG_DIR=//p' | head -1)"
fi
LIVE_DIR="${LOG_DIR:-${_live:-/tmp/calypso/logs}}"
L="${1:-$LIVE_DIR}"
SORTIE="${2:-}"
[ -n "$SORTIE" ] && exec > >(tee "$SORTIE")

q="$L/qemu.log"; o="$L/osmocon.log"; m="$L/mobile.log"
b="$L/bts.log";  g="$L/grgsm_decode.log"; man="$L/qemu-manifest.log"

n() { [ -r "${2:-}" ] && grep -icE -- "$1" "$2" 2>/dev/null | head -1 || echo 0; }
temoin() {
    [ -r "${2:-}" ] || return
    grep -iE -- "$1" "$2" 2>/dev/null | tail -1 \
        | sed -E 's/\x1b\[[0-9;]*m//g; s/^[[:space:]]+//' | cut -c1-140
}
mes() {
    local lib="$1" mot="$2" fic="$3" v
    v="$(n "$mot" "$fic")"
    printf '  %-24s %7s' "$lib" "$v"
    if [ "$v" -gt 0 ] 2>/dev/null; then
        local t; t="$(temoin "$mot" "$fic")"; [ -n "$t" ] && printf '  | %s' "$t"
    else
        printf '  | motif jamais vu — absence NON prouvee'
    fi
    printf '\n'
}
gate() { [ -r "$man" ] && grep -m1 "^\[calypso-manifest\] $1=" "$man" 2>/dev/null | cut -d= -f2- || echo '?'; }
titre() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
info()  { printf '  %-24s %s\n' "$1" "$2"; }

printf '\033[1m########## RAPPORT DE RUN — %s ##########\033[0m\n' "$(date '+%Y-%m-%d %H:%M:%S')"
[ -r "$q" ] || { echo "ERREUR : $q illisible — mauvais repertoire ?"; exit 2; }
printf 'journaux : %s%s\n' "$L" "$([ "$L" = "$LIVE_DIR" ] && echo '  (run en cours)' || echo '  (photo archivee)')"
printf 'derniere ecriture : %s\n' "$(stat -c %y "$q" 2>/dev/null | cut -d. -f1)"
# CONTROLE DE FRAICHEUR. Un journal fige pendant que qemu tourne signifie qu on
# regarde le mauvais repertoire : on le dit haut et fort plutot que de publier
# des compteurs perimes.
if [ "$L" = "$LIVE_DIR" ] && [ -n "${_pid_qemu:-}" ]; then
    _t0="$(stat -c %s "$q" 2>/dev/null)"; sleep 2; _t1="$(stat -c %s "$q" 2>/dev/null)"
    if [ "${_t0:-0}" = "${_t1:-0}" ]; then
        printf '\033[1m  ⚠️ qemu.log NE GROSSIT PAS alors que qemu tourne (pid %s).\n' "$_pid_qemu"
        printf '     Journaux probablement perimes — verifier LOG_DIR du processus.\033[0m\n'
    fi
fi

titre "0. IDENTITE DU RUN  (source : qemu-manifest.log du run analyse)"
if [ -r "$man" ]; then
    info "mode"        "$(gate CALYPSO_MODE)"
    info "pipeline"    "$(gate CALYPSO_PIPELINE)"
    info "profil"      "$(gate CALYPSO_PROFILE)"
    RC="$(gate CALYPSO_DSP_RUN_C54X)"; SH="$(gate CALYPSO_DSP_SHUNT)"
    info "producteur L1" "RUN_C54X=$RC DSP_SHUNT=$SH -> $([ "$RC" = 1 ] && echo 'c54x reveille' || echo 'c54x eteint'), $([ "$SH" = 1 ] && echo 'gr-gsm demodule' || echo 'pas de shunt')"
    info "chiffrement" "CIPH_A5=$(gate CALYPSO_CIPH_A5)"
    info "pont"        "$(gate CALYPSO_BRIDGE)"
    info "sondes"      "SBFN=$(gate CALYPSO_SBFN) SUBC=$(gate CALYPSO_SUBC) FIX_LK_SHFT=$(gate CALYPSO_FIX_LK_SHFT)"
    info "build"       "$(grep -m1 BUILD-STAMP "$man" 2>/dev/null | sed 's/.*compile le //')"
else
    info "manifeste"   "ABSENT — identite du run inconnue, ne pas conclure sur la config"
fi
if [ "$L" = "$LIVE_DIR" ]; then
    P="$(pgrep -x qemu-system-arm 2>/dev/null | head -1)"
    [ -n "$P" ] && info "qemu vivant" "pid=$P age=$(ps -o etime= -p "$P" 2>/dev/null | tr -d ' ')" \
                || info "qemu vivant" "ARRETE"
fi

titre "1. ACQUISITION L1 (osmocon.log)"
mes "L1CTL_FBSB_REQ"      'L1CTL_FBSB_REQ'                 "$o"
mes "FB detectee"         '^FB[01] \('                      "$o"
mes "Synchronize_TDMA"    'Synchronize_TDMA'                "$o"
mes "SB decodee"          '^SB[0-9] \(|=> SB 0x'            "$o"
mes "  BSIC non nul"      'BSIC=[1-9]'                      "$o"
mes "RESET FULL"          'L1CTL_RESET_REQ: FULL'           "$o"
mes "DSP Error Status"    'DSP Error Status'                "$o"
[ -r "$o" ] && info "codes erreur DSP" "$(grep -oE 'DSP Error Status: [0-9]+' "$o" | sort | uniq -c | tr '\n' ' ')"
[ -r "$o" ] && info "TOA les plus vus" "$(grep -oE 'TOA= *[0-9]+' "$o" | tr -s ' ' | sort | uniq -c | sort -rn | head -5 | tr '\n' ' ')"

titre "2. PRODUCTEUR L1 (qemu.log) — qui remplit le contrat DSP"
mes "shunt : SCH reel"    'SCH reel \(gr-gsm\)'             "$q"
mes "shunt : feed_si"     'feed_si: SI'                     "$q"
mes "shunt : feed_agch"   'feed_agch'                       "$q"
mes "c54x : d_fb_det 0>1" 'FBDET-WR .*0x0000 -> 0x0001'     "$q"
mes "c54x : tache SB"     'SBSLOT-WR'                       "$q"
mes "c54x : CRC SB bon"   'cur_pc=0x989a'                   "$q"
mes "c54x : CRC SB faux"  'cur_pc=0x989f'                   "$q"
[ -r "$q" ] && info "a_sch[3] ecrit" "$(grep 'A_SCH3_p1' "$q" 2>/dev/null | grep -oE '0x[0-9a-f]{4}->0x[0-9a-f]{4}' | sort | uniq -c | tr '\n' ' ')"
printf '  -- sondes de session (0 = non armee, cf. section 0) --\n'
mes "SBFN-PROBE"          'SBFN-PROBE'                      "$q"
mes "SUBC-PROBE quotient" 'SUBC-PROBE QUOTIENT'             "$q"
mes "SUBC-PROBE controle" 'SUBC-PROBE CONTROLE'             "$q"
mes "MVDD-PROBE copies"   'MVDD-PROBE COPIE'                "$q"
mes "sas FIX_LK_SHFT"     'FIX_LK_SHFT ACTIF'               "$q"
printf '  -- sante de l emulation --\n'
mes "opcode non impl."    'NON IMPLEMENTE|unhandled: 0x'    "$q"
mes "derail"              'DERAIL'                          "$q"

titre "3. DEMODULATION gr-gsm (grgsm_decode.log)"
mes "System Information"  'System Information'              "$g"
mes "erreurs"             'error|traceback'                 "$g"

titre "4. COUCHES 2/3 (mobile.log) — jusqu ou va l abonne"
mes "sync ARFCN"          'Sync to ARFCN'                   "$m"
mes "SYSTEM INFORMATION"  'SYSTEM INFORMATION [0-9]'        "$m"
mes "  sans sysinfo"      'No sysinfo yet'                  "$m"
mes "camp"                'camping \(normal\)|camped normally' "$m"
mes "CHANNEL REQUEST"     'CHANNEL REQUEST'                 "$m"
mes "IMMEDIATE ASSIGN"    'IMMEDIATE ASSIGNMENT'            "$m"
mes "LAPDm SABM"          'LAPD_STATE_SABM_SENT'            "$m"
mes "cipher negocie"      'cipher [1-9]'                    "$m"
mes "LU REQUEST"          'LOCATION UPDATING REQUEST'       "$m"
mes "LU ACCEPT"           'LOCATION UPDATING ACCEPT'        "$m"
mes "LU REJECT"           'LOCATION UPDATING REJECT'        "$m"
mes "TMSI"                'TMSI'                            "$m"
mes "SMS"                 'SMS-DELIVER|new SMS|CP-DATA'     "$m"
mes "appel"               'CC_SETUP|MNCC_SETUP'             "$m"
[ -r "$m" ] && info "timers MM"  "$(grep -oE 'T3[0-9]{3}' "$m" | sort | uniq -c | sort -rn | head -4 | tr '\n' ' ')"
[ -r "$m" ] && info "ccch mode"  "$(grep -oE 'ccch mode [A-Z]+' "$m" | sort | uniq -c | tr '\n' ' ')"

titre "5. RESEAU (bts / trx / sidecars)"
mes "BTS erreurs"         'ERROR'                           "$b"
[ -r "$b" ] && info "erreur dominante" "$(grep -oE 'send\(\) failed on TRXD[^(]*|ERROR [a-z0-9.]+:' "$b" | sort | uniq -c | sort -rn | head -2 | tr '\n' ' ')"
mes "TRX RACH detectee"   'RACH-DET'                        "$L/osmo-trx-ipc.log"
mes "sidecar mobile err"  'error|fail'                      "$L/sidecar-mobile.log"

titre "6. SERVICES"
mes "SMSC"                'sms|deliver'                     "$L/smsc-op1.log"
mes "asterisk warn/err"   'error|warning'                   "$L/asterisk.log"

titre "7. VERDICT — jusqu ou va la chaine"
etape() {
    if [ "${2:-0}" -gt 0 ] 2>/dev/null; then printf '  [ OK ] %-22s (%s)\n' "$1" "$2"
    else printf '  [ .. ] %-22s (0)\n' "$1"; fi
}
etape "synchro FB"        "$(n '^FB[01] \(' "$o")"
etape "synchro SB"        "$(n '^SB[0-9] \(|=> SB 0x' "$o")"
etape "sysinfo"           "$(n 'SYSTEM INFORMATION [0-9]' "$m")"
etape "camp"              "$(n 'camping \(normal\)|camped normally' "$m")"
etape "acces RACH"        "$(n 'CHANNEL REQUEST' "$m")"
etape "canal dedie"       "$(n 'IMMEDIATE ASSIGNMENT' "$m")"
etape "LU demande"        "$(n 'LOCATION UPDATING REQUEST' "$m")"
etape "LU accepte"        "$(n 'LOCATION UPDATING ACCEPT' "$m")"
etape "SMS"               "$(n 'SMS-DELIVER|new SMS|CP-DATA' "$m")"
printf '\n  Methode : un 0 dit que le MOTIF n a pas ete vu. Verifier le motif et\n'
printf '  l armement de la sonde (section 0) avant de conclure a une absence.\n'
