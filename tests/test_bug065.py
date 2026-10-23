"""BUG-065 (Run 14: a gremlin in the caves held the Kern+ lockdown for months) and FR-75 (popups), Python side: the
state fields alarm.age / lim / qw / by, the brief's cause line (the lockdown's cause by unit, race, position, distances,
not 'threat 0 vis'), the wake line's next move for DECISION_NEEDED intruder_sortie / confined_need, and
config/reflex.json confine / popups. The kernel side is tests/lua/test_reflex.lua and tests/lua/test_kern_arbiter.lua."""
import json
from types import SimpleNamespace

from dfpilot import brief, fairplay, schema, wake

BY = {"id": 300, "race": "GREMLIN", "k": "inv", "pos": [110, 20, 91], "dc": 10, "de": 58, "hl": 1, "n": 1, "sz": 4000}


def alarm(**kw):
    a = {"defcon": 3, "unacked": 0, "last": 7, "ack": 7, "lock": 1, "why": "arrival:invader"}
    a.update(kw)
    return a


def ctx(al, vis=0):
    s = {"alarm": al, "threat": {"vis": vis, "armed": 0}, "t": {"tps": 100}}
    return SimpleNamespace(s=s)


def test_state_fields_validate():
    al = alarm(age=5040, lim=12000, qw="near", by=BY)
    bad = dict(al, by=dict(BY, pos=[1, 2]))
    assert schema.validate("state", _full_state(bad)) != []
    assert schema.validate("state", _full_state(al)) == []
    assert schema.validate("state", _full_state(dict(al, qw="x" * 9))) != []


def _full_state(al):
    base = json.loads(json.dumps(_STATE))
    base["alarm"] = al
    return base


_STATE = {"v": 2, "seq": 1, "t": {"y": 3, "tick": 10, "season": 0, "tps": 100, "paused": False}, "mode": "ALERT",
          "k": {"ms_s": 1, "gap_max_ms": 1, "slow": [], "faults": 0}, "ev": 1}


def test_brief_names_the_cause_and_the_clock():
    txt = brief.line_alarm(ctx(alarm(age=5040, lim=12000, qw="near", by=BY)))
    assert "lockdown arrival:invader 4.2 of 10 days" in txt, txt
    assert "inv 300 GREMLIN at 110,20,91" in txt, txt
    assert "10 tiles from a citizen outside Kern+" in txt and "58 from an entrance" in txt, txt
    assert "size 4000, harmless" in txt and "quiet clock: a hostile is near" in txt, txt
    nosz = {k: v for k, v in BY.items() if k != "sz"}
    assert "size unknown, dangerous" in brief.line_alarm(ctx(alarm(age=1, lim=12000, qw="near", by=dict(nosz, hl=0)))), txt


def test_brief_without_a_hostile_says_why_the_lockdown_holds():
    txt = brief.line_alarm(ctx(alarm(age=900, lim=12000, qw="recent")))
    assert "no hostile in sight" in txt and "quiet clock: a trigger within the last 2,400 ticks" in txt, txt
    txt = brief.line_alarm(ctx(alarm(age=900, lim=0, qw="run")))
    assert "no limit" in txt, txt


def test_brief_dangerous_cause_and_threat_line():
    txt = brief.line_alarm(ctx(alarm(age=15000, lim=12000, qw="near", by=dict(BY, hl=0, n=3, k="inv"))))
    assert "dangerous" in txt and "+2 more" in txt and "past the limit" in txt, txt
    # the threat line no longer says '0 vis' alone while a lockdown holds
    d = brief.line_def(ctx(alarm(age=900, lim=12000, qw="recent")))
    assert "threat 0 vis (lockdown holds: quiet clock recent)" in d, d


def test_wake_hints():
    cmd = 'dfllm cmd squad.sortie \'{"squad":"A","target":[110,20,91],"approve":true}\''
    e = {"n": 9, "tick": 5, "type": "DECISION_NEEDED", "cls": "A", "msg": "m",
         "d": {"id": "intruder_sortie", "q": "q", "unit": 300, "hl": 1, "squad": "A", "cmd": cmd, "pos": [110, 20, 91]}}
    h = wake.next_hint("DECISION_NEEDED", e)
    assert cmd in h and "Gordon" in h and "ends by itself" in h, h
    e["d"] = dict(e["d"], hl=0)
    h = wake.next_hint("DECISION_NEEDED", e)
    assert "stays" in h and cmd in h, h
    e["d"] = {"id": "confined_need", "q": "q", "unit": 3, "units": [3], "why": "mood", "thirst": 63513, "hunger": 0, "n": 1}
    h = wake.next_hint("DECISION_NEEDED", e)
    assert "mood" in h and "STRANDED" in h, h
    assert schema.validate("event", dict(e, d=e["d"])) == []


def test_reflex_config_confine_and_popups(tmp_path):
    def errs(doc):
        p = tmp_path / "reflex.json"
        p.write_text(json.dumps(dict({"v": 2}, **doc)), encoding="utf-8")
        return fairplay.reflex_errors(p)
    assert errs({"confine": {"max_days": 10, "harmless_size": 20000, "harmless_races": ["GREMLIN"], "lone_max": 2,
                             "offer_days": 1, "need_thirst": 40000, "need_hunger": 60000},
                 "popups": {"other": False, "other_s": 20, "log_s": 900}}) == []
    assert errs({"confine": {"max_days": 400}})
    assert errs({"confine": {"lone_max": 0}})
    assert errs({"confine": {"harmless_races": ["gremlin"]}})
    assert errs({"confine": {"harmless_races": "GREMLIN"}})
    assert errs({"confine": {"nope": 1}})
    assert errs({"popups": {"other": 1}})
    assert errs({"popups": {"other_s": 2}})
    assert errs({"popups": {"log_s": 10}})
    assert errs({"popups": {"nope": True}})
    real = json.loads((fairplay.REPO / "config" / "reflex.json").read_text(encoding="utf-8"))
    assert real["confine"]["max_days"] == 10 and real["popups"]["other"] is False
    assert fairplay.reflex_errors() == []
