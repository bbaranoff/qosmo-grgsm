"""
test_golive_grafcet.py — validation du GRAFCET go-live/corrélateur DSP contre un run live.

Chaque étape du grafcet = un jalon (regex sur qemu.log). Le test grep le log live,
construit la table de validation, et asserte l'état COURANT connu (2026-07-25) :
le go-live est débloqué (BGEN natif) jusqu'à FB0_SEARCH, mais le corrélateur 0x8d00
n'est PAS atteint (BRINT0 masqué par INTM=1). Les jalons "goal" (encore non atteints)
sont en xfail(strict=False) : le jour où un fix les atteint, pytest le SIGNALE (xpass)
= détecteur de progrès, pas un faux vert.

Log : $CALYPSO_QEMU_LOG, sinon /root/qemu.log (dans le conteneur), sinon skip.
Réf : grafcet G0..G4 (workflow trace) + findings live (BGEN, BRINT0/INTM, 0x3f92/0x0810).
"""
import os
import re
import subprocess

try:
    import pytest
except ModuleNotFoundError:            # permet le runner standalone sans pytest installé
    class _MarkShim:
        @staticmethod
        def parametrize(*a, **k):
            def deco(fn):
                return fn
            return deco

    class _PytestShim:
        mark = _MarkShim()

        @staticmethod
        def fixture(*a, **k):
            def deco(fn):
                return fn
            return deco

        @staticmethod
        def skip(msg=""):
            raise SystemExit("SKIP: " + msg)

        @staticmethod
        def xfail(msg=""):
            raise SystemExit(0)

        @staticmethod
        def fail(msg=""):
            raise AssertionError(msg)

    pytest = _PytestShim()

# ---------------------------------------------------------------------------
# Localisation du log live
# ---------------------------------------------------------------------------
def _resolve_log():
    p = os.environ.get("CALYPSO_QEMU_LOG")
    if p and os.path.exists(p):
        return p
    for cand in ("/root/qemu.log", "/tmp/qemu.log"):
        if os.path.exists(cand):
            return cand
    # dernier recours : copier depuis le conteneur osmo-operator-1
    dst = "/tmp/_calypso_qemu_live.log"
    for pref in (["docker"], ["sudo", "-n", "docker"]):
        try:
            subprocess.run(pref + ["cp", "osmo-operator-1:/root/qemu.log", dst],
                           check=True, capture_output=True, timeout=30)
            if os.path.getsize(dst) > 0:
                return dst
        except Exception:
            continue
    return None


@pytest.fixture(scope="module")
def loglines():
    p = _resolve_log()
    if not p:
        pytest.skip("aucun qemu.log live (poser CALYPSO_QEMU_LOG=/chemin)")
    with open(p, "rb") as f:
        data = f.read().decode("latin-1", "replace")
    return data


def _count(data, rx):
    return len(re.findall(rx, data))


# ---------------------------------------------------------------------------
# GRAFCET : (id, libellé, regex, env-vars gating, expected_reached_live)
#   expected=True  -> DOIT être atteint (assert reached)
#   expected=False -> "mur"/goal encore non franchi (xfail strict=False)
# ---------------------------------------------------------------------------
GRAFCET = [
    # --- Amont : DSP vivant + commande ARM -------------------------------
    ("S10", "DSP core actif", r"\[c54x\]", "CALYPSO_DSP_RUN_C54X", True),
    ("S20", "ARM commande tâche FB (task_md=5)", r"task_md=5|d_task_md.?=?.?0x0005", "CALYPSO_ARM2DSP", True),
    ("S30", "ARM ouvre gate d_ctrl_system 0x0810", r"ARM-WRITE-0810.*val=0x8000|data\[0x0810\]=0x8000", "-", True),
    # --- Go-live natif débloqué par BGEN (Fix A) -------------------------
    ("S40", "BGEN pose 0x098a/0x098c (handshake ARM)", r"\[arm2dsp\] BGEN post|FORCE-GATE", "CALYPSO_ARM2DSP_BGEN", True),
    ("S50", "d_fb_mode/3f70 bit1 posé (wait-loop libérée)", r"F70-SETBIT1", "CALYPSO_ARM2DSP_BGEN", True),
    ("S60", "IMR armé 0x52ed", r"IMR=0x52ed|IMR=0x52fd", "CALYPSO_KEEP_IMR", True),
    ("S70", "IMR shadow d[0x435b] peuplé", r"d\[0x435b\]=0x52ed|d\[435b\]=52ed", "CALYPSO_INIT_435B_OFF", True),
    ("S80", "FB0_SEARCH lancé (real DSP path)", r"FB0_SEARCH .real DSP", "CALYPSO_FORCE_DEMOD_BRIDGE", True),
    # --- LE MUR : dispatch du corrélateur --------------------------------
    ("S90", "IT frame BRINT0 pending (IFR bit5)", r"IFR=0x1020|SYNC-DISPATCH-PROBE.*BRINT0", "-", True),
    ("S91", "BRINT0 bloqué par INTM=1 (STAYS-PENDING)", r"STAYS-PENDING", "CALYPSO_INTM_TRANS", True),
    ("S92", "boucle rejet go-live a53c->a575 (TC=0)", r"a53f.BC a575 if NTC. TC=0", "-", True),
    # --- Goals encore NON atteints (détecteurs de progrès) ---------------
    ("G1", "corrélateur 0x8d00 ENTRÉ", r"PC=0x8d00|pc=0x8d00|CORRELATOR-TRACE", "CALYPSO_CORRELATOR_TRACE", False),
    ("G2", "FB tenté (fb0_att>0)", r"fb0_att=[1-9]", "-", False),
    ("G3", "d_fb_det DÉTECTÉ (!=0)", r"d_fb_det.*=.*0x0*[1-9a-f]|rx_fb_det=1", "-", False),
    ("G4", "IT servie (RETE depuis ISR)", r"\bRETE\b.*served|DISPATCHED", "-", False),
]


@pytest.fixture(scope="module")
def reached(loglines):
    return {g[0]: _count(loglines, g[2]) for g in GRAFCET}


def test_grafcet_table(reached, capsys):
    """Imprime la table de validation grafcet (toujours vert : c'est le rapport)."""
    lines = ["", "GRAFCET go-live/corrélateur — validation vs run live", "=" * 64]
    for gid, label, rx, env, exp in GRAFCET:
        n = reached[gid]
        mark = "OK " if (n > 0) == exp else ("!! " if exp else "** ")
        state = f"{n:>7} hits" if n else "      0 hits"
        lines.append(f"{mark}{gid:4} {label:44} {state}  gate={env}")
    lines.append("=" * 64)
    lines.append("OK=conforme  !!=régression (attendu mais absent)  **=PROGRÈS (goal atteint!)")
    print("\n".join(lines))


@pytest.mark.parametrize("gid,label", [(g[0], g[1]) for g in GRAFCET if g[4]])
def test_step_reached(reached, gid, label):
    """Les étapes du chemin nominal DOIVENT être atteintes (sinon régression)."""
    assert reached[gid] > 0, f"RÉGRESSION grafcet: {gid} '{label}' non atteint dans le run"


@pytest.mark.parametrize("gid,label", [(g[0], g[1]) for g in GRAFCET if not g[4]])
def test_goal_not_yet(reached, gid, label):
    """Goals non atteints : xfail tant que le mur tient ; xpass = fix confirmé."""
    if reached[gid] > 0:
        pytest.fail(f"🎯 PROGRÈS: {gid} '{label}' ATTEINT ({reached[gid]} hits) — "
                    f"le mur corrélateur est tombé, mettre à jour le grafcet !")
    pytest.xfail(f"mur attendu: {gid} '{label}' pas encore atteint (corrélateur non dispatché)")


def test_wall_is_correlator_dispatch(reached):
    """Invariant de diagnostic : go-live franchi (FB0_SEARCH) MAIS corrélateur non entré."""
    assert reached["S80"] > 0, "FB0_SEARCH devrait tourner (go-live débloqué)"
    assert reached["G1"] == 0, "0x8d00 ne devrait pas être atteint (mur BRINT0/INTM)"
    assert reached["S91"] > 0, "le blocage BRINT0/INTM=1 (STAYS-PENDING) devrait être visible"


# ---------------------------------------------------------------------------
# Runner standalone (sans pytest) : python3 test_golive_grafcet.py [log]
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import sys
    path = sys.argv[1] if len(sys.argv) > 1 else _resolve_log()
    if not path:
        print("aucun qemu.log (usage: python3 test_golive_grafcet.py /chemin/qemu.log)")
        sys.exit(2)
    data = open(path, "rb").read().decode("latin-1", "replace")
    print(f"\nGRAFCET go-live/corrélateur — validation vs {path}")
    print("=" * 72)
    regress = progress = 0
    for gid, label, rx, env, exp in GRAFCET:
        n = _count(data, rx)
        good = (n > 0) == exp
        if exp and not good:
            tag, regress = "!! REGRESS", regress + 1
        elif not exp and n > 0:
            tag, progress = "** PROGRES", progress + 1
        else:
            tag = "OK"
        print(f"{tag:11} {gid:4} {label:46} {n:>8} hits  gate={env}")
    print("=" * 72)
    print(f"régressions={regress}  progrès(goals atteints)={progress}")
    wall_ok = _count(data, r"FB0_SEARCH .real DSP") > 0 and _count(data, r"PC=0x8d00|pc=0x8d00") == 0
    print(f"invariant [go-live franchi + corrélateur non entré] = {wall_ok}")
    sys.exit(1 if regress else 0)
