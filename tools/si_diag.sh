# si_diag.sh — module de diagnostic commun aux scripts SI.
#   . "$(dirname "$0")/si_diag.sh"   puis   diag_complet
#
# Quatre sources, quatre points de vue sur la meme chaine :
#   qemu.log     le MODELE  : gates, sondes, erreurs DSP, opcodes non implementes
#   osmocon.log  le FIRMWARE: FB, SB, synchronisation, resets
#   mobile.log   la COUCHE 3: cellule, sysinfo, MM/CC, location update
#   mailbox.log  la MEMOIRE : qui ecrit quoi, et avec quelles valeurs
#
# Aucune de ces lectures ne fige QEMU : ce sont des journaux.

LOG_DIR="${LOG_DIR:-/tmp/calypso/logs}"
# mailbox.log atteint plusieurs centaines de Mo : on n en depouille que la fin.
MBX_FENETRE="${MBX_FENETRE:-60000000}"

_titre() { printf '\n===== %s =====\n' "$1"; }
# /!\ `grep -c` IMPRIME "0" ET sort en erreur quand il ne trouve rien : un
# `|| echo 0` ajoutait donc un SECOND zero. On neutralise le code de sortie.
_n()     { { grep -c "$1" "$2" 2>/dev/null; } || true; }
_ni()    { { grep -ci "$1" "$2" 2>/dev/null; } || true; }

# --------------------------------------------------------------- le run
diag_run() {
    _titre "RUN"
    local q g
    q="$(pgrep -x qemu-system-arm | head -1)"
    if [ -z "$q" ]; then echo "  aucun qemu-system-arm en cours"; return 1; fi
    g="$(pgrep -x gdbserver | head -1)"
    printf '  qemu=%s  gdbserver=%s  age=%ss\n' "$q" "${g:-<absent>}" \
        "$(ps -o etimes= -p "$q" | tr -d ' ')"
    printf '  binaire : %s\n' "$(stat -L -c %y "/proc/$q/exe" 2>/dev/null)"
    printf '  LOG_DIR : %s\n' "$(tr '\0' '\n' < "/proc/$q/environ" 2>/dev/null | sed -n 's/^LOG_DIR=//p')"
    echo "  -- reglage d amplitude (PAS un defaut : l attenuation AGC manquante) --"
    local sh dec toa
    sh="$(tr '\0' '\n' < "/proc/$q/environ" 2>/dev/null | sed -n 's/^CALYPSO_BSP_IQ_SHIFT=//p')"
    dec="$(tr '\0' '\n' < "/proc/$q/environ" 2>/dev/null | sed -n 's/^CALYPSO_BSP_IQ_DECIM=//p')"
    # modes.env : le firmware vise CAL_DSP_TGT_BB_LVL=80 alors que la chaine
    # injecte a pleine echelle (+/-32766). Sans attenuation le correlateur FCCH
    # SATURE et rend un TOA aberrant. 32766>>8=128, >>9=64 (cible 80).
    # Le bon reglage est un A/B entre 7, 8 et 9 ; juge = TOA stable autour de 39.
    if [ -z "$sh" ] || [ "$sh" = "0" ]; then
        printf '    /!\\ CALYPSO_BSP_IQ_SHIFT=%s : AUCUNE attenuation -> le correlateur\n' "${sh:-<absent>}"
        printf '        FCCH SATURE (entree ~400x trop forte) et le TOA devient aberrant.\n'
        printf '        Essayer 7, 8 ou 9 ; juge = TOA stable autour de 39.\n'
    else
        printf '    CALYPSO_BSP_IQ_SHIFT=%s -> pleine echelle 32766 ramenee a %s (cible 80)\n' \
            "$sh" "$((32766 >> sh))"
    fi
    [ -n "$dec" ] && printf '    CALYPSO_BSP_IQ_DECIM=%s\n' "$dec"
    toa="$(grep -oE '^FB1 \([0-9]+:[0-9]+\): TOA= *[0-9-]+' "$LOG_DIR/osmocon.log" 2>/dev/null \
           | grep -oE '[0-9-]+$' | sort -n | uniq -c | sort -rn | head -3 | tr '\n' ' ')"
    [ -n "$toa" ] && printf '    TOA les plus vus (juge du reglage, cible ~39) : %s\n' "$toa"
    echo "  gates poses :"
    tr '\0' '\n' < "/proc/$q/environ" 2>/dev/null \
        | grep -E '^CALYPSO_(ISA|FORCE|OVLY|MAILBOX|HOSTGDB|FIXES|MODE|BSP|SHUNT)' \
        | sort | sed 's/^/    /'
}

# ------------------------------------------------------------ le modele
diag_qemu() {
    local f="$LOG_DIR/qemu.log"
    _titre "MODELE (qemu.log)"
    [ -r "$f" ] || { echo "  absent"; return; }
    echo "  -- correctifs ISA annonces au demarrage --"
    grep -hoE '\[c54x\] ISA-[A-Z0-9-]+ [A-Z]+' "$f" 2>/dev/null | sort -u | sed 's/^/    /'
    grep -m1 'OVLY-SCRATCH' "$f" 2>/dev/null | cut -c1-100 | sed 's/^/    /'
    echo "  -- sondes actives --"
    grep -hoE '\[c54x\] [A-Z-]+ (ACTIVE|ACTIF)' "$f" 2>/dev/null | sort -u | sed 's/^/    /'
    grep -m1 'mailbox. couverture' "$f" 2>/dev/null | cut -c1-160 | sed 's/^/    /'
    echo "  -- sante du DSP --"
    printf '    opcodes NON IMPLEMENTES : %s occurrence(s)\n' "$(_n 'UNIMPL @' "$f")"
    grep -hoE 'UNIMPL @0x[0-9a-f]+: 0x[0-9a-f]+' "$f" 2>/dev/null \
        | sort | uniq -c | sort -rn | head -5 | sed 's/^/      /'
    printf '    erreurs DSP publiees    : %s\n' "$(_n 'DSP Error Status' "$LOG_DIR/osmocon.log")"
    grep -hoE 'DSP Error Status: [0-9]+' "$LOG_DIR/osmocon.log" 2>/dev/null \
        | sort | uniq -c | sort -rn | head -4 | sed 's/^/      /'
    echo "  -- bequilles cote ARM : ou la chaine des SI casse-t-elle ? --"
    local gf ga di
    gf="$(_n 'GATE-FBSB' "$f")"; ga="$(_n 'GATE-AGCH' "$f")"
    di="$(_ni 'data_ind' "$LOG_DIR/osmocon.log")"
    printf '    FORCE_TOA annonce=%s | GATE-FBSB=%s | DATA_IND=%s | GATE-AGCH=%s\n' \
        "$(_n 'CALYPSO_FORCE_TOA=' "$f")" "$gf" "$di" "$ga"
    if [ "${gf:-0}" = "0" ]; then
        echo "    -> FBSB_CONF jamais force : le mobile n atteint pas le BCCH."
    elif [ "${di:-0}" = "0" ]; then
        echo "    -> FBSB force, mais AUCUN DATA_IND : FORCE_AGCH ne peut pas tirer"
        echo "       (il ne s active que sur payload[0]==0x03). Le blocage est en"
        echo "       amont, cote FORCE_NB / l1s_nb_resp."
    elif [ "${ga:-0}" = "0" ]; then
        echo "    -> DATA_IND emis mais AGCH ne tire pas : verifier chan_nr (0x80 BCCH)."
    else
        echo "    -> chaine complete : les SI devraient apparaitre en couche 3."
    fi
}

# ----------------------------------------------------------- le firmware
diag_osmocon() {
    local f="$LOG_DIR/osmocon.log"
    _titre "FIRMWARE (osmocon.log)"
    [ -r "$f" ] || { echo "  absent"; return; }
    printf '  chaine FB -> SB -> sync :\n'
    printf '    FBSB_REQ=%s  FB0=%s  FB1=%s  Synchronize_TDMA=%s\n' \
        "$(_n 'L1CTL_FBSB_REQ' "$f")" "$(grep -cE '^FB0 ' "$f" 2>/dev/null)" \
        "$(grep -cE '^FB1 ' "$f" 2>/dev/null)" "$(_n 'Synchronize_TDMA' "$f")"
    # prim_fbsb.c l1s_sbdet_resp : le garde CRC fait `return 0` AVANT tout
    # printf. Donc l ABSENCE de ligne SB est le signal du refus, et une ligne
    # « SB 0x00000000 » signifie au contraire que le CRC est ACCEPTE mais que
    # a_sch[3]|a_sch[4]<<16 est vide. Deux etats a ne pas confondre.
    local nsb
    nsb="$(grep -cE '^SB[0-9]' "$f" 2>/dev/null || true)"
    printf '    ^SB=%s  => SB=%s  valeurs SB : %s\n' \
        "$nsb" "$(_n '=> SB' "$f")" \
        "$(grep -oE '=> SB 0x[0-9a-f]+' "$f" 2>/dev/null | sort -u | tr '\n' ' ')"
    if [ "${nsb:-0}" = "0" ]; then
        echo "    -> AUCUNE ligne SB : le garde CRC refuse (a_sch[0] bit 8 arme),"
        echo "       ou la tache SB n est jamais programmee. Ce n est PAS un SB nul."
    else
        echo "    -> des lignes SB existent : le CRC est ACCEPTE au moins parfois ;"
        echo "       un SB a 0x00000000 est alors une charge utile vide, pas un refus."
    fi
    printf '    BSIC non nul=%s  RESET FULL=%s  « bits in the future »=%s\n' \
        "$(grep -oE 'BSIC=[0-9]+' "$f" 2>/dev/null | grep -cv 'BSIC=0$')" \
        "$(_n 'L1CTL_RESET_REQ: FULL' "$f")" "$(_n 'in the future' "$f")"
    printf '    DATA_IND=%s  BCCH=%s  PM MEAS=%s\n' \
        "$(_ni 'data_ind' "$f")" "$(_ni 'bcch' "$f")" "$(_n 'PM MEAS' "$f")"
    echo "  -- 4 derniers evenements marquants --"
    grep -nE '^(FB|SB)[0-9]|=> SB|Synchronize_TDMA|L1CTL_RESET_REQ: FULL|in the future' "$f" 2>/dev/null \
        | tail -4 | cut -c1-130 | sed 's/^/    /'
}

# ----------------------------------------------------------- la couche 3
diag_mobile() {
    local f="$LOG_DIR/mobile.log"
    _titre "COUCHE 3 (mobile.log)"
    [ -r "$f" ] || { echo "  absent"; return; }
    # /!\ « sysinfo » compte aussi « No sysinfo yet » : c est un FAUX POSITIF.
    # Le vrai temoin de reception des SI est BCCH / ccch mode, pas ce mot.
    # /!\ Ne PAS compter le mot « sysinfo » : il apparait dans « No sysinfo yet »
    # ET dans « free sysinfo ARFCN=... » (liberation apres echec). Les deux sont
    # des ECHECS. Le seul temoin positif d une SI recue est le decodage d un
    # SYSTEM INFORMATION, ou a defaut un DATA_IND BCCH.
    printf '  SI reellement decodees=%s  cell=%s  MM=%s  CC=%s  RR=%s\n' \
        "$(grep -acE 'SYSTEM INFORMATION|si_type|sysinfo [0-9]|SI[0-9]+ ' "$f" 2>/dev/null || true)" \
        "$(_ni 'cell' "$f")" \
        "$(_n ' MM ' "$f")" "$(_n ' CC ' "$f")" "$(_n ' RR ' "$f")"
    printf '  location update : demande=%s  ACCEPT=%s  REJECT=%s\n' \
        "$(_ni 'location updating request\|LOCATION UPDATING REQUEST' "$f")" \
        "$(_ni 'location update accepted\|LOCATION UPDATING ACCEPT' "$f")" \
        "$(_ni 'location updating reject' "$f")"
    printf '  ccch mode : %s\n' \
        "$(grep -oiE 'ccch mode [A-Z]+' "$f" 2>/dev/null | sort | uniq -c | sort -rn | head -3 | tr '\n' ' ')"
    printf '  echecs : « No sysinfo yet »=%s  « free sysinfo »=%s  « Channel sync error »=%s\n' \
        "$(grep -aci 'no sysinfo yet' "$f" 2>/dev/null || true)" \
        "$(grep -aci 'free sysinfo' "$f" 2>/dev/null || true)" \
        "$(grep -aci 'channel sync error' "$f" 2>/dev/null || true)"
    echo "  -- 4 dernieres lignes couche 3 --"
    grep -iE 'sysinfo|cell|location updat' "$f" 2>/dev/null | tail -4 \
        | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-130 | sed 's/^/    /'
}

# ------------------------------------------------------------ la memoire
diag_mailbox() {
    local f="$LOG_DIR/mailbox.log"
    _titre "MEMOIRE (mailbox.log — ecrivains par zone du chemin DSP)"
    [ -r "$f" ] || { echo "  absent"; return; }
    printf '  taille=%s o, depouillement des %s derniers o\n' "$(wc -c < "$f")" "$MBX_FENETRE"
    tail -c "$MBX_FENETRE" "$f" | python3 -c '
import sys, collections
ZONES = [("burst 0x2a00",     0x2A00, 0x2B2F), ("corr A 0x2c56",  0x2C56, 0x2C87),
         ("corr B 0x2c88",    0x2C88, 0x2CB9), ("src coef 0x2cba", 0x2CBA, 0x2CBF),
         ("blocs 3-4 0x2cce", 0x2CCE, 0x2CDB), ("reference 0x2cea",0x2CEA, 0x2CF0),
         ("scratch 0x0060",   0x0060, 0x0067), ("src a_sch 0x08fe",0x08FE, 0x0902),
         ("a_sch p0 0x0837",  0x0837, 0x083B), ("a_sch p1 0x084b", 0x084B, 0x084F),
         ("d_error 0x08d5",   0x08D5, 0x08D5)]
W = collections.defaultdict(lambda: collections.defaultdict(lambda: [0, 0]))
R = collections.Counter()
for ln in sys.stdin:
    f = ln.split()
    if len(f) < 5 or not f[3].startswith("0x"): continue
    try: a = int(f[3], 16)
    except ValueError: continue
    for nom, lo, hi in ZONES:
        if lo <= a <= hi:
            if "WR" in f[2] and len(f) >= 8:
                e = W[nom][f[-1]]; e[0] += 1
                if f[6] != "0x0000": e[1] += 1
            elif "RD" in f[2]: R[nom] += 1
            break
for nom, lo, hi in ZONES:
    if nom not in W and not R[nom]:
        print("    %-20s : hors des plages surveillees" % nom); continue
    ecr = sorted(W[nom].items(), key=lambda kv: -kv[1][0])[:3]
    det = "  ".join("%s %d/%d nn" % (pc, v[0], v[1]) for pc, v in ecr)
    print("    %-20s : %7d lect. | %s" % (nom, R[nom], det or "aucun ecrivain"))
' 2>/dev/null || echo "    (depouillement impossible)"
}

# --------------------------------------------- l ORDRE, que l agregat perd
# L agregat par ecrivain ne dit PAS qui ecrit en DERNIER. Or c est ce qui
# tranche entre « init puis remplissage » et « remplissage puis destruction ».
# Exemple mesure : @0x833a ecrit 52 valeurs non nulles et @0x833c 66 zeros dans
# la MEME zone -- selon l ordre, l un initialise et l autre remplit, ou l inverse.
diag_ordre() {
    local f="$LOG_DIR/mailbox.log"
    _titre "ORDRE CHRONOLOGIQUE (dernier ecrivain par cellule)"
    [ -r "$f" ] || { echo "  absent"; return; }
    tail -c "$MBX_FENETRE" "$f" | python3 -c '
import sys, collections
CIBLES = [("scratch coef", 0x0061, 0x0066), ("src coef", 0x2CBA, 0x2CBF),
          ("blocs 3-4",    0x2CCE, 0x2CDB)]
dernier = {}
seq = collections.defaultdict(list)
for ln in sys.stdin:
    f = ln.split()
    if len(f) < 8 or "WR" not in f[2] or not f[3].startswith("0x"): continue
    try: a = int(f[3], 16)
    except ValueError: continue
    for nom, lo, hi in CIBLES:
        if lo <= a <= hi:
            dernier[a] = (f[-1], f[6])
            if len(seq[nom]) < 12: seq[nom].append((f[-1], f[6]))
            break
for nom, lo, hi in CIBLES:
    print("  %s :" % nom)
    if not seq[nom]:
        print("      aucune ecriture dans la fenetre (zone surveillee ?)"); continue
    print("      12 premieres : %s" % "  ".join("%s=%s" % (p, v) for p, v in seq[nom]))
    for a in range(lo, hi + 1):
        if a in dernier:
            p, v = dernier[a]
            print("      DERNIER sur 0x%04x : %s ecrit %s%s" % (a, p, v,
                  "   <- ecrase a zero" if v == "0x0000" else ""))
' 2>/dev/null || echo "    (depouillement impossible)"
}

diag_complet() { diag_run; diag_qemu; diag_osmocon; diag_mobile; diag_mailbox; diag_ordre; }
