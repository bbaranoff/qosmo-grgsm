# Chemin gdb vers les SI — mode d'emploi

Comment aller, pas à pas, du burst reçu jusqu'aux *System Information*, en
inspectant le modèle DSP à chaud avec gdb, et quelle trace QEMU laisse à chaque
étape.

## Mise en route

Le run doit tourner avec `CALYPSO_HOSTGDB=1` — c'est ce qui lance QEMU **sous
gdbserver** et attache un client gdb permanent piloté par un tube nommé.

```bash
cd /opt/GSM/qemu-src && CALYPSO_HOSTGDB=1 \
  CALYPSO_MAILBOX=1 CALYPSO_MAILBOX_ONLY=1 \
  CALYPSO_MAILBOX_RANGES=0x2cc0-0x2cf0,0x2cba-0x2cbf,0x0060-0x0067 \
  CALYPSO_MODE=native CALYPSO_DSP_RUN_C54X=1 ... ./run.sh --reset
```

Puis, à tout moment :

```bash
tools/run_si_gdb.sh                          # un relevé complet des 5 étapes
tools/run_si_gdb.sh --repete 5 --intervalle 20
tools/run_si_gdb.sh --etape 4                # une seule étape
tools/run_si_gdb.sh --reset                  # purge les points laissés avant
```

En interactif, `source tools/si.gdb` puis `si_snap`.

**Pourquoi `gdbserver` lance QEMU et ne s'y attache pas** : le conteneur a
`cap_sys_ptrace` retiré et `ptrace_scope=1` n'autorise qu'un parent à tracer son
propre fils. `gdb -p` et `gdbserver --attach` échouent tous deux. `--multi` a été
écarté après essai : il ne transmet pas les arguments à l'inférieur.

## La chaîne, étape par étape

La poignée est **`bsp`**, la statique de `calypso_bsp.c`, qui porte `bsp.dsp`
(un `C54xState*`). Il n'existe pas de `g_c54x`.

| # | étape | commande | lecture attendue | trace QEMU / osmocon |
|---|---|---|---|---|
| 1 | le burst arrive en DARAM | `si_etape1_burst` | `0x2a00` : >150/304 non nuls, énergie > 10⁵ | `[BSP] DARAM-FCCH-ONLY` au démarrage |
| 2 | le corrélateur discrimine | `si_etape2_corr` | `A(0x2c56)` et `B(0x2c88)` : `distinct` proche de 50/50 | — |
| 3 | la banque des 7 blocs | `si_etape3_blocs` | bloc 7 (`0x2cea`) bipolaire `±512` ; blocs 3 et 4 non nuls | `SCRATCH-WR` si les plages mailbox les couvrent |
| 4 | coefficients du FIRS | `si_etape4_coef` | `data[0x61..0x66]` non nuls | `FIRS-COEF`, `MPY-SMEM` |
| 5 | résultat SB lu par l'ARM | `si_etape5_sb` | `B_SCH_CRC=0` et `SB` non nul | `SB1 (fn:tn): TOA=…` puis `=> SB 0x…: BSIC=…` |
| 6 | synchronisation | *(journal)* | — | `Synchronize_TDMA` |
| 7 | SI | *(journal)* | — | `BSIC=`, `sysinfo`, `CCCH` dans `osmocon.log` |

Les étapes 6 et 7 sont gratuites : `run_si_gdb.sh` les compte directement dans
`osmocon.log`, sans figer QEMU.

### Correspondance des adresses

L'ARM lit `data[offset/2 + 0x0800]` ; le DSP lit `api_ram[addr − 0x0800]`.
`db_r` page 0 = offset `0x50`, page 1 = offset `0x78`. `a_sch[]` occupe les mots
15 à 19 du bloc `db_r` dans **les deux** variantes de `dsp_api.h` :

```
a_sch[0..4]            page 0 : 0x0837..0x083b     page 1 : 0x084b..0x084f
a_serv_demod[D_TOA]    page 0 : 0x0830             page 1 : 0x0844
```

`prim_fbsb.c` abandonne si `a_sch[0] & (1<<8)` (`B_SCH_CRC`), sinon il assemble
`sb = a_sch[3] | a_sch[4] << 16`.

## Où la chaîne casse aujourd'hui

Étapes 1, 2 et 3 **passent**. Le blocage est à l'étape 4 :

```
burst 0x2a00 (296/304 non nuls)                                   ✓
  → corrélateur : distinct 50/50                                  ✓
  → MVDD 0x7ce0/0x7ce4 : 231 copies, 231 non nulles → blocs 3 et 4 ✓
  → ⚠️ 0x81e4 : MPY Smem,dst avec T = 0  →  A = 0
  → 0x81e5/0x81e6 : stores parallèles écrasent les blocs de zéros
  → 0x8202 écrit zéro → MVDD 0x833c recopie zéro → coefficients FIRS nuls
  → SB jamais décodé
```

Le seul inconnu restant est **pourquoi `T` vaut 0 en `0x81e4`**, alors qu'il
vaut `0x00ac` trente mots plus haut (`0x81b2`, `0x81bf`) et que `LD Smem,T` est
bien exécuté en `0x815e`.

`si_watch_t` pose un point de surveillance qui s'arrête quand `T` devient nul ;
`si_where` donne alors le PC du DSP responsable.

## Forcer les SI — et ce que ça vaut

`si_force_sb [bsic]` écrit directement un bloc `a_sch` plausible dans les deux
pages, efface `B_SCH_CRC` et pose `a_serv_demod[D_TOA] = 23`. Le firmware
assemble alors un vrai SB, en tire un BSIC, se synchronise, arme le CCCH et peut
recevoir les SI.

```bash
tools/run_si_gdb.sh --forcer --repete 20 --intervalle 2
```

**C'est une béquille, et il faut le dire à chaque fois qu'on lit son résultat.**
Elle prouve que *tout l'aval du SB fonctionne* — synchronisation, CCCH, SI. Elle
n'apprend **rien** sur le DSP : les SI obtenues ainsi ne sont pas décodées par le
modèle, elles découlent d'une valeur qu'on a écrite à la main. Elle se retire le
jour où `si_etape4_coef` cesse de dire `TABLE INTROUVABLE`.

Le forçage doit être **répété** : le DSP réécrit ces cellules à chaque trame.
D'où `--forcer` dans la boucle du script plutôt qu'un coup unique.

## Cinq pièges, tous vérifiés à leurs dépens

**Le tube se referme.** Chaque `printf > tube` ouvre *puis referme* le tube.
Quand le dernier écrivain ferme, gdb voit un EOF sur son entrée et **cesse de
lire** — le canal meurt en silence et toute commande suivante reste sans
réponse. `run_si_gdb.sh` tient donc le tube ouvert sur le descripteur 9 pendant
toute sa durée et réamorce un gardien permanent s'il manque.

**Lire fige.** Avec `target remote`, gdb ne peut pas lire la mémoire pendant que
la cible tourne. Toute inspection exige un arrêt, et un arrêt de quelques
secondes casse la synchro GSM : le mobile repart en `L1CTL_RESET_REQ: FULL`.
C'est sans conséquence pour lire des structures qui **persistent** (tampons,
tables, coefficients), mais on ne peut pas observer ainsi une acquisition en
train d'aboutir.

**`LOG_DIR` bouge d'un run à l'autre.** Ne jamais le supposer : le lire dans
`/proc/<pid>/environ`.

**Une sonde muette n'est pas une sonde absente.** `C54_LOG` — donc les lignes
`UNIMPL` — est conditionné par `CALYPSO_DEBUG=C54X`. Sans ce canal, l'absence de
`UNIMPL` ne prouve rien.

**Un plafond n'est pas une absence.** Une sonde plafonnée à N lignes peut
épuiser son quota très tôt sur une cellule bavarde et taire tout le reste.
Plafonner **par adresse**, jamais globalement, et toujours doubler d'un compteur
cumulatif.

## Ce que le mailbox voit

`CALYPSO_MAILBOX_RANGES=lo-hi,…` (jusqu'à 16 plages, bornes incluses) permet de
surveiller n'importe quelle région, pas seulement la fenêtre API `0x0800-0x0FFF`.
`CALYPSO_MAILBOX_ONLY=1` restreint aux plages listées — indispensable, la fenêtre
API seule produisant ~190 Mo en deux minutes.

L'annonce de couverture au démarrage liste les plages avec leur taille : c'est
elle qui distingue « la cellule n'a pas bougé » de « la cellule n'était pas
surveillée ».

Plages utiles pour ce chemin :

```
0x2a00-0x2b2f   le burst
0x2c56-0x2cb9   les deux tampons de sortie du corrélateur
0x2cc0-0x2cf0   la banque des 7 blocs de 7 mots
0x2cba-0x2cbf   la source du MVDD des coefficients
0x0060-0x0067   le scratch-pad où le FIRS lit ses coefficients
```
