#!/bin/sh
# gdbq.sh — envoyer une commande au gdb attache au MODELE (CALYPSO_HOSTGDB=1).
#
# Le client gdb lit ses commandes sur un tube nomme et ecrit ses reponses dans
# un journal ; on envoie, on attend, on rend le delta du journal. Sans ce
# script il faudrait manipuler le tube a la main et deviner ou commence la
# reponse.
#
# /!\ `interrupt` FIGE QEMU. La synchro GSM du mobile ne survit pas a une pause
# de quelques secondes : a reserver aux structures qui PERSISTENT (tampons,
# tables), jamais a l observation d une acquisition en cours. Le script
# n interrompt PAS tout seul : c est a l appelant de le demander.
#
# POIGNEE : `bsp` (statique de calypso_bsp.c) est resolvable directement par gdb
# et porte `bsp.dsp`, un C54xState*. Tout part de la. Il n existe PAS de g_c54x.
#
#   gdbq.sh "p bsp.dsp->ar[2]"                   # un registre d adresse
#   gdbq.sh "p/x bsp.dsp->data[0x0061]@6"        # les coefficients du FIRS
#   gdbq.sh "p bsp.bursts_written"               # compteur de livraison BSP
#   gdbq.sh "interrupt"
#   gdbq.sh "x/50xh &bsp.dsp->data[0x2c88]"      # tampon B du correlateur
#   gdbq.sh "continue &"
set -u
RUN_DIR="${RUN_DIR:-/tmp/calypso}"
LOG_DIR="${LOG_DIR:-$RUN_DIR/logs}"
GIN="$RUN_DIR/gdb.in"
GOUT="$LOG_DIR/gdb.log"
[ -p "$GIN" ] || { echo "gdbq: $GIN absent — le run tourne-t-il avec CALYPSO_HOSTGDB=1 ?" >&2; exit 1; }
[ $# -ge 1 ] || { echo "usage: gdbq.sh \"<commande gdb>\"" >&2; exit 2; }
avant=$(wc -c < "$GOUT" 2>/dev/null || echo 0)
printf '%s\n' "$*" > "$GIN"
i=0
while [ "$i" -lt "${GDBQ_TIMEOUT:-30}" ]; do
    sleep 0.3
    apres=$(wc -c < "$GOUT" 2>/dev/null || echo 0)
    if [ "$apres" -gt "$avant" ]; then
        sleep 0.4                      # laisser la reponse se terminer
        tail -c "+$((avant + 1))" "$GOUT"
        exit 0
    fi
    i=$((i + 1))
done
echo "gdbq: pas de reponse en ${GDBQ_TIMEOUT:-30} tours — la cible tourne-t-elle ? (essayez \"interrupt\")" >&2
exit 3
