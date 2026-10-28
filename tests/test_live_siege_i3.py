"""BUG-140 .. BUG-146 (live test i3, Trussroads y717, area siege), Python side: the contract of the new fields, the
status/brief lines, and source rules for the kernel (no locale-dependent decimal format, no read of a field DF 53.16
lacks). The kernel side is tests/lua/test_bug14*_*.lua and tests/lua/test_stations.lua (BUG-142)."""
import json
import re
from pathlib import Path
from types import SimpleNamespace

from dfpilot import brief, schema

REPO = Path(__file__).resolve().parents[1]
_STATE = {"v": 2, "seq": 1, "t": {"y": 3, "tick": 10, "season": 0, "tps": 100, "paused": False}, "mode": "BREACH",
          "k": {"ms_s": 1, "gap_max_ms": 1, "slow": [], "faults": 0}, "ev": 1}
AL = {"defcon": 1, "unacked": 0, "last": 7, "ack": 7, "lock": 1, "why": "arrival:invader"}
BY = {"id": 41873, "race": "TROGLODYTE", "k": "inv", "pos": [114, 68, 132], "dc": 23, "de": 4, "hl": 0, "n": 1, "sz": 5767}
ALERT = {"want": "Kern+", "burrow": "Kern+", "tiles": 900, "inside": 40, "ok": 1}


def state(**kw):
    s = json.loads(json.dumps(_STATE))
    s.update(kw)
    return s


def test_new_state_fields_validate():
    assert schema.validate("state", state(alarm=dict(AL, age=10, by=dict(BY, hw="large predator")))) == []
    assert schema.validate("state", state(alarm=dict(AL, age=10, by=dict(BY, hw="x" * 25)))) != []
    assert schema.validate("state", state(alert=dict(ALERT, aud=60339))) == []
    assert schema.validate("state", state(alert=dict(ALERT, aud=-1))) != []
    text = (REPO / "lua/dfllm/util/contract.lua").read_text("utf-8")
    assert "hw = str(24)" in text and "aud = NAT" in text


def test_bug144_the_cause_says_why_it_is_dangerous():
    txt = brief.lockdown_text(dict(AL, age=1200, lim=12000, qw="near", by=dict(BY, hw="large predator")))
    assert "size 5767, dangerous (large predator)" in txt, txt
    txt = brief.lockdown_text(dict(AL, age=1200, lim=12000, qw="near", by=dict(BY, hl=1)))
    assert "size 5767, harmless" in txt and "(" not in txt.split("harmless")[1][:2], txt


def test_bug144_the_benign_line_stays_in_the_status_while_a_lockdown_or_lone_clock_holds():
    s = {"alarm": dict(AL, ben=["41874:visitor", "41875:merchant"]), "t": {"tps": 100}}
    items = brief.alarm_items(SimpleNamespace(s=s))
    assert (2, "not counted as hostile (id:why): 41874:visitor, 41875:merchant") in items, items
    s["alarm"] = dict(AL, lock=0, ben=["41874:visitor"])
    assert (3, "not counted as hostile (id:why): 41874:visitor") in brief.alarm_items(SimpleNamespace(s=s))


def test_bug144_the_drill_hint_never_offers_a_command_that_is_refused():
    def line(r):
        out = brief.pop_items(SimpleNamespace(s={"ready": r}))
        return next(t for _, t in out if "drill" in t)
    r = {"lvl": 0, "worn": 0, "cv": 3, "drill_age": -1, "audit": {"ok": 0, "age": -1, "min_traps": 0},
         "fail": ["no_inner"], "open": 0, "dhold": "no_inner"}
    assert "drill never (auto: no_inner; build fortcore stage 2/3 first)" in line(r), line(r)
    r["dref"] = 1
    t = line(r)
    assert "drill never (auto: no_inner) [1 refused: build fortcore stage 2/3 first]" in t and "run dfllm cmd drill" not in t, t
    r.pop("dhold")                             # refused drills but no auto-hold reason: still no 'run dfllm cmd drill'
    t = line(r)
    assert "drill never [1 refused: build fortcore stage 2/3 first]" in t and "run dfllm cmd drill" not in t, t
    r.pop("dref")
    assert "drill never (run dfllm cmd drill)" in line(r), line(r)
    r["dhold"] = "no barracks"
    assert "drill never (auto: no barracks; run dfllm cmd drill)" in line(r)


def test_bug146_the_alert_line_names_old_refuge_data():
    assert "refuge data 50.3 d old" in brief.line_alert(dict(ALERT, aud=60339))
    assert "refuge data" not in brief.line_alert(ALERT)


def test_bug143_no_kernel_file_formats_a_decimal_with_the_locale():
    bad = re.compile(r"%[-+ #0]*\d*\.[1-9]\d*f|%[-+ #0]*[\d.]*[gGeE](?![A-Za-z])")
    hits = []
    for p in sorted((REPO / "lua/dfllm").rglob("*.lua")):
        if p.name == "num.lua":
            continue
        for i, l in enumerate(p.read_text("utf-8").splitlines(), 1):
            code = l.split("--", 1)[0]
            if bad.search(code):
                hits.append(f"{p.relative_to(REPO)}:{i}: {l.strip()}")
    assert hits == [], "\n".join(hits)


def test_bug144_sense_reads_no_field_df_53_16_lacks():
    code = [ln.split("--", 1)[0] for ln in (REPO / "lua/dfllm/sense.lua").read_text("utf-8").splitlines()]
    assert not any("flags2.restrained" in c for c in code)


def test_the_bug_files_and_rows_exist():
    rows = (REPO / "bugs/README.md").read_text("utf-8")
    for n in range(140, 147):
        files = list((REPO / "bugs").glob(f"BUG-{n}-*.md"))
        assert len(files) == 1, n
        assert f"[BUG-{n}]({files[0].name})" in rows, n
