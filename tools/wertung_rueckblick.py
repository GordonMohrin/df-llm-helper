"""NEU1 P1: the retrospective score table of every Run 15/16 fort (docs/v2/WERTUNG-rueckblick.md).

    python tools/wertung_rueckblick.py [--out docs/v2/WERTUNG-rueckblick.md] [--runs <dwarf-fortress-v2/runs>]

Read-only: it never writes into a runtime folder (dfpilot.wertung.score(update=False)). The four DF installs and the
STAND.md of each run are fixed below (this machine, Run 15/16); a fort folder that is missing is reported as a gap."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from dfpilot import wertung  # noqa: E402

STEAM = "E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/dfllm-runtime"
T2, T3, T4 = "E:/DF-test2/dfllm-runtime", "E:/DF-test3/dfllm-runtime", "E:/DF-test4/dfllm-runtime"
# (run label, STAND.md folder under runs/, runtime root, fort folders in embark order)
RUNS = [
    ("Run 15a", "run-15-guildcleans", T2, ["r15-guildcleans-site97"]),
    ("Run 15b", "run-15b-earthboat", T3, ["r15-earthboat-site97", "a-run15-earthboat-site97"]),
    ("Run 15c", "run-15c-inkintense", STEAM, ["r15c-inkintense-site97"]),
    ("Run 15d", "run-15d-drillchamber", T4, ["r15d-drillchamber-site97"]),
    ("Run 16a (i1)", "run-16a", STEAM, ["r16a-bachwald-site97", "r16a2-mansionlauded-site97", "r16a3-manorsubtle-site97",
                                        "r16a4-syrupobeyed-site97", "r16a5-basementflew-site97"]),
    ("Run 16b (i2)", "run-16b", T2, ["r16b-ostgate-site97", "r16b2-glendagger-site97", "r16b3-roadvises-site97",
                                     "r16b4-brotherarrow-site97", "r16b5-valleyhame-site97", "r16b6-rocksblush-site98",
                                     "r16b7-whirledrampart-site98"]),
    ("Run 16c (i3)", "run-16c", T3, ["r16c-w9-18-site97", "r16c2-w6-17-site97", "r16c3-castletongs-site97",
                                     "r16c4-sealcertain-site97", "r16c5-wallfree-site97", "r16c6-doorwings-site97",
                                     "r16c7-lancemoment-site97"]),
    ("Run 16d (i4)", "run-16d", T4, ["r16d-woodmill-site97", "r16d2-mazelanterns-site97", "r16d3-orbblock-site97",
                                     "r16d4-trumpetrealms-site97", "r16d5-pagedsculpture-site97"]),
]
NOTES = [
    "Quelle: events.jsonl + events.1.jsonl jedes Forts (live Zeitlinie, verworfene Zeitlinien nach TIMELINE_RESET "
    "herausgenommen) und perf.csv + perf.1.csv; alle Forts haben ihr Ereignislog ab #1.",
    "Pop-Verlauf: perf.csv rotiert, perf.1.csv wird bei der naechsten Rotation geloescht. Wo perf fehlt, fuellen die "
    "Spielerzeilen `y### ... Pop N` aus STAND.md (Spalte Daten: `perf % + STAND %`); der Rest ist linear vom Embark "
    "(7 Buerger) interpoliert. Zwergjahre und Tote je 100 ZJ sind dort entsprechend unsicher.",
    "perf `pop` zaehlt die Buerger des Zensus; Kinder sterben als Buerger mit. Der Verlust je Belagerung ist deshalb "
    "bei 100 % gekappt.",
    "Todesursachen kommen aus den DEATH-Ereignissen des Kernels (Ursache, Vorfall, Taeter, Patient, Stimmung); ein "
    "nie gefundener Toter ausserhalb einer Belagerung heisst `vermisst`. BUG-379 (ungenaue Ursachen) gilt weiter.",
    "a-run15-earthboat ist ein zweiter Zweig desselben Embarks (gleicher Start-Tick wie r15-earthboat), im STAND nicht "
    "beschrieben; er steht der Vollstaendigkeit halber in der Tabelle.",
    "Nicht enthalten: Forts frueherer Runs (region2-*, Run 1-14) und Forts ohne Runtime-Ordner.",
]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "docs" / "v2" / "WERTUNG-rueckblick.md"))
    ap.add_argument("--runs", default="C:/Users/admin/claude gordons projects/dwarf-fortress-v2/runs")
    a = ap.parse_args(argv)
    scores, notes = [], list(NOTES)
    for label, run_dir, root, forts in RUNS:
        try:
            stand = (Path(a.runs) / run_dir / "STAND.md").read_text(encoding="utf-8", errors="replace")
        except OSError:
            stand = ""
            notes.append(f"{label}: keine STAND.md in {run_dir}")
        order = [wertung.fort_key(f) for f in forts]
        for f in forts:
            d = Path(root) / f
            if not (d / "events.jsonl").exists():
                scores.append({"save": f, "gap": "kein Runtime-Ordner"})
                notes.append(f"{label} {f}: kein Runtime-Ordner unter {root}")
                continue
            extra = wertung.stand_samples(stand, wertung.fort_key(f), order) if stand else []
            sc = wertung.score(d, extra, update=False)
            sc["save"] = f"{label}: {f}"
            scores.append(sc)
            print(wertung.score_line(sc))
    Path(a.out).write_text(wertung.md_table(scores, "Wertung Rueckblick Run 15/16 (NEU1 P1)", notes), encoding="utf-8")
    print(f"wrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
