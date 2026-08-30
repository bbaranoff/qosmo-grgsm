# si.gdb — chemin instrumente vers les SI (System Information)
#
#   (gdb) source /opt/GSM/qemu-src/tools/si.gdb
#   (gdb) si_all
#
# Ou, sans client interactif, via le tube du mode CALYPSO_HOSTGDB=1 :
#   tools/gdbq.sh "source /opt/GSM/qemu-src/tools/si.gdb"
#   tools/gdbq.sh "si_all"
#
# POIGNEE : `bsp` est la statique de calypso_bsp.c, resolvable directement par
# gdb ; elle porte `bsp.dsp`, un C54xState*. Il n existe PAS de g_c54x.
#
# /!\ AVEC `target remote`, gdb NE PEUT PAS lire la memoire pendant que la
# cible tourne (« Cannot execute this command while the target is running »).
# TOUTE inspection exige donc un arret bref. Utilise `si_snap`, qui enchaine
# interrupt -> mesure -> continue &.
# Un arret de quelques secondes CASSE la synchro GSM du mobile : le mobile
# repart en L1CTL_RESET_REQ: FULL. C est acceptable pour lire des structures qui
# PERSISTENT (tampons, tables), jamais pour observer une acquisition en cours.
# Voir CHEMIN-SI-GDB.md.

set pagination off
set confirm off
set print pretty off

python
import struct

# data[] et prog[] sont des TABLEAUX dans C54xState, pas des pointeurs :
# int(gdb.parse_and_eval("bsp.dsp->data")) echoue avec « Cannot convert value
# to long ». Il faut prendre l ADRESSE du premier element.
# Plusieurs syntaxes selon comment gdb a resolu le type : on les essaie toutes
# plutot que de parier sur une seule, et on dit clairement laquelle a marche.
_BASES = {}
def _base(champ):
    if champ in _BASES:
        return _BASES[champ]
    essais = [
        "(unsigned long)&bsp.dsp->%s[0]" % champ,
        "(unsigned long)(bsp.dsp->%s)" % champ,
        "(unsigned long)&((struct C54xState *)bsp.dsp)->%s[0]" % champ,
        "(unsigned long)&((C54xState *)bsp.dsp)->%s[0]" % champ,
    ]
    derniere = None
    for e in essais:
        try:
            v = int(gdb.parse_and_eval(e))
            if v:
                _BASES[champ] = v
                return v
        except Exception as ex:
            derniere = ex
    raise gdb.GdbError(
        "si.gdb: impossible de resoudre l adresse de bsp.dsp->%s (%s).\n"
        "  Verifier que la cible est ARRETEE (interrupt) et que `p bsp.dsp` repond."
        % (champ, derniere))

def _lire(champ, mot, n):
    raw = gdb.selected_inferior().read_memory(_base(champ) + 2 * mot, 2 * n)
    return struct.unpack("<%dH" % n, raw.tobytes())

def _mem(mot, n):
    """Lit n mots de bsp.dsp->data a partir de l adresse DSP `mot`."""
    return _lire("data", mot, n)

def _prog_vu(mot, n):
    """Ce que prog_read() rend REELLEMENT, alias OVLY compris.

    /!\ Lire le tableau prog[] brut est un PIEGE : avec PMST.OVLY leve et une
    adresse dans [plancher..0x2800[, prog_read rend data[addr], pas prog[addr].
    Une sonde qui lit le tableau brut affiche 0xF4E4 (remplissage ROM) la ou
    l instruction, elle, lit le scratch-pad. C est ce qui m a fait annoncer a
    tort une divergence prog/data."""
    pmst = int(gdb.parse_and_eval("bsp.dsp->pmst"))
    ovly = bool(pmst & 0x20)
    brut = _lire("prog", mot, n)
    if ovly and 0x60 <= mot and mot + n <= 0x2800:
        return _mem(mot, n), brut, True
    return brut, brut, False

def _api(mot, n):
    """Lit la fenetre API telle que LE DSP la voit : api_ram[mot - 0x0800].

    /!\ Piege central de ce modele : pour une adresse >= 0x0800 le DSP lit
    api_ram[], tandis que l ARM lit data[]. Les deux peuvent DIVERGER, et lire
    le mauvais cote fait conclure a tort. On affiche donc toujours LES DEUX."""
    p = int(gdb.parse_and_eval("(unsigned long)bsp.dsp->api_ram"))
    if not p or mot < 0x0800:
        return None
    raw = gdb.selected_inferior().read_memory(p + 2 * (mot - 0x0800), 2 * n)
    return struct.unpack("<%dH" % n, raw.tobytes())

def _duo(mot, n):
    """Rend (data[], api_ram[], ecart) pour une adresse de la fenetre API."""
    d = _mem(mot, n)
    a = _api(mot, n)
    return d, a, (a is not None and tuple(d) != tuple(a))

def _s16(v):
    return v - 0x10000 if v & 0x8000 else v

def _stat(vals):
    s = [_s16(v) for v in vals]
    return len(set(s)), min(s), max(s), sum(abs(x) for x in s)

def _reg(nom):
    return int(gdb.parse_and_eval("bsp.dsp->%s" % nom))
end

# Auto-verification : la poignee se resout-elle ?
define si_check
python
try:
    d = _base("data"); p = _base("prog")
    n = int(gdb.parse_and_eval("bsp.dsp->insn_count"))
    print("si.gdb OK : data@0x%x  prog@0x%x  insn_count=%u" % (d, p, n))
    print("  data[0x2a00..0x2a03] = %s" % " ".join("%04x" % x for x in _mem(0x2A00, 4)))
except Exception as e:
    print("si.gdb KO : %s" % e)
    print("  La cible est-elle ARRETEE ? gdb ne lit pas la memoire en marche.")
end
end

# ---------------------------------------------------------------- etat brut
# Releve COMPLET : registres, mots d etat decodes, etat des boucles, compteurs.
define si_where
python
R = lambda n: int(gdb.parse_and_eval("bsp.dsp->%s" % n))
ar = [int(gdb.parse_and_eval("bsp.dsp->ar[%d]" % i)) for i in range(8)]
st0, st1, pmst = R("st0"), R("st1"), R("pmst")
a = R("a") & 0xFFFFFFFFFF; b = R("b") & 0xFFFFFFFFFF
print("--- PC / execution ---")
print("  PC=0x%04x  XPC=0x%02x  derniere insn executee : PC=0x%04x op=0x%04x"
      % (R("pc"), R("xpc"), R("last_exec_pc"), R("last_exec_op")))
print("  insn_count=%u  cycles=%u  SP=0x%04x" % (R("insn_count"), R("cycles"), R("sp")))
print("  NON IMPLEMENTE : %u rencontre(s), dernier opcode 0x%04x"
      % (R("unimpl_count"), R("last_unimpl")))
print("--- accumulateurs et registres ---")
print("  A=0x%010x  B=0x%010x  T=0x%04x (%d)  TRN=0x%04x"
      % (a, b, R("t"), _s16(R("t")), R("trn")))
for i in range(0, 8, 4):
    print("  " + "  ".join("AR%d=0x%04x" % (j, ar[j]) for j in range(i, i + 4)))
print("--- boucles ---")
print("  BK=0x%04x  BRC=0x%04x  RSA=0x%04x  REA=0x%04x  RPTB=%s"
      % (R("bk"), R("brc"), R("rsa"), R("rea"), "ACTIF" if R("rptb_active") else "-"))
print("  RPT : %s reste=%u sur PC=0x%04x   PAR=0x%04x%s"
      % ("ACTIF" if R("rpt_active") else "-", R("rpt_count"), R("rpt_pc"),
         R("par"), " (pose)" if R("par_set") else ""))
print("--- mots d etat ---")
f1 = [n for n, bit in (("CMPT",5),("FRCT",6),("C16",7),("SXM",8),("OVM",9),
                       ("INTM",11),("HM",12),("XF",13),("BRAF",14)) if st1 & (1 << bit)]
f0 = [n for n, bit in (("TC",12),("C",11),("OVA",10),("OVB",9)) if st0 & (1 << bit)]
fp = [n for n, bit in (("MP/MC",6),("OVLY",5),("AVIS",4),("DROM",3),
                       ("CLKOFF",2),("SMUL",1),("SST",0)) if pmst & (1 << bit)]
print("  ST0=0x%04x [%s]  ARP=%d  DP=0x%03x" % (st0, " ".join(f0) or "-",
                                                (st0 >> 13) & 7, st0 & 0x1FF))
print("  ST1=0x%04x [%s]" % (st1, " ".join(f1) or "-"))
print("  PMST=0x%04x [%s]  IPTR=0x%04x" % (pmst, " ".join(fp) or "-", (pmst >> 7) << 7))
print("  IMR=0x%04x  IFR=0x%04x  idle=%s" % (R("imr"), R("ifr"), bool(R("idle"))))
print("--- alimentation BSP ---")
print("  bsp_len=%d  bsp_pos=%d  writer_kind=%d"
      % (R("bsp_len"), R("bsp_pos"), R("writer_kind")))
end
end

# PC et opcodes seulement (releve rapide, repetable)
define si_pc
python
R = lambda n: int(gdb.parse_and_eval("bsp.dsp->%s" % n))
print("PC=0x%04x  last_exec: PC=0x%04x op=0x%04x  insn=%u  unimpl=%u (dernier 0x%04x)"
      % (R("pc"), R("last_exec_pc"), R("last_exec_op"), R("insn_count"),
         R("unimpl_count"), R("last_unimpl")))
end
end

# ------------------------------------------------- etape 1 : tampon de burst
define si_etape1_burst
python
n, mn, mx, e = _stat(_mem(0x2A00, 304))
nz = sum(1 for v in _mem(0x2A00, 304) if v)
print("[1] BURST 0x2a00 : %d/304 non nuls, %d valeurs distinctes, energie=%d, [%d..%d]"
      % (nz, n, e, mn, mx))
print("    verdict : %s" % ("VIVANT" if nz > 150 and e > 100000 else "MORT ou famine"))
end
end

# --------------------------------------------- etape 2 : sorties correlateur
define si_etape2_corr
python
for nom, base in (("A", 0x2C56), ("B", 0x2C88)):
    n, mn, mx, e = _stat(_mem(base, 50))
    verdict = "DISCRIMINE" if n >= 30 else ("FAIBLE" if n >= 10 else "DEGENERE (fenetre figee ?)")
    print("[2] CORR %s (0x%04x) : distinct=%2d/50 [%6d..%6d]  -> %s" % (nom, base, n, mn, mx, verdict))
end
end

# ------------------------------------- etape 3 : la banque des 7 blocs de 7
define si_etape3_blocs
python
for i, base in enumerate((0x2CC0, 0x2CC7, 0x2CCE, 0x2CD5, 0x2CDC, 0x2CE3, 0x2CEA), 1):
    v  = _mem(base, 7)
    nz = sum(1 for x in v if x)
    print("[3] bloc %d 0x%04x : %d/7 non nuls | %s" % (i, base, nz, " ".join("%04x" % x for x in v)))
print("    bloc 7 (0x2cea) = reference de correlation, attendue bipolaire +/-512 (0x0200/0xfe00)")
print("    blocs 3 et 4 (0x2cce/0x2cd5) = operandes des MAC qui produisent les coefficients")
end
end

# --------------------------------- etape 4 : coefficients du FIRS et sa source
define si_etape4_coef
python
pv, pbrut, alias = _prog_vu(0x61, 6)
dv   = _mem(0x0061, 6)
sv   = _mem(0x2CB9, 7)
nzp  = sum(1 for x in pv if x and x != 0xF4E4)
nzd  = sum(1 for x in dv if x)
print("[4] prog_read(0x61..0x66) = %s  (utiles=%d)%s"
      % (" ".join("%04x" % x for x in pv), nzp,
         "   [alias OVLY actif -> c est data[] que lit le FIRS]" if alias else ""))
print("    tableau prog[] brut      = %s   (sans interet si l alias est actif)"
      % " ".join("%04x" % x for x in pbrut))
print("    data[0x61..0x66] = %s  (utiles=%d)" % (" ".join("%04x" % x for x in dv), nzd))
print("    SOURCE MVDD data[0x2cb9..] = %s" % " ".join("%04x" % x for x in sv))
if nzd:   print("    verdict : coefficients presents dans le SCRATCH-PAD")
elif nzp: print("    verdict : coefficients en memoire PROGRAMME")
else:     print("    verdict : TABLE INTROUVABLE -- le FIRS multiplie par du vide")
end
end

# ---------------------------------------------- etape 5 : blocs resultat FB/SB
# Correspondance : l ARM lit data[offset/2 + 0x0800]. db_r page0 = offset 0x50,
# page1 = offset 0x78. a_sch[] occupe les mots 15..19 du bloc db_r dans LES DEUX
# variantes de dsp_api.h, d ou p0 = 0x0837..0x083b et p1 = 0x084b..0x084f.
# a_serv_demod[D_TOA] = offset 0x60 (p0) / 0x88 (p1) -> mots 0x0830 / 0x0844.
define si_etape5_sb
python
for pg, asch, atoa in ((0, 0x0837, 0x0830), (1, 0x084B, 0x0844)):
    a = _mem(asch, 5)
    t = _mem(atoa, 1)[0]
    sb = a[3] | (a[4] << 16)
    crc = 1 if (a[0] & 0x0100) else 0
    # /!\ Ce SB est ce qui SERAIT assemble si la garde passait. Avec CRC=1 le
    # firmware abandonne AVANT : ce n est pas un SB accepte, juste un calcul.
    print("[5] page %d : a_sch = %s | B_SCH_CRC=%d | SB(hypothetique)=0x%08x | D_TOA=0x%04x%s"
          % (pg, " ".join("%04x" % x for x in a), crc, sb, t,
             "  <- REFUSE par la garde" if crc else ""))
print("    prim_fbsb.c : si a_sch[0] & (1<<8) -> abandon AVANT d assembler le SB")
print("                  sinon sb = a_sch[3] | a_sch[4] << 16")
end
end

# ------------------------------------------------- LE CHEMIN DSP COMPLET
# Onze sauts, du burst livre par le BSP jusqu au SB lu par l ARM. Chaque saut
# porte l adresse du code qui l execute et la cellule qu il produit ; on affiche
# l etat de cette cellule pour voir OU la chaine se rompt.
define si_chemin
python
def bloc(v):
    nz = sum(1 for x in v if x)
    return nz, " ".join("%04x" % x for x in v[:8])

R = lambda n: int(gdb.parse_and_eval("bsp.dsp->%s" % n))
print("=========== CHEMIN DSP COMPLET ===========")

nz, _ = bloc(_mem(0x2A00, 304))
print(" 1. BSP -> DARAM 0x2a00        | bsp_len=%d pos=%d | %d/304 non nuls  %s"
      % (R("bsp_len"), R("bsp_pos"), nz, "OK" if nz > 150 else "<< ROMPU"))

c, cbrut, alias = _prog_vu(0x61, 6)
nzc = sum(1 for x in c if x)
pmst = int(gdb.parse_and_eval("bsp.dsp->pmst"))
print(" 2. banc FIRS 0x8336..0x8493   | coefficients LUS PAR LE FIRS = %s  %s"
      % (" ".join("%04x" % x for x in c), "OK" if nzc else "<< ROMPU (table vide)"))
print("                               | PMST=0x%04x OVLY=%d DROM=%d | alias programme->data : %s"
      % (pmst, 1 if pmst & 0x20 else 0, 1 if pmst & 0x08 else 0,
         "ACTIF" if alias else "INACTIF (le FIRS lirait la ROM)"))

a = _mem(0x2C56, 50); b = _mem(0x2C88, 50)
da = len(set(_s16(x) for x in a)); db = len(set(_s16(x) for x in b))
print(" 3. correlateur 0x84a2..0x84c6 | A distinct=%d/50  B distinct=%d/50  %s"
      % (da, db, "OK" if da > 20 and db > 20 else "<< ROMPU (fenetre figee)"))

n3, v3 = bloc(_mem(0x2CCE, 7)); n4, v4 = bloc(_mem(0x2CD5, 7))
print(" 4. MVDD 0x7ce0/0x7ce4         | bloc3 %d/7 : %s" % (n3, v3))
print("                               | bloc4 %d/7 : %s  %s"
      % (n4, v4, "OK" if n3 and n4 else "<< ROMPU (ecrases a zero)"))

print(" 5. MPY 0x81e4 + ST|| 0x81e5-e6| T=0x%04x A CET INSTANT (PC=0x%04x)"
      % (R("t"), R("pc")))
print("                               | pas de verdict : ce qui compte est T EN 0x81e4,")
print("                               | que seul si_break_mpy peut lire (mesure : T=0)")

n6, v6 = bloc(_mem(0x2CBA, 6))
print(" 6. 0x8202 -> source coef      | 0x2cba..0x2cbf %d/6 : %s  %s"
      % (n6, v6, "OK" if n6 else "<< ROMPU"))

print(" 7. MVDD 0x833c -> scratch-pad | data[0x60..0x66] = %s"
      % " ".join("%04x" % x for x in _mem(0x0060, 7)))

n8, v8 = bloc(_mem(0x2A00, 8))
print(" 8. bits souples (sth *AR6+)   | AR6=0x%04x  debut 0x2a00 : %s" % (R("ar")[6] if False else int(gdb.parse_and_eval("bsp.dsp->ar[6]")), v8))

# /!\ 0x08fe est DANS la fenetre API : le DSP y lit api_ram[0xfe], l ARM lit
# data[0x08fe]. Lire un seul cote fait conclure a tort — on montre les deux.
d, a, ecart = _duo(0x08FE, 5)
print(" 9. SCH 0x9841 / Viterbi 0x9a78| source a_sch, LES DEUX COTES du miroir :")
print("      data[0x08fe..] (vu ARM) = %s" % " ".join("%04x" % x for x in d))
print("      api_ram[0xfe..] (vu DSP)= %s%s"
      % (" ".join("%04x" % x for x in a) if a else "<api_ram absent>",
         "   << ECART : le DSP ne voit PAS ce que l ARM voit" if ecart else ""))

for pg, asch in ((0, 0x0837), (1, 0x084B)):
    d, a, ecart = _duo(asch, 5)
    sb = d[3] | (d[4] << 16)
    print("10. copie a_sch 0xb214 page %d | data= %s | CRC=%d | SB=0x%08x%s"
          % (pg, " ".join("%04x" % x for x in d), 1 if d[0] & 0x0100 else 0, sb,
             "  << ECART data/api" if ecart else ""))
    if a:
        print("                               | api = %s" % " ".join("%04x" % x for x in a))

ed, ea, _e = _duo(0x08D5, 1)
err = (ea[0] if ea else ed[0])
noms = [n for n, m in (("RHEA",1),("IQ_SAMPLES",4),("DMA_PROG",8),
                       ("DMA_TASK",0x10),("DMA_PEND",0x20),("VM",0x80)) if err & m]
print("11. d_error_status 0xb10a     | 0x%04x [%s]  (data=0x%04x api=%s)"
      % (err, " ".join(noms) or "-", ed[0], "0x%04x" % ea[0] if ea else "-"))
print("==========================================")
end
end

# ------------------------------------------------------------------ synthese
# si_snap : la commande a utiliser en pratique — arret, mesure, reprise.
define si_snap
interrupt
si_all
continue &
end

define si_all
printf "===== chemin vers les SI : ou la chaine casse-t-elle ? =====\n"
si_etape1_burst
si_etape2_corr
si_etape3_blocs
si_etape4_coef
si_etape5_sb
si_chemin
printf "===========================================================\n"
si_where
end

# ------------------------------- LA SOUSTRACTION QUI ANNULE LE DIVIDENDE
# Mesure : A vaut 7 en 0x7d14 puis 0 en 0x7d17. Entre les deux, deux
# instructions d un mot (binutils) :
#     0x7d15  101f   LD  *(0x1f), A
#     0x7d16  0806   SUB *(0x06), A
# Donc A = data[DP:0x1f] - data[DP:0x06]. Si ce resultat est nul, le SUBC qui
# suit divise zero et rend un quotient nul, d ou T=0 et toute la cascade.
# /!\ Lire les deux cellules PLUS TARD ne prouve RIEN : elles bougent. Il faut
#     les lire AU POINT D ARRET, ce que fait si_sub.
define si_break_sub
break data_write if s->pc == 0x7d17
printf "arret pose sur le STL A de 0x7d17 ; a chaque arret : si_sub\n"
end

define si_sub
python
R = lambda n: int(gdb.parse_and_eval("bsp.dsp->%s" % n))
dp   = R("st0") & 0x1FF
base = dp << 7
x = _mem(base | 0x1F, 1)[0]
y = _mem(base | 0x06, 1)[0]
a = R("a") & 0xFFFFFFFFFF
try:    val = int(gdb.parse_and_eval("val")) & 0xFFFF
except Exception: val = -1
att = (_s16(x) - _s16(y)) & 0xFFFF
print("DP=0x%03x -> base=0x%04x" % (dp, base))
print("  data[0x%04x]=0x%04x  -  data[0x%04x]=0x%04x  =  0x%04x (attendu)"
      % (base | 0x1F, x, base | 0x06, y, att))
print("  A reel = 0x%010x (bas 16 = 0x%04x)   ecrit = 0x%04x" % (a, a & 0xFFFF, val))
if att == 0:
    print("  VERDICT : les deux cellules sont EGALES -> dividende nul LEGITIMEMENT.")
    print("            Le defaut est chez le PRODUCTEUR de ces deux cellules.")
elif (a & 0xFFFF) != att:
    print("  VERDICT : ECART. Le modele rend 0x%04x la ou la soustraction donne" % (a & 0xFFFF))
    print("            0x%04x -> defaut du LD ou du SUB (adressage direct DP ?)." % att)
else:
    print("  VERDICT : la soustraction est correcte ; remonter aux deux cellules.")
end
end

# --------------------------------------- LE QUOTIENT QUI ALIMENTE T
# Toute la cascade tient a T=0 au MPY de 0x81e4. Or T ne vient PAS de cette
# zone : le desassemblage de l appelant donne
#     0x7d1c  RPT #15
#     0x7d1d  SUBC *(0x0b), A     ; division en 16 pas
#     0x7d1e  STL  A, *(0x0a)     ; le QUOTIENT
#     0x7d21  LD   *(0x0a), T     ; <- T est charge ICI
#     0x7d24  CALLD 0x81df        ; sous-programme du MPY, qui n ecrit jamais T
# Donc : quotient nul -> T nul -> produit nul -> blocs 3-4 ecrases -> source des
# coefficients vide -> scratch vide -> FIRS multiplie par du vide -> CRC arme.
# Une cause, quatre symptomes.
#   dividende non nul et quotient nul -> defaut du SUBC ou de son ordonnancement
#   dividende deja nul                -> remonter encore d un cran
define si_break_quotient
break data_write if s->pc == 0x7d1e
printf "arret pose sur le STL du quotient (0x7d1e).\n"
printf "  a chaque arret : si_quotient\n"
end

define si_quotient
python
R = lambda n: int(gdb.parse_and_eval("bsp.dsp->%s" % n))
a = R("a") & 0xFFFFFFFFFF
dp = R("st0") & 0x1FF
try:
    dst = int(gdb.parse_and_eval("addr")); val = int(gdb.parse_and_eval("val"))
except Exception:
    dst = val = -1
# adressage direct C54x : adresse = (DP << 7) | offset(0..127)
print("PC=0x%04x  STL A -> data[0x%04x] = 0x%04x   (DP=0x%03x)"
      % (R("pc"), dst & 0xFFFF, val & 0xFFFF, dp))
print("  A=0x%010x  (bas 16 bits = 0x%04x)  T actuel=0x%04x" % (a, a & 0xFFFF, R("t")))
diviseur = _mem((dp << 7) | 0x0B, 1)[0]
print("  diviseur data[DP:0x0b] = 0x%04x" % diviseur)
if (val & 0xFFFF) == 0:
    print("  VERDICT : quotient NUL -> T sera nul -> toute la cascade suit.")
    print("            Dividende (A) %s, diviseur %s."
          % ("non nul" if a else "NUL", "non nul" if diviseur else "NUL"))
else:
    print("  VERDICT : quotient NON NUL -> T devrait etre bon ; verifier 0x7d21.")
end
end

# ------------------------------------------------- LA MESURE QUI COUPE LE NOEUD
# Sur les sites qui ecrivent ZERO (0x833c vers le scratch, 0x8202 vers la source
# des coefficients), separer DEFINITIVEMENT les deux familles d hypotheses :
#   accumulateur != 0 et valeur ecrite = 0  -> BUG DE STORE dans l emulateur
#       (cote ST src,Ymem : Ymem = (src << ASM) >> 16 ; un ASM faux suffit)
#   accumulateur = 0                        -> le defaut est EN AMONT (T, etc.)
# ASM est ST1[4:0], un decalage SIGNE sur 5 bits. 0x81e3 fait `LD #1, ASM` juste
# avant les stores paralleles : la valeur ecrite est donc (A << 1) >> 16, ce qui
# rend ZERO des que A est petit -- et ce serait LEGITIME. D ou l interet de voir
# les deux ensemble.
define si_break_store
break data_write if s->pc == 0x833c || s->pc == 0x8202 || s->pc == 0x81e5 || s->pc == 0x81e6
printf "arret pose sur les ecrivains a zero (0x833c, 0x8202, 0x81e5-e6)\n"
printf "  a chaque arret : si_store\n"
end

define si_store
python
R = lambda n: int(gdb.parse_and_eval("bsp.dsp->%s" % n))
st1 = R("st1")
asm = st1 & 0x1F
if asm & 0x10: asm -= 0x20            # 5 bits signes
a = R("a") & 0xFFFFFFFFFF; b = R("b") & 0xFFFFFFFFFF
try:
    dst = int(gdb.parse_and_eval("addr")); val = int(gdb.parse_and_eval("val"))
except Exception:
    dst = val = -1
def _st(acc):
    v = acc - (1 << 40) if acc & (1 << 39) else acc
    return ((v << asm) >> 16) & 0xFFFF if asm >= 0 else ((v >> -asm) >> 16) & 0xFFFF
print("PC=0x%04x  dst=0x%04x  ecrit=0x%04x" % (R("pc"), dst & 0xFFFF, val & 0xFFFF))
print("  A=0x%010x -> (A<<ASM)>>16 = 0x%04x" % (a, _st(a)))
print("  B=0x%010x -> (B<<ASM)>>16 = 0x%04x" % (b, _st(b)))
print("  ASM=%d  T=0x%04x  ST1=0x%04x" % (asm, R("t"), st1))
if val == 0 and (a or b):
    print("  VERDICT : accumulateur NON NUL mais ecriture NULLE.")
    print("            Si (acc<<ASM)>>16 vaut 0 aussi, le store est CORRECT et")
    print("            l accumulateur est simplement trop petit -> defaut EN AMONT.")
    print("            Sinon c est un BUG DE STORE.")
elif val == 0:
    print("  VERDICT : accumulateur NUL -> le defaut est EN AMONT (T ?).")
end
end

# /!\ si_force_coef seul NE TESTE RIEN : l injection est ecrasee avant que le
# FIRS ne lise (mesure : @0x833c ecrit 66 zeros, @0x8202 en ecrit 314, APRES
# l injection). Pour que l experience ait un sens il faut injecter A L ENTREE
# DU BANC puis reprendre. C est ce que fait si_inject_firs.
define si_inject_firs
# L injection doit avoir lieu a l ENTREE DU BANC (0x8336, le STM #0x0060,AR2
# du prologue), pas au MVDD 0x833c qui la recouvre aussitot.
break data_write if s->pc == 0x8336 || s->pc == 0x833c
commands
silent
python
COEF = [0x0800, 0x1000, 0x2000, 0x2000, 0x1000, 0x0800]
inf = gdb.selected_inferior()
inf.write_memory(_base("data") + 2 * 0x0061, struct.pack("<6H", *COEF))
end
continue
end
printf "injection ARMEE : a chaque passage en 0x833c les coefficients sont\n"
printf "  reposes puis l execution reprend. C est la SEULE facon de les avoir\n"
printf "  presents au moment ou le FIRS les lit.\n"
printf "  /!\\ BEQUILLE, et lente (un arret par passage).\n"
end

# ------------------------------------------------------------- FORCAGE (BEQUILLE)
# @BEQUILLE — si_force_sb
#   masque  : le DSP emule ne produit pas de resultat SB (a_sch reste nul, car la
#             chaine correlateur -> coefficients FIRS est cassee en amont).
#   ce que  : ecrit DIRECTEMENT un bloc a_sch plausible dans les deux pages de
#   ca fait   l API, efface le bit B_SCH_CRC, et pose a_serv_demod[D_TOA] = 23
#             (la valeur « a l heure » attendue par prim_fbsb.c, qui fait toa -= 23).
#             Le firmware assemble alors un vrai SB, en tire un BSIC, se
#             synchronise, arme le CCCH et peut recevoir les SI.
#   ce que  : que TOUT L AVAL du SB fonctionne (sync, CCCH, SI). Cela n apprend
#   ca prouve RIEN sur le DSP : les SI obtenues ainsi ne sont PAS decodees par le
#             modele, elles sont la consequence d une valeur qu on a ecrite.
#   retirer : quand a_sch est renseigne par le DSP lui-meme, c est-a-dire quand
#             si_etape4_coef cesse de dire TABLE INTROUVABLE.
#
#   (gdb) si_force_sb          # BSIC par defaut 0x3f
#   (gdb) si_force_sb 0x2a     # BSIC choisi
#
# /!\ UN SEUL COUP : le DSP reecrit ces cellules a chaque trame. Pour tenir, il
# faut repeter — c est ce que fait `run_si_gdb.sh --forcer`.
define si_force_sb
python
bsic = 0x3F
try:
    a = gdb.parse_and_eval("$arg0")
    bsic = int(a) & 0x3F
except Exception:
    pass
base = _base("data")
inf  = gdb.selected_inferior()
# SB GSM : 25 bits d information. On fabrique un mot coherent porteur du BSIC.
sb  = (bsic & 0x3F) | (1 << 6)
lo  = sb & 0xFFFF
hi  = (sb >> 16) & 0xFFFF
for asch, atoa in ((0x0837, 0x0830), (0x084B, 0x0844)):
    cur = struct.unpack("<5H", inf.read_memory(base + 2*asch, 10).tobytes())
    neuf = [cur[0] & ~0x0100, cur[1], cur[2], lo, hi]     # bit 8 = B_SCH_CRC efface
    inf.write_memory(base + 2*asch, struct.pack("<5H", *neuf))
    inf.write_memory(base + 2*atoa, struct.pack("<H", 23))
print("[BEQUILLE] a_sch injecte sur les 2 pages : SB=0x%08x (BSIC=%d), CRC efface, D_TOA=23"
      % (sb, bsic))
print("           /!\ ceci ne prouve QUE l aval ; le DSP n a rien decode.")
end
end

# @BEQUILLE — si_force_coef
#   masque  : la table de coefficients du banc FIRS, que le DSP ne produit pas
#             (chaine 0x81e4 -> 0x8202 -> 0x833c cassee par T=0).
#   ce que  : ecrit un jeu SYMETRIQUE plausible dans data[0x0061..0x0066] ET
#   ca fait   dans la source du MVDD data[0x2cba..0x2cbf], pour que le FIRS
#             filtre avec quelque chose plutot qu avec du vide.
#   ce que  : que TOUT L AVAL du filtre fonctionne (bits souples, Viterbi,
#   ca prouve parite, a_sch). Cela n apprend RIEN sur la production des
#             coefficients elle-meme.
#   retirer : quand si_etape4_coef cesse de dire TABLE INTROUVABLE tout seul.
# /!\ Le DSP reecrit ces cellules a chaque trame : il faut REPETER.
define si_force_coef
python
# jeu symetrique normalise en Q15 (somme = 0x8000)
COEF = [0x0800, 0x1000, 0x2000, 0x2000, 0x1000, 0x0800]
base = _base("data")
inf  = gdb.selected_inferior()
inf.write_memory(base + 2 * 0x0061, struct.pack("<6H", *COEF))
# la source du MVDD est lue en DESCENDANT depuis 0x2cbf : on la pose retournee
inf.write_memory(base + 2 * 0x2CBA, struct.pack("<6H", *reversed(COEF)))
print("[BEQUILLE] coefficients injectes : data[0x61..0x66] et data[0x2cba..0x2cbf]")
print("           %s" % " ".join("%04x" % c for c in COEF))
print("           /!\\ ceci ne prouve QUE l aval du filtre.")
end
end

# -------------------------------------------------------- arrets (INVASIFS)
# /!\ Ces commandes FIGENT QEMU. La synchro GSM du mobile ne survit pas a une
# pause de quelques secondes : a reserver au diagnostic, jamais pendant une
# acquisition qu on veut voir aboutir.

# Le MPY qui doit produire les coefficients (dst = T * Smem).
define si_break_mpy
break data_write if addr >= 0x2cce && addr <= 0x2cdb && s->pc >= 0x81e5 && s->pc <= 0x81e6
printf "arret pose sur l ecrasement des blocs 3/4 par les stores paralleles\n"
printf "  a chaque arret : si_where  (T doit etre NON NUL pour que le mpy produise)\n"
end

# Qui met T a zero ?
define si_watch_t
watch bsp.dsp->t if bsp.dsp->t == 0
printf "watchpoint pose : arret quand T DEVIENT nul ; lire ensuite si_where\n"
end

# Une cellule precise de la reference de correlation.
define si_watch_ref
watch bsp.dsp->data[0x2ceb]
printf "watchpoint pose sur la reference de correlation data[0x2ceb]\n"
end

printf "si.gdb charge. Commandes : si_all | si_where | si_etape1_burst ..\n"
printf "  si_etape2_corr | si_etape3_blocs | si_etape4_coef | si_etape5_sb\n"
printf "  si_where = releve COMPLET (registres, etats, boucles, compteurs)\n"
printf "  si_pc    = PC + derniere insn + compteur d opcodes non implementes\n"
printf "  si_check = auto-verification de la poignee bsp.dsp\n"
printf "  si_chemin = LE CHEMIN DSP COMPLET, 11 sauts, avec le point de rupture\n"
printf "  si_snap = interrupt + si_all + continue &  (LA commande pratique)\n"
printf "  INVASIF (fige QEMU) : si_break_mpy | si_watch_t | si_watch_ref\n"
printf "  MESURE DECISIVE     : si_break_sub + si_sub  (le dividende)\n"
printf "                        si_break_quotient + si_quotient\n"
printf "                        si_break_store   + si_store     (le store)\n"
printf "  BEQUILLE            : si_force_sb [bsic] | si_force_coef | si_inject_firs\n"
