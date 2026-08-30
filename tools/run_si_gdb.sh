#!/bin/bash
# run_si_gdb.sh — releve automatise du chemin vers les SI, via gdb.
#
#   tools/run_si_gdb.sh              # un releve complet, puis reprise
#   tools/run_si_gdb.sh --repete 5   # 5 releves espaces de 10 s
#   tools/run_si_gdb.sh --intervalle 30 --repete 4
#   tools/run_si_gdb.sh --etape 4    # une seule etape (1..5)
#   tools/run_si_gdb.sh --gel        # laisse QEMU FIGE a la fin (pour enchainer)
#   tools/run_si_gdb.sh --reset      # supprime d abord les points laisses avant
#   tools/run_si_gdb.sh --all        # les deux forcages + lecture croisee
#   tools/run_si_gdb.sh --arm        # forcage COTE ARM (bequilles l1ctl)
#   tools/run_si_gdb.sh --dsp        # injection COTE DSP (coefficients, a_sch)
#   tools/run_si_gdb.sh --si         # OBTENIR les SI : verifie les bequilles,
#                                    # donne la ligne exacte si elles manquent,
#                                    # puis surveille leur arrivee
#   tools/run_si_gdb.sh --forcer --repete 20 --intervalle 2
#                                    # BEQUILLE : injecte un SB a chaque tour
#                                    # pour faire avancer le firmware jusqu aux SI
#
# POURQUOI CE SCRIPT. Trois pieges rendent le releve manuel penible, et il les
# absorbe tous :
#   1. avec `target remote`, gdb NE PEUT PAS lire la memoire pendant que la
#      cible tourne : il faut interrompre, lire, reprendre ;
#   2. le client gdb lit ses commandes sur un TUBE et repond dans un JOURNAL :
#      il faut memoriser la taille du journal avant, pour ne rendre que le delta ;
#   3. si le script echoue au milieu, QEMU reste FIGE. Ici un trap garantit la
#      reprise, sauf --gel explicite ;
#   4. LE PIEGE PRINCIPAL : chaque `printf > tube` OUVRE puis REFERME le tube.
#      Quand le dernier ecrivain ferme, gdb voit un EOF sur son entree et CESSE
#      DE LIRE — le canal est mort en silence, et toute commande suivante reste
#      sans reponse. Le script tient donc le tube ouvert sur le descripteur 9
#      pendant toute sa duree, et reamorce un gardien permanent s il manque.
#
# /!\ Chaque releve FIGE QEMU une seconde ou deux. La synchro GSM du mobile n y
# survit pas : il repart en L1CTL_RESET_REQ: FULL. C est sans consequence pour
# lire des structures qui PERSISTENT (tampons, tables, coefficients), mais on ne
# peut PAS observer ainsi une acquisition en train d aboutir.
#
# Prerequis : le run doit tourner avec CALYPSO_HOSTGDB=1.

set -u

# --- aiguillage vers les deux modes specialises ----------------------------
# run_si_gdb.sh est le point d entree unique :
#   --arm  -> forcage COTE ARM   (bequilles l1ctl/read MMIO : FORCE_TOA/FBSB/NB/AGCH)
#   --dsp  -> injection COTE DSP (coefficients FIRS, bloc a_sch, via gdb)
# sans option : le releve du chemin, sans rien forcer.
_D="$(cd "$(dirname "$0")" && pwd)"
case "${1:-}" in
    --arm) shift; exec "$_D/run_si_arm.sh" "$@" ;;
    --dsp) shift; exec "$_D/run_si_dsp.sh" "$@" ;;
    --all)
        # Les deux forcages a la suite, dans CET ordre : ARM d abord (il ne
        # touche pas au DSP et ne fige pas QEMU), DSP ensuite (il injecte et
        # fige). L inverse fausserait la mesure ARM.
        shift
        echo "############################################################"
        echo "###  1/2  FORCAGE COTE ARM  (bequilles l1ctl / read MMIO) ###"
        echo "############################################################"
        "$_D/run_si_arm.sh"
        echo
        echo "############################################################"
        echo "###  2/2  INJECTION COTE DSP  (coefficients FIRS, a_sch)  ###"
        echo "############################################################"
        "$_D/run_si_dsp.sh" "$@"
        echo
        echo "############################################################"
        echo "###  LECTURE CROISEE                                     ###"
        echo "############################################################"
        echo "  SI presentes avec --arm mais PAS avec --dsp seul :"
        echo "    l aval du SB est sain, le DSP ne produit rien -> defaut DSP."
        echo "  SI absentes DANS LES DEUX :"
        echo "    un blocage subsiste en aval du SB (verifier les 4 bequilles ARM)."
        echo "  a_sch perd son bit CRC apres injection DSP :"
        echo "    le filtre et le Viterbi sont sains, seule la PRODUCTION des"
        echo "    coefficients est en cause."
        exit 0 ;;
esac

RUN_DIR="${RUN_DIR:-/tmp/calypso}"
LOG_DIR="${LOG_DIR:-$RUN_DIR/logs}"
GIN="$RUN_DIR/gdb.in"
GOUT="$LOG_DIR/gdb.log"
SIGDB="${SIGDB:-/opt/GSM/qemu-src/tools/si.gdb}"

REPETE=1
INTERVALLE=10
ETAPE=""
GEL=0
RESET=0
FORCER=0
MODE_SI=0
ATTENTE="${ATTENTE:-16}"          # tours de 0,5 s max pour une reponse gdb

while [ $# -gt 0 ]; do
    case "$1" in
        --repete)     REPETE="$2"; shift 2 ;;
        --intervalle) INTERVALLE="$2"; shift 2 ;;
        --etape)      ETAPE="$2"; shift 2 ;;
        --gel)        GEL=1; shift ;;
        --reset)      RESET=1; shift ;;
        --forcer)     FORCER=1; shift ;;
        --si)         MODE_SI=1; shift ;;
        -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "option inconnue : $1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- barrieres
if [ ! -p "$GIN" ]; then
    echo "run_si_gdb: $GIN absent." >&2
    echo "  Le run tourne-t-il avec CALYPSO_HOSTGDB=1 ?" >&2
    exit 1
fi
if [ ! -r "$SIGDB" ]; then
    echo "run_si_gdb: $SIGDB introuvable." >&2
    exit 1
fi
QPID="$(pgrep -x qemu-system-arm | head -1)"
if [ -z "$QPID" ]; then
    echo "run_si_gdb: aucun qemu-system-arm en cours." >&2
    exit 1
fi
. "$_D/si_diag.sh"
RAPPORT="${RAPPORT:-$LOG_DIR/si-releve-$(date +%Y%m%d-%H%M%S).txt}"
exec > >(tee -a "$RAPPORT") 2>&1
echo "# rapport archive dans $RAPPORT"
echo "# qemu=$QPID  age=$(ps -o etimes= -p "$QPID" | tr -d ' ')s"
echo "# binaire : $(stat -L -c %y "/proc/$QPID/exe" 2>/dev/null)"

# --- le canal de commandes -------------------------------------------------
# Un gardien PERMANENT doit tenir le tube ouvert en ecriture entre deux runs du
# script, sinon gdb voit un EOF des que le script se termine et ne lira plus
# jamais rien. On le reamorce s il a disparu.
if ! pgrep -f "sleep 2147483647 > $GIN" >/dev/null 2>&1 \
   && ! pgrep -f "sleep infinity > $GIN" >/dev/null 2>&1; then
    echo "# gardien du tube absent -> reamorcage"
    setsid sh -c "exec sleep 2147483647 > '$GIN'" </dev/null >/dev/null 2>&1 &
    sleep 0.3
fi
# Et le script tient lui-meme le tube ouvert pendant toute sa duree.
exec 9> "$GIN"

# La reprise est garantie meme si on sort en catastrophe.
reprendre() { [ "$GEL" = "1" ] || printf 'continue &\n' >&9 2>/dev/null; }
trap 'reprendre' EXIT INT TERM

# envoie une commande et rend le DELTA du journal
gdbq() {
    _avant=$(wc -c < "$GOUT" 2>/dev/null || echo 0)
    printf '%s\n' "$1" >&9
    _i=0
    while [ "$_i" -lt "$ATTENTE" ]; do
        sleep 0.5
        _apres=$(wc -c < "$GOUT" 2>/dev/null || echo 0)
        if [ "$_apres" -gt "$_avant" ]; then
            sleep 0.5                      # laisser la reponse se terminer
            tail -c "+$((_avant + 1))" "$GOUT" | grep -vE '^\(gdb\) *$|^$'
            return 0
        fi
        _i=$((_i + 1))
    done
    echo "  [pas de reponse a: $1]" >&2
    echo "  -> le client gdb ne lit plus. Verifier :" >&2
    echo "       pgrep -af 'gdb -q -nx'      (le client est-il vivant ?)" >&2
    echo "       tail -5 $GOUT               (a-t-il quitte sur EOF ?)" >&2
    echo "     Si le client est mort, relancer le run avec CALYPSO_HOSTGDB=1." >&2
    return 3
}

# --- nettoyage des points laisses par un essai precedent --------------------
if [ "$RESET" = "1" ]; then
    echo "# --reset : suppression des points d arret et de surveillance"
    gdbq "delete" > /dev/null 2>&1
fi

# ------------------------------------------------------------- chargement
# On recharge A CHAQUE FOIS : `source` est idempotent, et ne recharger qu une
# fois signifierait ne jamais prendre les corrections apportees a si.gdb.
echo "# chargement de $SIGDB"
gdbq "source $SIGDB" | sed 's/^/  /'
gdbq "interrupt" > /dev/null 2>&1
gdbq "si_check" | sed 's/^/  /' 

CMD="si_all"
[ -n "$ETAPE" ] && case "$ETAPE" in
    1) CMD="si_etape1_burst" ;; 2) CMD="si_etape2_corr" ;;
    3) CMD="si_etape3_blocs" ;; 4) CMD="si_etape4_coef" ;;
    5) CMD="si_etape5_sb"   ;;
    *) echo "etape inconnue : $ETAPE (1..5)" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------- mode --si
# Les SI n arrivent PAS par le SB : elles arrivent par le DATA_IND BCCH.
# Trois bequilles s enchainent, dans cet ordre, et le code de l emulateur les
# documente lui-meme :
#   CALYPSO_FORCE_TOA=23  bloc resultat FB/SB cote read ARM (d_fb_det=1,
#                         a_sync TOA/ANGLE/SNR, a_serv_demod[D_TOA]) -> passe le
#                         FB et le controle « SB N bits in the future ».
#   CALYPSO_FORCE_FBSB=1  force FBSB_CONF a SUCCESS (l1ctl_sock.c : payload[18]
#                         -> 0). SANS ELLE le mobile echoue a l etape FBSB et
#                         n atteint JAMAIS le BCCH : les trois autres bequilles
#                         ne servent alors a rien.
#   CALYPSO_FORCE_NB=1    d_task_d != 0 -> l1s_nb_resp n abandonne plus sur
#                         « EMPTY » et le firmware EMET le DATA_IND BCCH.
#   CALYPSO_FORCE_AGCH=1  remplit ce DATA_IND avec un SI / IMM-ASS.
# Ce sont des BEQUILLES : elles prouvent que l aval fonctionne, et RIEN sur le
# DSP. Les SI obtenues ainsi ne sont pas decodees par le modele.
if [ "$MODE_SI" = "1" ]; then
    echo
    echo "########## mode --si : obtenir les SI ##########"
    env_run() { tr '\0' '\n' < "/proc/$QPID/environ" 2>/dev/null | grep "^$1=" | cut -d= -f2-; }
    manque=""
    for g in CALYPSO_FORCE_TOA CALYPSO_FORCE_FBSB CALYPSO_FORCE_NB CALYPSO_FORCE_AGCH; do
        v="$(env_run "$g")"
        if [ -n "$v" ] && [ "$v" != "0" ]; then
            printf '  %-22s = %-6s  actif\n' "$g" "$v"
        else
            printf '  %-22s = %-6s  MANQUANT\n' "$g" "${v:-<absent>}"
            manque="oui"
        fi
    done
    if [ -n "$manque" ]; then
        echo
        echo "  Les SI ne peuvent PAS arriver sans ces trois bequilles."
        echo "  Relance le run avec (en gardant tes autres gates) :"
        echo
        echo "    cd /opt/GSM/qemu-src && CALYPSO_HOSTGDB=1 \\"
        echo "      CALYPSO_FORCE_TOA=23 CALYPSO_FORCE_FBSB=1 \\"
        echo "      CALYPSO_FORCE_NB=1 CALYPSO_FORCE_AGCH=1 \\"
        echo "      CALYPSO_MODE=native CALYPSO_DSP_RUN_C54X=1 \\"
        echo "      CALYPSO_ISA_A0_ADD=1 CALYPSO_ISA_DUAL_MPY=1 \\"
        echo "      CALYPSO_ISA_MPY_SMEM=1 CALYPSO_OVLY_SCRATCH=1 \\"
        echo "      CALYPSO_MAILBOX=1 CALYPSO_MAILBOX_ONLY=1 \\"
        echo "      CALYPSO_MAILBOX_RANGES=0x2a00-0x2b2f,0x2c56-0x2cf0,0x0060-0x0067 \\"
        echo "      ./run.sh --reset"
        echo
        echo "  /!\\ En mode full-grgsm, run.sh VERROUILLE ces gates a 0 (assignation"
        echo "      dure puis export) : les poser en ligne de commande n a alors AUCUN"
        echo "      effet. Il faut CALYPSO_MODE=native."
        echo
        echo "  /!\\ BEQUILLES : elles prouvent que l aval du SB fonctionne"
        echo "      (synchronisation, CCCH, SI) et RIEN sur le DSP. Les SI"
        echo "      obtenues ainsi ne sont pas decodees par le modele."
    else
        echo "  Les trois bequilles sont actives : surveillance de l arrivee des SI."
    fi
    echo
    o="$LOG_DIR/osmocon.log"
    echo "  etat actuel des journaux :"
    echo "    (preuves attendues dans qemu.log : GATE-FBSB #1 / GATE-AGCH #2 bcch)"
    printf '    GATE-FBSB=%s  GATE-AGCH=%s\n' \
        "$(grep -c 'GATE-FBSB' "$LOG_DIR/qemu.log" 2>/dev/null)" \
        "$(grep -c 'GATE-AGCH' "$LOG_DIR/qemu.log" 2>/dev/null)"
    printf '    DATA_IND=%s  BCCH=%s  sysinfo=%s  BSIC non nul=%s\n' \
        "$(grep -ci 'data_ind' "$o" 2>/dev/null)" \
        "$(grep -ci 'bcch' "$o" 2>/dev/null)" \
        "$(grep -ciE 'sysinfo|system information|SI[0-9] ' "$o" 2>/dev/null)" \
        "$(grep -oE 'BSIC=[0-9]+' "$o" 2>/dev/null | grep -cv 'BSIC=0$')"
    [ -n "$manque" ] && { trap - EXIT; exit 0; }
fi

# ------------------------------------------------------------- les releves
n=1
while [ "$n" -le "$REPETE" ]; do
    echo
    echo "########## releve $n/$REPETE  —  $(date +%H:%M:%S) ##########"
    gdbq "interrupt" > /dev/null 2>&1
    [ "$FORCER" = "1" ] && gdbq "si_force_sb"
    gdbq "$CMD"
    if [ -z "$ETAPE" ]; then
        echo "--- etat complet du DSP ---"
        gdbq "si_where"
    fi
    # etat cote journaux, gratuit et non invasif
    if [ -r "$LOG_DIR/osmocon.log" ]; then
        printf '[6] osmocon : Sync=%s  ^SB=%s  => SB=%s  RESET FULL=%s\n' \
            "$(grep -c Synchronize_TDMA "$LOG_DIR/osmocon.log")" \
            "$(grep -cE '^SB[0-9]' "$LOG_DIR/osmocon.log")" \
            "$(grep -c '=> SB' "$LOG_DIR/osmocon.log")" \
            "$(grep -c 'L1CTL_RESET_REQ: FULL' "$LOG_DIR/osmocon.log")"
        sb="$(grep -oE '=> SB 0x[0-9a-f]+' "$LOG_DIR/osmocon.log" | sort -u | tr '\n' ' ')"
        [ -n "$sb" ] && printf '    valeurs SB vues : %s\n' "$sb"
        printf '[7] SI      : BSIC=%s  sysinfo=%s  CCCH=%s\n' \
            "$(grep -c 'BSIC=' "$LOG_DIR/osmocon.log")" \
            "$(grep -icE 'sysinfo|system information|SI[0-9]' "$LOG_DIR/osmocon.log")" \
            "$(grep -icE 'ccch|bcch' "$LOG_DIR/osmocon.log")"
    fi
    # --- depouillement du mailbox : les ECRIVAINS de chaque cellule du chemin.
    # Gratuit et non invasif : c est de la lecture de journal, QEMU n est pas
    # fige pour ca. Ne rend rien si les plages ne sont pas couvertes par
    # CALYPSO_MAILBOX_RANGES — ce qui est une information en soi.
    if [ -r "$LOG_DIR/mailbox.log" ]; then
        echo "--- ecrivains vus par le mailbox ---"
        python3 - "$LOG_DIR/mailbox.log" <<'PYEOF'
import sys, collections
ZONES = [("burst 0x2a00",        0x2A00, 0x2B2F),
         ("src a_sch 0x08fe",    0x08FE, 0x0902),
         ("a_sch p0 0x0837",     0x0837, 0x083B),
         ("a_sch p1 0x084b",     0x084B, 0x084F),
         ("d_error 0x08d5",      0x08D5, 0x08D5),
         ("corr A 0x2c56",       0x2C56, 0x2C87),
         ("corr B 0x2c88",       0x2C88, 0x2CB9),
         ("src coef 0x2cba",     0x2CBA, 0x2CBF),
         ("blocs 3-4 0x2cce",    0x2CCE, 0x2CDB),
         ("reference 0x2cea",    0x2CEA, 0x2CF0),
         ("scratch 0x0060",      0x0060, 0x0067)]
W = collections.defaultdict(lambda: collections.defaultdict(lambda: [0, 0]))
R = collections.Counter()
for ln in open(sys.argv[1], errors="ignore"):
    f = ln.split()
    if len(f) < 5 or not f[3].startswith("0x"):
        continue
    try:
        a = int(f[3], 16)
    except ValueError:
        continue
    for nom, lo, hi in ZONES:
        if lo <= a <= hi:
            if "WR" in f[2] and len(f) >= 8:
                e = W[nom][f[-1]]
                e[0] += 1
                if f[6] != "0x0000":
                    e[1] += 1
            elif "RD" in f[2]:
                R[nom] += 1
            break
for nom, lo, hi in ZONES:
    if nom not in W and not R[nom]:
        print("  %-20s : hors des plages surveillees" % nom)
        continue
    ecr = sorted(W[nom].items(), key=lambda kv: -kv[1][0])[:3]
    det = "  ".join("%s %d ecr/%d non nulles" % (pc, v[0], v[1]) for pc, v in ecr)
    print("  %-20s : %6d lectures | %s" % (nom, R[nom], det or "aucun ecrivain"))
PYEOF
    fi
    [ "$GEL" = "1" ] && [ "$n" = "$REPETE" ] || gdbq "continue &" > /dev/null 2>&1
    n=$((n + 1))
    [ "$n" -le "$REPETE" ] && sleep "$INTERVALLE"
done

diag_complet
echo
if [ "$GEL" = "1" ]; then
    echo "# QEMU laisse FIGE (--gel). Reprendre avec :  echo 'continue &' > $GIN"
    trap - EXIT
else
    echo "# QEMU repris."
fi
