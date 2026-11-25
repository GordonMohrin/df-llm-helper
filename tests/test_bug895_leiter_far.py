"""NEU14 BUG-895 (Run 17c i3 Orangering y459: two corpses corpse_far at 88,83,145, 69 free coffins, 'NAECHST Wohl I: 2 Tote unbestattet -> tombs.repair' for 40 days):
a body in another walk group is out of reach of coffins, zones and tombs.repair; the ladder says so and names no repair command, and a far body whose memorial slab
stands is not counted at all (care.lua: corpses_old without it)."""
from test_neu1_wertung_leiter import cfg_dir, run_dir, state  # noqa: F401  (fixtures and helpers of the ladder tests)

from dfpilot import leiter


def test_every_unburied_body_out_of_reach_names_no_repair(tmp_path, cfg_dir):  # noqa: F811
    d = run_dir(tmp_path)
    s = state(care={"ghosts": 0, "corpses_old": 2, "corpses_far": 2, "tombs_free": 69}, pop={"cit": 40},
              ready={"lvl": 1, "open": 0, "fail": []})
    w = leiter.compute(d, s)["tracks"]["wohl"]
    assert "tombs.repair" not in w["cmd"], w
    assert "ausser Reichweite" in w["need"] and "Gedenkplatte" in w["need"], w
    assert w["cmd"] == "dfllm cmd inspect what=tombs", w


def test_a_mix_keeps_the_repair_and_the_old_text(tmp_path, cfg_dir):  # noqa: F811
    d = run_dir(tmp_path)
    s = state(care={"ghosts": 1, "corpses_old": 3, "corpses_far": 2, "tombs_free": 5}, pop={"cit": 40},
              ready={"lvl": 1, "open": 0, "fail": []})
    w = leiter.compute(d, s)["tracks"]["wohl"]
    assert w["cmd"] == "dfllm cmd tombs.repair", w
    assert "3 Tote unbestattet" in w["need"], w


def test_no_far_counter_is_the_old_ladder(tmp_path, cfg_dir):  # noqa: F811
    d = run_dir(tmp_path)
    s = state(care={"ghosts": 2, "corpses_old": 3, "tombs_free": 2}, pop={"cit": 40}, ready={"lvl": 1, "open": 0, "fail": []})
    w = leiter.compute(d, s)["tracks"]["wohl"]
    assert w["cmd"] == "dfllm cmd tombs.repair", w
