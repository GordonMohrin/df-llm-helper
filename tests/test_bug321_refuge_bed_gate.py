"""BUG-321 (Run 15b Earthboat y385: `plan propose` ERROR 'Tiefe+ has 16 beds < 21 ... add refuge_beds n=3', no free site
even after `bp sites refuge_beds --fresh`, so plan y385 was 'not applied' and y384 stayed active): at P3+ the bed count
is a warning with the next step when no free site takes refuge_beds; with a site it stays the ERROR that asks for it.
The site test (fort.refuge.bed_site) asks for a free site, as bp.place resolves S1."""
import copy
import json

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import files, plan, schema


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.delenv("DFLLM_SAVE", raising=False)
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _state(save, beds, need):
    s = copy.deepcopy(files.read_state(save))
    s.setdefault("alert", {"want": "Kern+", "burrow": "Kern+", "tiles": 100, "inside": 5, "ok": 1})
    s["alert"]["ref"] = {"ex": 1, "sep": 1, "beds": beds, "need": need}
    assert schema.validate("state", s) == []
    return s


def _ref(res):
    errs, warn = res
    return [e for e in errs if e.startswith("refuge")], [w for w in warn if w.startswith("refuge")]


def test_no_bed_site_at_p3_plus_is_a_warning_with_the_next_step(save):
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    doc = copy.deepcopy(prev)
    assert doc["phase_target"] >= "P3"
    state = _state(save, 16, 21)
    fort = {"refuge": {"fortcore": True, "stage3": False, "beds": 2, "seal": False, "ents": 0, "bed_site": False}}
    errs, warn = _ref(plan.check(doc, state, decisions={}, banned=plan.BANNED, prev=prev, fort=fort))
    assert errs == [], "old code: ERROR 'Tiefe+ has 16 beds < 21', the year plan not applicable"
    (w,) = [x for x in warn if "beds" in x]
    assert w.startswith("refuge: Tiefe+ has 16 beds < 21 (+2 under way); no free site takes refuge_beds now: the plan "
                        "may be applied; next: dfllm bp sites refuge_beds --fresh"), w
    site = {"refuge": dict(fort["refuge"], bed_site=True)}             # a free site: the build is asked for
    errs, _ = _ref(plan.check(doc, state, decisions={}, banned=plan.BANNED, prev=prev, fort=site))
    assert any('add {"tpl":"refuge_beds","site":"S1","p":{"n":3}}' in e for e in errs), errs


def test_bed_site_needs_a_free_site(save, monkeypatch):
    state = _state(save, 16, 21)
    monkeypatch.setattr(plan, "sites_snapshot", lambda d: {"id": "s"})
    seen = []

    def free(save_dir, tpl, params=None, snap=None, n=3, where=None, taken=None):
        seen.append((tpl, params, n))
        return [], "s", 3                                  # 3 ranked, all taken by placed projects
    monkeypatch.setattr(plan, "free_sites", free)
    monkeypatch.setattr(plan, "rank_sites", lambda *a, **k: ([{"id": "S1"}], "s"))   # old code: ranked = a site
    assert plan._bed_site(save, state) is False
    assert seen == [("refuge_beds", {"n": 5}, 1)]
