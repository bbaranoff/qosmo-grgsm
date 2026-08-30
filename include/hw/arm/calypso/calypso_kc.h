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
