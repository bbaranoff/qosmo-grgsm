#!/bin/bash
# run_si_dsp.sh — SI forcees COTE DSP, par injection gdb dans la memoire du modele.
#
# Difference avec run_si_arm.sh : ici on ne touche PAS au firmware ni au chemin
# l1ctl. On injecte dans le DSP lui-meme, la ou sa chaine est rompue, et on
# regarde jusqu ou elle repart toute seule. C est un diagnostic, pas un mode
# de fonctionnement.
#
# Deux points d injection, du plus amont au plus aval :
#   si_force_coef  la table de coefficients du banc FIRS (data[0x61..0x66] et
#                  la source du MVDD 0x2cba..0x2cbf). Si les bits souples
#                  redeviennent sains, tout l aval (Viterbi, parite, a_sch)
#                  doit suivre SANS autre aide -> le defaut est bien en amont.
#   si_force_sb    le bloc a_sch lui-meme, si l on veut court-circuiter aussi
#                  le decodeur SCH (option --sb).
#
# /!\ Le DSP reecrit ces cellules a CHAQUE TRAME (4,6 ms) : l injection doit
# etre repetee, et elle ne « tiendra » jamais parfaitement. Un taux de reussite
# partiel est le resultat attendu, pas un echec.
# /!\ Chaque injection FIGE QEMU une seconde : la synchro GSM n y survit pas.
#
#   run_si_dsp.sh                 # injecte les coefficients, 12 tours
#   run_si_dsp.sh --sb            # injecte AUSSI le bloc a_sch
#   run_si_dsp.sh --tours 30 --pause 1
set -u
D="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="${RUN_DIR:-/tmp/calypso}"
LOG_DIR="${LOG_DIR:-$RUN_DIR/logs}"
GIN="$RUN_DIR/gdb.in"; GOUT="$LOG_DIR/gdb.log"
SIGDB="${SIGDB:-/opt/GSM/qemu-src/tools/si.gdb}"
. "$D/si_diag.sh"
TOURS=12; PAUSE=2; AUSSI_SB=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tours) TOURS="$2"; shift 2 ;;
    --pause) PAUSE="$2"; shift 2 ;;
    --sb)    AUSSI_SB=1; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "option inconnue : $1" >&2; exit 2 ;;
  esac
done
[ -p "$GIN" ] || { echo "run_si_dsp: $GIN absent — le run tourne-t-il avec CALYPSO_HOSTGDB=1 ?" >&2; exit 1; }
QPID="$(pgrep -x qemu-system-arm | head -1)"
[ -n "$QPID" ] || { echo "run_si_dsp: aucun qemu-system-arm." >&2; exit 1; }
RAPPORT="$LOG_DIR/si-dsp-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee -a "$RAPPORT") 2>&1
echo "# rapport : $RAPPORT"
echo "# qemu=$QPID  binaire : $(stat -L -c %y /proc/$QPID/exe)"
pgrep -f "sleep 2147483647 > $GIN" >/dev/null 2>&1 || \
  setsid sh -c "exec sleep 2147483647 > '$GIN'" </dev/null >/dev/null 2>&1 &
sleep 0.3
exec 9> "$GIN"
trap 'printf "continue &\n" >&9 2>/dev/null' EXIT INT TERM
env_q() { A=$(wc -c < "$GOUT"); printf '%s\n' "$1" >&9; i=0
  while [ $i -lt 16 ]; do sleep 0.4
    B=$(wc -c < "$GOUT"); [ "$B" -gt "$A" ] && { sleep 0.3
      tail -c "+$((A+1))" "$GOUT" | grep -vE '^\(gdb\) *$|^$'; return 0; }
    i=$((i+1)); done; echo "  [muet]"; }
env_q "source $SIGDB" >/dev/null
echo
echo "########## injection COTE DSP : $TOURS tours ##########"
echo "/!\\ BEQUILLE : prouve l aval du filtre, RIEN sur la production des coefficients."
n=1
while [ "$n" -le "$TOURS" ]; do
  env_q "interrupt" >/dev/null
  [ "$n" = 1 ] && env_q "si_force_coef" | sed 's/^/  /'
  [ "$n" != 1 ] && env_q "si_force_coef" >/dev/null
  [ "$AUSSI_SB" = 1 ] && env_q "si_force_sb" >/dev/null
  if [ $((n % 4)) = 0 ] || [ "$n" = "$TOURS" ]; then
    echo "--- tour $n ---"
    env_q "si_etape4_coef" | sed 's/^/  /'
    env_q "si_etape5_sb"   | sed 's/^/  /'
    printf '  osmocon : Sync=%s  ^SB=%s  => SB=%s | SI: sysinfo=%s BCCH=%s\n' \
      "$(grep -c Synchronize_TDMA "$LOG_DIR/osmocon.log" 2>/dev/null)" \
      "$(grep -cE '^SB[0-9]' "$LOG_DIR/osmocon.log" 2>/dev/null)" \
      "$(grep -c '=> SB' "$LOG_DIR/osmocon.log" 2>/dev/null)" \
      "$(grep -ciE 'sysinfo|system information' "$LOG_DIR/osmocon.log" 2>/dev/null)" \
      "$(grep -ci 'bcch' "$LOG_DIR/osmocon.log" 2>/dev/null)"
  fi
  env_q "continue &" >/dev/null
  n=$((n + 1)); sleep "$PAUSE"
done
echo
diag_complet
echo
echo "# QEMU repris. Lecture : si a_sch perd son bit CRC apres injection, le"
echo "# defaut est bien la production des coefficients, et l aval est sain."
