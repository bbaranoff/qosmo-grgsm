#!/bin/bash
# run_si_arm.sh — SI forcees COTE ARM.  (appele aussi par run_si_gdb.sh --arm)
#
# Les SI n arrivent pas par le SB mais par le DATA_IND BCCH. Quatre bequilles
# s enchainent, toutes cote ARM / l1ctl :
#   CALYPSO_FORCE_TOA=23   bloc resultat FB/SB sur le read MMIO ARM (d_fb_det=1,
#                          a_sync TOA/ANGLE/SNR, a_serv_demod[D_TOA]) -> passe le
#                          FB et le controle « SB N bits in the future »
#   CALYPSO_FORCE_FBSB=1   FBSB_CONF force a SUCCESS (l1ctl_sock.c payload[18]->0)
#                          -> SANS ELLE le mobile n atteint JAMAIS le BCCH
#   CALYPSO_FORCE_NB=1     d_task_d != 0 -> l1s_nb_resp n abandonne plus sur
#                          « EMPTY » et le firmware EMET le DATA_IND
#   CALYPSO_FORCE_AGCH=1   remplit ce DATA_IND : sur BCCH il fait tourner le type
#                          de SI (0x19..0x1c), sur PCH il ecrase le L3 par un
#                          IMM ASSIGNMENT
#
# /!\ BEQUILLES. Elles prouvent que l AVAL du SB fonctionne (synchronisation,
# CCCH, SI) et RIEN sur le DSP : les SI obtenues ainsi ne sont pas decodees par
# le modele. A retirer quand le DSP publie un a_cd valide.
# /!\ En full-grgsm, run.sh VERROUILLE ces gates a 0 : il faut CALYPSO_MODE=native.
set -u
D="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${LOG_DIR:-/tmp/calypso/logs}"
. "$D/si_diag.sh"
RAPPORT="$LOG_DIR/si-arm-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee -a "$RAPPORT") 2>&1
echo "# rapport : $RAPPORT"
Q="$(pgrep -x qemu-system-arm | head -1)"
[ -n "$Q" ] || { echo "run_si_arm: aucun qemu-system-arm."; exit 1; }
_env() { tr '\0' '\n' < "/proc/$Q/environ" 2>/dev/null | sed -n "s/^$1=//p"; }
echo; echo "########## bequilles COTE ARM ##########"
manque=""
for g in CALYPSO_FORCE_TOA CALYPSO_FORCE_FBSB CALYPSO_FORCE_NB CALYPSO_FORCE_AGCH; do
    v="$(_env "$g")"
    if [ -n "$v" ] && [ "$v" != "0" ]; then printf '  %-22s = %-8s actif\n' "$g" "$v"
    else printf '  %-22s = %-8s MANQUANT\n' "$g" "${v:-<absent>}"; manque=oui; fi
done
if [ -n "$manque" ]; then
    cat <<'TXT'

  Les SI ne peuvent PAS arriver sans les QUATRE. Relance avec :

    cd /opt/GSM/qemu-src && CALYPSO_HOSTGDB=1 \
      CALYPSO_FORCE_TOA=23 CALYPSO_FORCE_FBSB=1 \
      CALYPSO_FORCE_NB=1 CALYPSO_FORCE_AGCH=1 \
      CALYPSO_FIXES=FIX_STL_STH_SHFT,FIX_LD_PARALLEL,FIX_LDM_ZEROEXT \
      CALYPSO_MODE=native CALYPSO_DSP_RUN_C54X=1 \
      CALYPSO_MAILBOX=1 CALYPSO_MAILBOX_ONLY=1 \
      CALYPSO_MAILBOX_RANGES=0x2a00-0x2b2f,0x2c56-0x2cf0,0x0060-0x0067,0x0837-0x084f \
      ./run.sh --reset

  /!\ BEQUILLES : elles prouvent l aval du SB, RIEN sur le DSP.
TXT
fi
diag_complet
