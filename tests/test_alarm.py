"""FR-53 interrupt channel, Python side: <save>/alarm.txt, `dfllm wait --until-interrupt` and `dfllm ack`."""
import json
import threading
import time

import pytest
from cli_v2_helpers import FakeKern, append_events, ev, inbox_docs, make_runtime, reset_paths

from dfpilot import alarm, schema
from dfpilot.cli import main


@pytest.fixture
def save(tmp_path):
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def run(save, *argv):
    return main(["--runtime", str(save.parent), *argv])


HEAD = "DEFCON {d} | mode PEACE | unacked {u} | last {last} | ack {ack} | lockdown off"


def write_alarm(save, items, ack=0, defcon=3):
    lines = [HEAD.format(d=defcon, u=sum(1 for n, *_ in items if n > ack), last=items[-1][0] if items else 0, ack=ack)]
    for n, typ, msg in items:
        lines.append(f"{n}\t1791676800\t1333000\t{typ}\t{'acked' if n <= ack else 'unacked'}\t{msg}")
    (save / "alarm.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def test_read_alarm_parses_head_and_items(save):
    write_alarm(save, [(8820, "ARRIVAL", "siege (popup) -> clock 30 t/s"), (8821, "INTRUDER", "2 hostiles")], ack=8820)
    a = alarm.read_alarm(save)
    assert a["defcon"] == 3 and a["ack"] == 8820
    assert [(i["n"], i["type"], i["status"]) for i in a["items"]] == [(8820, "ARRIVAL", "acked"),
                                                                       (8821, "INTRUDER", "unacked")]
    (save / "alarm.txt").write_text("DEF", encoding="utf-8")       # torn: unknown, not an error
    assert alarm.read_alarm(save) is None


def test_wait_returns_at_once_while_interrupts_stand_unacked(save, capsys):
    write_alarm(save, [(8820, "ARRIVAL", "siege (popup) \"A vile force of darkness has arrived!\" -> clock 30 t/s")])
    t0 = time.monotonic()
    assert run(save, "wait", "--until-interrupt", "--timeout", "5") == 0
    assert time.monotonic() - t0 < 2
    out = capsys.readouterr().out
    assert out.startswith("INTERRUPT #8820 ARRIVAL (unacked): siege (popup)") and "DEFCON 3" in out
    assert "dfllm ack" in out


def test_wait_times_out_quickly_when_everything_is_acked(save, capsys):
    write_alarm(save, [(8820, "ARRIVAL", "x")], ack=8820, defcon=5)
    t0 = time.monotonic()
    assert run(save, "wait", "--until-interrupt", "--timeout", "0.4") == 1
    assert time.monotonic() - t0 < 3
    assert "no interrupt in 0.4 s | DEFCON 5" in capsys.readouterr().out


def test_wait_returns_as_soon_as_a_new_interrupt_appears(save):
    write_alarm(save, [(8820, "ARRIVAL", "x")], ack=8820)

    def later():
        time.sleep(0.3)
        write_alarm(save, [(8820, "ARRIVAL", "x"), (8831, "PREDATOR", "1 wild danger inside")], ack=8820, defcon=3)
    threading.Thread(target=later, daemon=True).start()
    t0 = time.monotonic()
    items, a = alarm.wait_interrupt(save, timeout=10, poll=0.05)
    assert time.monotonic() - t0 < 5
    assert [i["n"] for i in items] == [8831] and a["defcon"] == 3


def test_wait_falls_back_to_events_jsonl(save):
    # no alarm.txt (reflex module backed off): an interrupt type in events.jsonl still returns the wait
    def later():
        time.sleep(0.3)
        append_events(save, [ev(9001, "DEATHS_3PLUS", "3 deaths today", {"n": 3, "ids": [1, 2, 3]}),
                             ev(9002, "SEASON", "season 2", {"year": 3, "season": 2})])
    threading.Thread(target=later, daemon=True).start()
    items, a = alarm.wait_interrupt(save, timeout=10, poll=0.05)
    assert a is None and [(i["n"], i["type"]) for i in items] == [(9001, "DEATHS_3PLUS")]


def test_wait_since(save):
    write_alarm(save, [(8820, "ARRIVAL", "a"), (8825, "NO_DEPOT", "b")], ack=8825)
    items, _ = alarm.wait_interrupt(save, since=8820, timeout=0)
    assert [i["n"] for i in items] == [8825]


def test_ack_sends_the_verb(save, capsys):
    with FakeKern(save, reply=lambda doc: (True, "acked up to #8825 (0 interrupts open, DEFCON 5)", {"n": 8825})) as k:
        assert run(save, "ack", "--n", "8825") == 0
    out = capsys.readouterr().out
    assert "ok" in out and "acked up to #8825" in out
    assert k.seen and k.seen[0]["verb"] == "ack" and k.seen[0]["args"] == {"n": 8825} and k.seen[0]["by"] == "cli"


def test_ack_verb_schema():
    assert schema.VERBS["ack"] == ("reflex", None, False)
    assert schema.validate_args("ack", {}) == [] and schema.validate_args("ack", {"n": 12}) == []
    assert schema.validate_args("ack", {"n": -1}) and schema.validate_args("ack", {"x": 1})


def test_ack_without_kernel_reply(save, capsys):
    assert run(save, "ack", "--wait", "0") == 0
    docs = inbox_docs(save)
    assert docs and docs[-1]["verb"] == "ack" and docs[-1]["args"] == {}


# ---------------------------------------------------------------- contracts and config of the reflex (FR-51/52/55)
def test_reflex_events_validate():
    def e(t, d, msg="m"):
        return {"n": 1, "tick": 0, "type": t, "cls": schema.EVENTS[t][0], "msg": msg, "d": d}
    ok = [e("ARRIVAL", {"kind": "siege", "src": "popup", "text": "A vile force of darkness has arrived!", "raised": 3,
                        "doors": 1, "alert": "on Kern+", "clock": 30, "out": 2, "eta": 48}),
          e("INTRUDER", {"n": 6, "id": 201, "pos": [51, 0, 10], "k": "inv"}),
          e("PREDATOR", {"n": 1, "id": 400, "pos": [62, 72, 10]}),
          e("NO_DEPOT", {"text": "The merchants need a trade depot to unload their goods."}),
          e("LOCKDOWN", {"why": "ack_timeout", "n": 52, "type": "DEATHS_3PLUS", "clock": 30}),
          e("LOCKDOWN_END", {"why": "arrival:siege", "ticks": 5000, "doors": 1})]
    for ev in ok:
        assert schema.validate("event", ev) == [], ev
    assert schema.validate("event", e("ARRIVAL", {"src": "popup"}))           # kind is required
    assert schema.validate("event", e("INTRUDER", {"pos": [1, 2]}))
    assert schema.validate("event", dict(e("SIEGE_START", {}), cls="B"))     # class A since Run 9
    assert set(schema.INTERRUPTS) <= {t for t, (c, _, _) in schema.EVENTS.items() if c == "A"}


def test_decision_d14_peace_gates(tmp_path):
    from dfpilot import fairplay
    assert schema.DECISIONS["D-14"] == "down"
    p = tmp_path / "decisions.yaml"
    p.write_text("D-14: up  # answered\n", encoding="utf-8")
    assert fairplay.decision_errors(p) == [] and fairplay.get_decision("D-14", p) == "up"
    p.write_text("D-14: open\n", encoding="utf-8")
    assert fairplay.decision_errors(p) and fairplay.get_decision("D-14", p) == "down"
    shipped = fairplay.parse_decision_lines((fairplay.REPO / "config" / "decisions.yaml").read_text(encoding="utf-8"))
    assert shipped["D-14"][0] == "down" and shipped["D-14"][1].startswith("answered 2026-10-15 by Gordon")


def test_reflex_config_validation(tmp_path):
    from dfpilot import fairplay
    assert fairplay.reflex_errors() == []                                    # the shipped config/reflex.json
    shipped = json.loads((fairplay.REPO / "config" / "reflex.json").read_text(encoding="utf-8"))
    assert shipped["clock"] == {"siege_cap": 30, "alert_cap": 100, "trade_cap": 100} and shipped["ack_timeout_s"] == 60
    assert sorted(shipped["defaults"]) == sorted(schema.INTERRUPTS)
    p = tmp_path / "reflex.json"
    assert fairplay.reflex_errors(p) == []                                   # missing: all defaults
    p.write_text(json.dumps({"v": 2, "clock": {"siege_cap": 5, "warp": 1, "trade_cap": 2000}, "ack_timeout_s": True,
                             "defaults": {"ARRIVAL": ["clock", "nuke"], "SIEGE_END": []}, "x": 1}), encoding="utf-8")
    errs = fairplay.reflex_errors(p)
    for needle in ("clock.siege_cap", "clock.warp", "clock.trade_cap", "ack_timeout_s", "defaults.ARRIVAL", "defaults.SIEGE_END",
                   "unknown key 'x'"):
        assert any(needle in e for e in errs), (needle, errs)
    assert shipped["refuge"] == {"bed_pct": 25, "breach_days": 7}            # seal.CFG defaults (refuge beds, BUG-019)
    p.write_text(json.dumps({"v": 2, "refuge": {"bed_pct": 101, "breach_days": 3, "tiles": 1}}), encoding="utf-8")
    errs = fairplay.reflex_errors(p)
    assert any("refuge.bed_pct" in e for e in errs) and any("refuge.tiles: unknown key" in e for e in errs), errs
    assert not any("breach_days" in e for e in errs), errs
    p.write_text("{", encoding="utf-8")
    assert fairplay.reflex_errors(p)[0].startswith("config/reflex.json: not JSON")


def test_reflex_config_intake_and_sortie(tmp_path):
    """Gordon 2026-10-16: the intake waves and the sortie through O1; the shipped values are the kernel's defaults
    (lua/dfllm/siege.lua M.IK / M.SO) and every key has the kernel's limits (M.IK_LIM / M.SO_LIM)."""
    import re
    from dfpilot import fairplay
    shipped = json.loads((fairplay.REPO / "config" / "reflex.json").read_text(encoding="utf-8"))
    lua = (fairplay.REPO / "lua" / "dfllm" / "siege.lua").read_text(encoding="utf-8")

    def table(name):
        m = re.search(r"^M\." + name + r" = \{(.*?)\}\n(?=M\.|local|--)", lua, re.S | re.M)
        assert m, name
        out = {}
        for k, v in re.findall(r"(\w+) = (\{\d+, \d+\}|true|false|\d+)", m.group(1)):
            out[k] = True if v == "true" else False if v == "false" else (
                tuple(int(x) for x in re.findall(r"\d+", v)) if v.startswith("{") else int(v))
        return out
    assert shipped["intake"] == table("IK") and shipped["sortie"] == table("SO")
    lim_i = {k: v for k, v in fairplay.INTAKE_LIM.items() if v != "bool"}
    assert table("IK_LIM") == lim_i and table("SO_LIM") == fairplay.SORTIE_LIM
    assert set(fairplay.INTAKE_LIM) == set(shipped["intake"]) and set(fairplay.SORTIE_LIM) == set(shipped["sortie"])
    p = tmp_path / "reflex.json"
    p.write_text(json.dumps({"v": 2, "intake": {"on": 1, "wave": 0, "cooldown": 1200, "zap": 1},
                             "sortie": {"worn": 101, "near": 5}}), encoding="utf-8")
    errs = fairplay.reflex_errors(p)
    for needle in ("intake.on: true or false", "intake.wave: int 1..40", "intake.zap: unknown key", "sortie.worn"):
        assert any(needle in e for e in errs), (needle, errs)
    assert not any("cooldown" in e or "near" in e for e in errs), errs


def test_reflex_config_stations(tmp_path):
    """BUG-030: the deep defense's knobs; the shipped values are the kernel's defaults (lua/dfllm/siege.lua M.ST) with
    the kernel's limits (M.ST_LIM)."""
    import re
    from dfpilot import fairplay
    shipped = json.loads((fairplay.REPO / "config" / "reflex.json").read_text(encoding="utf-8"))
    lua = (fairplay.REPO / "lua" / "dfllm" / "siege.lua").read_text(encoding="utf-8")

    def table(name):
        m = re.search(r"^M\." + name + r" = \{(.*?)\}\n", lua, re.M)
        assert m, name
        return {k: (tuple(int(x) for x in re.findall(r"\d+", v)) if v.startswith("{") else int(v))
                for k, v in re.findall(r"(\w+) = (\{\d+, \d+\}|\d+)", m.group(1))}
    assert shipped["stations"] == table("ST") == {"core_ratio": 3, "worn": 60, "metal": 0}
    assert table("ST_LIM") == fairplay.STATIONS_LIM
    p = tmp_path / "reflex.json"
    p.write_text(json.dumps({"v": 2, "stations": {"core_ratio": 0, "worn": 60, "zap": 1}}), encoding="utf-8")
    errs = fairplay.reflex_errors(p)
    for needle in ("stations.core_ratio: int 1..50", "stations.zap: unknown key"):
        assert any(needle in e for e in errs), (needle, errs)
    assert not any("stations.worn" in e for e in errs), errs
    assert fairplay.reflex_errors(fairplay.REPO / "config" / "reflex.json") == []
