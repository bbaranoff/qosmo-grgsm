/*
 * calypso_kc.h — LE format de /dev/shm/calypso_kc, et le seul ecrivain.
 *
 * POURQUOI CE FICHIER EXISTE
 * --------------------------
 * Trois producteurs ont ecrit ce fichier, chacun avec sa propre copie du
 * format et sa propre idee de l'atomicite :
 *   - l1ctl_sock.c, en espionnant L1CTL_CRYPTO_REQ (chemin MORT : le socket
 *     l1ctl de QEMU est orphelin, le mobile parle a osmocon) ;
 *   - osmocon, hors de ce depot, qui EFFACE la cle sur DM_EST_REQ — donc en
 *     plein milieu d'une session chiffree, des que le mobile ouvre un lien de
 *     plus (SAPI 3 du SMS) ;
 *   - le shunt DSP, qui devait publier l'etat REEL de la L1... et ne le
 *     faisait pas : pont.py documente `shunt_publish_kc` depuis le 27/08,
 *     mais la fonction n'a jamais existe. C'est en la croyant en place qu'on a
 *     mis PONT_KC_RETENTION a 0. Resultat : plus personne n'ecrivait de cle
 *     valable, le fichier restait a zero, et le pont laissait EN CLAIR un
 *     canal que le reseau chiffrait — tout ce qui suit le CIPHERING MODE
 *     COMMAND echouait au CRC, SDCCH comme TCH.
 *
 * LE FORMAT, UNE FOIS POUR TOUTES (32 octets, little-endian)
 * ---------------------------------------------------------
 *   [0..3]   seq   u32   incremente a chaque CHANGEMENT d'etat. 0 = rien.
 *   [4]      algo  u8    0 = en clair, 1..3 = A5/1..A5/3
 *   [5]      len   u8    longueur de la cle en octets (8 pour A5)
 *   [6..13]  kc    u8[8] la cle, dans l'ordre RSL (celui de osmo_a5)
 *   [14]     cksn  u8    0xFF si inconnu
 *   [15..31] reserve, a zero
 *
 * ATOMICITE : PAS DE O_TRUNC.
 * L'ancien ecrivain ouvrait en O_WRONLY|O_CREAT|O_TRUNC puis ecrivait. Entre
 * les deux, le fichier fait ZERO octet — et le lecteur (pont.py, kc_read) qui
 * tombe dans cette fenetre lit moins de 14 octets et conclut « pas de cle »,
 * donc « en clair ». Un producteur qui reaffirme la cle dix fois par seconde
 * offre donc dix fenetres par seconde ou le pont peut decider de ne pas
 * dechiffrer. On garde UN descripteur ouvert et on repose les 32 octets par un
 * seul pwrite a l'offset 0 : la taille ne varie jamais, un lecteur voit
 * toujours un enregistrement entier.
 *
 * LES LECTEURS, ET CE QU'ILS DOIVENT EN FAIRE  [2026-08-31]
 * --------------------------------------------------------
 * REGLE UNIQUE : l'autoritaire (_l1) d'abord ; l'historique SEULEMENT s'il est
 * ABSENT. Une fois _l1 elu on n'en redescend jamais -- un algo=0 venu de LUI dit
 * vraiment « en clair » et se croit. Melanger les deux, c'est reintroduire la
 * course qu'on vient de supprimer.
 *
 * L'HISTORIQUE N'A PLUS D'ECRIVAIN. Le patch osmocon a ete retire le 30/08
 * (osmo-operator/Dockerfile:242) et l1ctl_sock.c est orphelin : /dev/shm/calypso_kc
 * n'est plus cree du tout. Mesure du 31/08 dans osmo-operator-2 et -3 : seul
 * calypso_kc_l1 existe. Le repli n'est donc conserve que pour un binaire QEMU
 * pas reconstruit.
 *
 * L'ENREGISTREMENT EST TRANSITOIRE, ET C'EST VOULU. Le shunt republie l'etat
 * REEL de la L1 : algo=1 pendant le canal dedie chiffre, puis algo=0 des que le
 * firmware repasse en clair. Releve du 31/08, un seul run :
 *     seq=1 EN CLAIR -> seq=2 A5/1 Kc=c7d20e13126d0c00 -> seq=3 EN CLAIR
 * Un lecteur qui echantillonne trouve donc des zeros la PLUPART du temps. Zero
 * veut dire « en clair MAINTENANT », jamais « pas de cle de la session ».
 * Qui a besoin de la cle APRES coup (dechiffrement differe, dashboard) doit
 * retenir le dernier non-nul -- ou la demander au mobile, qui la garde :
 *     $ echo 'show subscriber' | nc 127.0.0.1 4247
 *       Key: sequence 0  c7 d2 0e 13 12 6d 0c 00
 * (osmocom-bb common/vty.c:241 -> subscriber.c:518. Meme valeur que le shunt,
 * verifie le 31/08, et TOUJOURS la quand le fichier est deja remis a zero.)
 *
 * ⚠️ NE PAS "NORMALISER" LES LECTEURS SANS MESURER. si_bridge.py (read_kc) et
 * tools/calypso-ipc-device/qemu_wrap.c (calypso_kc_read) lisent encore
 * l'historique SEUL, donc rendent toujours 0. Ce n'est pas un oubli benin : chez
 * si_bridge, read_kc() commande le spawn/kill du grgsm CHIFFRE (boucle 0,5 s).
 * Le basculer sur _l1 ferait apparaitre et disparaitre ce decodeur a chaque
 * transition de chiffrement. C'est un changement de comportement du pipeline, a
 * mesurer pour lui-meme -- pas un alignement de chemin.
 */
#ifndef HW_ARM_CALYPSO_KC_H
#define HW_ARM_CALYPSO_KC_H

#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

/*
 * DEUX CHEMINS, ET C'EST LE COEUR DU CORRECTIF.
 *
 * Un format commun ne regle pas une COURSE. Il y a au moins trois ecrivains sur
 * /dev/shm/calypso_kc :
 *   1. osmocon      hors de ce depot, incontrolable d'ici, et il ECRASE le
 *                   fichier avec 32 zeros sur DM_EST_REQ -- y compris en pleine
 *                   session chiffree, des que le mobile ouvre un lien de plus ;
 *   2. l1ctl_sock.c le chemin espion L1CTL, mort dans cette configuration ;
 *   3. le shunt DSP la verite terrain (d_a5mode / a_kc du NDB).
 * Sans arbitrage, le DERNIER qui ecrit gagne -- et c'est l'effaceur. Mesure :
 * fichier a 32 zeros, « A5=non » sur tout le canal dedie, appel mort.
 *
 * On ne peut pas faire cooperer osmocon. On cesse donc de PARTAGER le fichier :
 * la source autoritaire publie dans un fichier a elle, qu'aucun autre ecrivain
 * ne connait. Le lecteur (pont.py) le prefere, et ne retombe sur l'historique
 * que s'il est absent. La course disparait au lieu d'etre arbitree.
 *
 *   CALYPSO_KC_PATH     historique, partage, ecrase par osmocon
 *   CALYPSO_KC_L1_PATH  autoritaire : l'etat de chiffrement REEL de la L1,
 *                       ecrit par le seul shunt. Un algo=0 venu de LA veut
 *                       vraiment dire « en clair », et se croit.
 */
#define CALYPSO_KC_PATH    "/dev/shm/calypso_kc"
#define CALYPSO_KC_L1_PATH "/dev/shm/calypso_kc_l1"
#define CALYPSO_KC_RECLEN 32

/*
 * Pose l'etat de chiffrement. `algo` 0 = en clair (kc ignore, l'enregistrement
 * est remis a zero sauf le seq). Retourne le seq ecrit, ou 0 si l'ecriture a
 * echoue.
 *
 * IDEMPOTENT : si l'etat est identique au dernier publie, on ne reecrit rien et
 * on ne touche pas au seq. Un lecteur peut donc se fier au seq pour detecter un
 * VRAI changement, et non la simple reaffirmation periodique de la meme cle.
 */
static inline uint32_t calypso_kc_publish_to(const char *path,
                                            uint8_t algo, const uint8_t *kc,
                                            uint8_t klen, uint8_t cksn,
                                            int *fdp, uint32_t *seqp,
                                            uint8_t *last, int *have_last)
{
    int      *fdslot = fdp;
    uint32_t *seq    = seqp;
    uint8_t   rec[CALYPSO_KC_RECLEN];

    if (algo < 1 || algo > 3 || !kc || klen == 0) {
        algo = 0; klen = 0;
    }
    if (klen > 8) klen = 8;

    memset(rec, 0, sizeof(rec));
    rec[4] = algo;
    rec[5] = klen;
    if (algo && klen)
        memcpy(rec + 6, kc, klen);
    rec[14] = cksn;

    if (*have_last && !memcmp(last + 4, rec + 4, CALYPSO_KC_RECLEN - 4))
        return *seq;

    if (*fdslot < 0) {
        *fdslot = open(path, O_WRONLY | O_CREAT, 0666);
        if (*fdslot < 0)
            return 0;
    }
    (*seq)++;
    memcpy(rec, seq, 4);
    if (pwrite(*fdslot, rec, sizeof(rec), 0) != (ssize_t)sizeof(rec)) {
        close(*fdslot);
        *fdslot = -1;
        (*seq)--;
        return 0;
    }
    memcpy(last, rec, sizeof(rec));
    *have_last = 1;
    return *seq;
}

/* Source AUTORITAIRE : le NDB du DSP. Fichier a elle seule. */
static inline uint32_t calypso_kc_publish_l1(uint8_t algo, const uint8_t *kc,
                                             uint8_t klen, uint8_t cksn)
{
    static int      fd = -1;
    static uint32_t seq = 0;
    static uint8_t  last[CALYPSO_KC_RECLEN];
    static int      have_last = 0;
    return calypso_kc_publish_to(CALYPSO_KC_L1_PATH, algo, kc, klen, cksn,
                                 &fd, &seq, last, &have_last);
}

static inline uint32_t calypso_kc_publish(uint8_t algo, const uint8_t *kc,
                                          uint8_t klen, uint8_t cksn)
{
    static int      fd  = -1;
    static uint32_t seq = 0;
    static uint8_t  last[CALYPSO_KC_RECLEN];
    static int      have_last = 0;

    uint8_t rec[CALYPSO_KC_RECLEN];

    if (algo < 1 || algo > 3 || !kc || klen == 0) {
        /* En clair : on le DIT, au lieu de laisser un vieil enregistrement. */
        algo = 0; klen = 0;
    }
    if (klen > 8) klen = 8;

    memset(rec, 0, sizeof(rec));
    rec[4] = algo;
    rec[5] = klen;
    if (algo && klen)
        memcpy(rec + 6, kc, klen);
    rec[14] = cksn;

    /* Comparaison hors seq : seul le CONTENU decide d'un changement. */
    if (have_last && !memcmp(last + 4, rec + 4, CALYPSO_KC_RECLEN - 4))
        return seq;

    if (fd < 0) {
        fd = open(CALYPSO_KC_PATH, O_WRONLY | O_CREAT, 0666);
        if (fd < 0)
            return 0;
    }
    seq++;
    memcpy(rec, &seq, 4);
    if (pwrite(fd, rec, sizeof(rec), 0) != (ssize_t)sizeof(rec)) {
        close(fd);
        fd = -1;
        seq--;
        return 0;
    }
    memcpy(last, rec, sizeof(rec));
    have_last = 1;
    return seq;
}

#endif /* HW_ARM_CALYPSO_KC_H */
