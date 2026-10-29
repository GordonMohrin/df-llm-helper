"""BUG-159..161 (live test round 2, i1 and i3): the brief trimmed the TIMELINE_RESET marker and status the hospital.retire
hint (BUG-159); `plan check` called seal at=audit and seal at=refuge a duplicate, `dfllm audit` gave up on a big fort's
snapshot after 60 s (BUG-160); the non-kernel Lua files still printed decimals with the locale's comma (BUG-161)."""
import json
import re
from pathlib import Path

import pytest
from cli_v2_helpers import append_events, make_runtime, reset_paths

from dfpilot import brief, files, plan, schema, wake

REPO = Path(__file__).resolve().parents[1]


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def e(n, typ, tick, msg="", d=None):
    return {"n": n, "tick": tick, "type": typ, "cls": schema.EVENTS[typ][0], "msg": msg, "d": d or {}}


# ---------------------------------------------------------------- BUG-159 (NEW7): the marker survives the trim
def _reset_and_noise(save):
    """The fixture clock is 1332160: a marker inside the 1-year window, then enough class A and B traffic that the
    digest (the last section) does not fit the budget."""
    evs = [{"n": 8813, "tick": 1_331_000, "type": "TIMELINE_RESET", "cls": "B",
            "msg": "game clock jumped back (older save loaded): tick 1420000 -> 1331000; events up to #8812 belong to "
                   "the discarded timeline", "d": {"n_alt": 8812, "tick_alt": 1_420_000, "tick_neu": 1_331_000}}]
    for i in range(30):
        evs.append(e(8814 + i, "GATE_FAIL", 1_331_100 + i, msg=f"B{i} not raised at T+900 " + "x" * 600,
                     d={"bridge": f"B{i}", "why": "timeout"}))
    btypes = sorted(t for t, v in schema.EVENTS.items() if v[0] == "B" and t != "TIMELINE_RESET")
    for i, t in enumerate(btypes[:60]):        # one digest line per type: a big fort's year
        evs.append(e(8900 + i, t, 1_331_200 + i, msg=f"{t} {i} " + "y" * 160))
    append_events(save, evs)


def test_the_default_brief_names_the_timeline_reset_in_its_head(save):
    _reset_and_noise(save)
    for budget in (brief.BRIEF_TOKENS, 500):
        text = brief.brief_text(save, budget)
        assert "TIMELINE_RESET x1" not in text, "the fixture must trim the digest's marker line"
        head = text.splitlines()[:3]
        assert any(x.startswith("TIMELINE RESET ") and "older save loaded (tick 1420000 -> 1331000)" in x
                   and "#8812" in x for x in head), head
    assert brief.brief_text(save, 20000).count("TIMELINE_RESET x1") == 1      # the digest keeps its entry


def test_no_marker_no_head_line(save):
    assert "TIMELINE RESET" not in brief.brief_text(save)


# ---------------------------------------------------------------- BUG-159 (BUG-131b): the retire hint in status
def put(save, hout):
    st = files.read_state(save)
    st["ready"] = {"lvl": 0, "worn": 94, "cv": 13, "drill_age": 5, "audit": {"age": 10, "ok": 1, "min_traps": 40},
                   "fail": ["hospital_out", "open_perimeter", "refuge_dry", "office", "burrow_lost"], "open": 3,
                   "ents": ["76,26,129 floor", "80,30,129 ramp", "90,31,129 floor"],
                   "office": "a vacant office or squads without a leader: dfllm cmd inspect what=offices " + "z" * 80}
    st["water"] = {"patients": 1, "thirst_max": 0, "hosp_ok": 1, "refuge_ok": 1, "buckets_free": 2, "hosp": 3,
                   "src": [[1, 2, 3]], "hosp_out": 1, "hout": hout}
    st["seq"] = st["seq"] + 10
    assert schema.validate("state", st) == []
    files.write_json_atomic(save / "state.a.json", st)
    files.write_json_atomic(save / "state.b.json", dict(st, seq=st["seq"] - 1))


def test_status_gives_the_retire_hint_its_own_line_even_when_the_r0_line_is_clipped(save):
    put(save, {"z": 26207, "at": [76, 26, 129], "ok": 1, "pat": 1})
    lines = brief.status_text(save).splitlines()
    r0 = next(x for x in lines if x.startswith("SIEGE UNREADY (R0)"))
    assert "hospital.retire" not in r0, r0                                   # not twice
    assert ("hospital_out: zone 26207 at 76,26,129 blocks it: 1 patient lies in it; once they are up: "
            "dfllm cmd hospital.retire zone=26207") in lines, lines


def test_a_finished_hospital_inside_drops_the_plan_it_inside_advice(save):
    put(save, {"z": 26207, "at": [76, 26, 129], "ok": 1, "pat": 1})
    text = brief.brief_text(save, 20000)
    assert "plan it inside" not in text and "a finished hospital inside exists, retire the old zones" in text, text
    assert "zone 26207 at 76,26,129 blocks it: 1 patient lies in it; once they are up: " \
           "dfllm cmd hospital.retire zone=26207" in text
    put(save, {"z": 26207, "at": [76, 26, 129], "ok": 0, "pat": 0})          # no hospital inside yet: the old advice
    text = brief.brief_text(save, 20000)
    assert "plan it inside" in text and "a finished hospital inside exists" not in text


# ---------------------------------------------------------------- BUG-160 (NEW2): seal at=audit vs at=refuge
def test_plan_check_tells_two_seals_with_other_params_apart(save):
    doc, state = json.loads((save / "plan.json").read_text("utf-8")), files.read_state(save)
    doc["seasons"][0]["build"] += [{"tpl": "seal", "site": "S1", "p": {"at": "audit"}},
                                   {"tpl": "seal", "site": "S1", "p": {"at": "refuge"}}]
    _, warn = plan.check(doc, state, decisions={}, banned=plan.BANNED)
    assert not any("duplicate seal@S1" in w for w in warn), warn
    doc["seasons"][0]["build"].append({"tpl": "seal", "site": "S1", "p": {"at": "refuge"}})
    _, warn = plan.check(doc, state, decisions={}, banned=plan.BANNED)
    assert sum("duplicate seal@S1" in w for w in warn) == 1, warn


# ---------------------------------------------------------------- BUG-160 (NEW3): the audit wait fits the fort
def test_the_audit_wait_adapts_to_the_snapshot_size(save):
    t, _ = wake.audit_timeout(save)
    assert t == wake.AUDIT_SNAP_S >= 180
    (save / "snap" / "big.json").write_bytes(b" " * 800_000)                  # ~ a 323k-tile audit box
    t, big = wake.audit_timeout(save)
    assert big == 800_000 and t == pytest.approx(60 + 3 * 800_000 / wake.AUDIT_SNAP_BPS) and t > 180
    (save / "snap" / "huge.json").write_bytes(b" " * 50_000_000)          # a dead kernel must not hang the CLI for hours
    assert wake.audit_timeout(save)[0] == wake.AUDIT_SNAP_MAX_S


def test_dfllm_audit_says_how_long_it_waits_and_that_it_still_waits(save, monkeypatch, capsys):
    from dfpilot import cmd
    monkeypatch.setattr(cmd, "send", lambda *a, **k: ("x", {"ok": True, "msg": "queued"}))
    monkeypatch.setattr(wake, "_snap_file", lambda *a, **k: None)
    now = [0.0]

    def sleep(s):
        now[0] += s
    ns = type("A", (), {"snap": None, "timeout": None, "wait": 1.0})()
    assert wake.run_audit(ns, save, sleep=sleep, clock=lambda: now[0]) == 3
    out = capsys.readouterr().out
    assert f"waiting up to {wake.AUDIT_SNAP_S:g} s" in out and "still waiting for" in out, out
    assert f"within {wake.AUDIT_SNAP_S:g} s; try again later: dfllm audit --snap aud" in out, out
    assert now[0] >= wake.AUDIT_SNAP_S


def test_the_audit_parser_default_is_adaptive():
    import argparse
    p = argparse.ArgumentParser()
    wake.add_audit_parser(p.add_subparsers())
    assert p.parse_args(["audit"]).timeout is None and p.parse_args(["audit", "--timeout", "5"]).timeout == 5


# ---------------------------------------------------------------- BUG-161 (NEW5): no locale decimal in any Lua text
STR = re.compile(r"'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"")
DIV = r"(?<![/])/(?!/)"
RULES = [("a %.Nf/%g/%e format", re.compile(r"%[-+ #0]*\d*\.[1-9]\d*f|%[-+ #0]*[\d.]*[gGeE](?![A-Za-z])"), False),
         ("tostring of a division", re.compile(r"tostring\((?:[^()]|\([^()]*\))*?" + DIV), True),
         ("tostring of a pacing share", re.compile(r"tostring\([\w.]*\bshare\)"), True),
         ("a division concatenated", re.compile(r"\.\.\s*\(?[\w.\[\]]+\s*" + DIV + r"\s*[\w.(]|[\w.\])]\s*" + DIV
                                                 + r"\s*[\w.]+\)?\s*\.\."), True)]


def locale_hits(paths):
    hits = []
    for p in paths:
        for i, line in enumerate(p.read_text("utf-8").splitlines(), 1):
            raw = line.split("--", 1)[0]
            code = STR.sub("S", line).split("--", 1)[0]
            for name, rx, strip in RULES:
                if rx.search(code if strip else raw):
                    hits.append(f"{p.name}:{i}: {name}: {line.strip()}")
    return hits


def test_no_lua_file_prints_a_decimal_with_the_locale():
    files_ = [p for p in sorted((REPO / "lua").rglob("*.lua")) if p.name != "num.lua"]
    assert {"dfllm.lua", "dfllm-hud.lua", "kern.lua"} <= {p.name for p in files_}
    assert locale_hits(files_) == []


def test_the_rule_catches_the_live_leaks(tmp_path):
    p = tmp_path / "leak.lua"
    p.write_text("print(string.format('load x%.2f', a / 100))\nlocal s = tostring(m.share)\n"
                 "local t = 'x' .. a / b\nlocal u = tostring(n / 3)\nlocal ok = tostring(n // 3) .. NUM.dec(a / b)\n",
                 encoding="utf-8")
    hits = locale_hits([p])
    assert [h.split(":")[1] for h in hits] == ["1", "2", "3", "4"], hits


def test_the_bug_files_and_rows_exist():
    rows = (REPO / "bugs/README.md").read_text("utf-8")
    for n in range(159, 162):
        fs = list((REPO / "bugs").glob(f"BUG-{n}-*.md"))
        assert len(fs) == 1, n
        assert f"[BUG-{n}]({fs[0].name})" in rows, n
