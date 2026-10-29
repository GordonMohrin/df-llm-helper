"""BUG-324 (Run 15 Inkintense/Earthboat): the water the kernel's scan found never became accepted water, so `bp sites
hospital` refused every site for years. The kernel now zones it (water.lua M.zone_found, act.water_zone); the Python side
names that, accepts the zone's source like any other, and the config takes the new water keys. Fails on 1d17c7e."""
import json

import pytest

from dfpilot import fairplay
from dfpilot.bp import sites


def test_no_accepted_water_names_the_kernel_zone_of_the_found_water():
    with pytest.raises(ValueError, match=r"the kernel zones it as Water Source dfllm-water itself while none is accepted"):
        sites._near_water([], "hospital", {}, {"src": [], "cand": "water 88,102,132 (7/7): a well at 88,102,133 over it"})


def test_the_zone_on_the_found_water_is_a_source_the_hospital_sites_follow(monkeypatch):
    monkeypatch.setattr(sites, "zone_box", lambda tpl, p, anchor, rot: [anchor[0], anchor[1], anchor[2],
                                                                       anchor[0] + 4, anchor[1] + 4, anchor[2]])
    cands = [{"anchor": [80, 100, 133], "rot": 0, "score": 10, "why": "S1"},
             {"anchor": [10, 10, 133], "rot": 0, "score": 50, "why": "S2"}]
    out = sites._near_water(cands, "hospital", {}, {"src": [[88, 102, 132]], "lbl": ["zone 18123 in Kern+"], "near": 30})
    assert [c["why"].split(",")[0] for c in out] == ["S1"]
    assert "zone 18123 at 88,102,132 in Kern+" in out[0]["why"]


def test_config_takes_the_new_water_keys(tmp_path):
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "water": {"wz": True, "wz_every": 2400, "wz_max": 4, "wz_forget": 33600,
                                                "ws_from": 3}}), encoding="utf-8")
    assert fairplay.water_errors(p) == [], "old code: unknown keys"
    p.write_text(json.dumps({"v": 2, "water": {"wz": 1, "ws_from": 0}}), encoding="utf-8")
    assert len(fairplay.water_errors(p)) == 2
