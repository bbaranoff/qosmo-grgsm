# 00-prereqs — vérifie que l'installation est utilisable, sans rien lancer.
# MOD_PURE=1 : aucun effet de bord, donc exécuté même en --dry-run pour que le
# plan affiché soit exact.
MOD_REGISTER prereqs "Vérification des prérequis"
MOD_REQUIRED[prereqs]=1
MOD_PURE[prereqs]=1
MOD_PROFILES[prereqs]="calypso faketrx hybrid core"

mod_prereqs_check() {
    local missing=""
    # [2026-08-30] DSP_PROM0 retiré de la liste : le merge `sans-dsp` supprime
    # tools/dsp_txt2bin.py, seul générateur des calypso_dsp.*.bin — la ROM
    # n'existe donc plus sur aucune installation à jour. Ce module étant
    # MOD_REQUIRED=1 sur les quatre profils, l'exiger avortait la séquence
    # entière, y compris pour `faketrx` et `core` qui n'ouvrent jamais une ROM
    # DSP. Seul le mode qemu s'en sert, et 40-qemu.sh en juge lui-même (il
    # démarre la machine calypso nue, via le shunt).
    for v in QEMU_BIN FIRMWARE_ELF; do
        local p="${!v:-}"
        [ -n "$p" ] && [ -e "$p" ] || missing="$missing $v"
    done
    if [ -n "$missing" ]; then
        mod_hint "réglez les chemins dans environnement/paths.env, puis ./run.sh --check-paths"
        mod_fail "dépendances introuvables :$missing"
        return $MOD_RC_FAIL
    fi
    mod_ok
}
mod_prereqs_start()  { mod_ok; }
mod_prereqs_status() { return $MOD_RC_FAIL; }   # module pur : jamais « déjà démarré »
