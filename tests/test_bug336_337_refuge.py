"""Run 15b Earthboat y387 (i3, pop 92 -> 1): BUG-336 the refuge hatch 55,82,133 stalled 911 days, the refuge was still the
civilians' burrow (5 trolls walked down the open stair after them); BUG-337 SIEGE_DEEP called a refuge closed only by a hatch
'the separated refuge' with building destroyers in sight. The kernel behaviour is tested in tests/lua/test_seal_refuge.lua,
tests/lua/test_intake.lua and tests/lua/test_bug336_seal_escalate.lua; here the Python side of the contract."""
import json
from pathlib import Path

from test_bug313_boxed_hatch import earthboat, save  # noqa: F401  (the Earthboat shaft and its runtime fixture)

from dfpilot import brief, cmd, fairplay, files, plan, schema, wake

ROOT = Path(__file__).resolve().parents[1]


def test_bug336_brief_says_the_open_refuge_is_not_used_in_a_fight():
    al = {"burrow": "Kern+", "tiles": 900, "inside": 40, "ok": 1, "want": "Kern+",
          "ref": {"ex": 1, "sep": 1, "beds": 20, "need": 21, "tr": 0, "trw": "no hatch at 55,82,133", "op": 1}}
    txt = brief.line_alert(al)
    assert "refuge NOT TRUSTED: no hatch at 55,82,133" in txt
    assert "REFUGE OPEN: not used in a siege or breach" in txt and "bp.place tpl=seal site=S1 at=refuge" in txt
    del al["ref"]["op"]
    assert "REFUGE OPEN" not in brief.line_alert(al)
    al["ref"]["sf"] = 1                        # BUG-337 review: destroyers in sight, only a hatch closes it
    assert "refuge closed by a hatch/door only: building destroyers in sight break it" in brief.line_alert(al)


def test_bug336_state_and_events_carry_the_new_fields():
    assert "op" in schema.STATE.opt["alert"].opt["ref"].opt
    assert "sf" in schema.STATE.opt["alert"].opt["ref"].opt
    assert schema.validate_event_d("SIEGE_DEEP", {"why": ["destroyers"], "ropen": "open: no hatch at 55,82,133",
                                                  "soft": "hatch"}) == []
    assert schema.validate_event_d("DECISION_NEEDED", {"id": "seal_stalled", "q": "seal y384s1b0: hatch 55,82,133 open",
                                                       "n": 30, "mat": "hatch 55,82,133", "proj": "y384s1b0",
                                                       "cmd": "dfllm cmd bp.cancel ...", "how": "build it by hand"}) == []
    contract = (ROOT / "lua" / "dfllm" / "util" / "contract.lua").read_text(encoding="utf-8")
    assert "op = FLAG," in contract and "sf = FLAG}" in contract


def test_bug336_esc_days_is_known_to_the_config_lint(tmp_path):
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"runner": {"seal_first": {"esc_days": 20}}}), encoding="utf-8")
    assert fairplay.runner_errors(p) == []
    p.write_text(json.dumps({"runner": {"seal_first": {"esc_days": 61}}}), encoding="utf-8")
    assert any("esc_days" in e for e in fairplay.runner_errors(p))
    base = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))
    assert base["runner"]["seal_first"]["esc_days"] == 30
    lua = (ROOT / "lua" / "dfllm" / "runner.lua").read_text(encoding="utf-8")
    assert "seal_esc_days = 30," in lua


def test_bug336_wake_hint_tells_gordon_with_the_command():
    d = {"id": "seal_stalled", "proj": "y384s1b0", "mat": "hatch 55,82,133", "n": 30,
         "how": "build it by hand in DF (no tile beside it to build from), or cancel it and put doors round the stair foot",
         "cmd": "dfllm cmd bp.cancel '{\"proj\":\"y384s1b0\"}' then dfllm cmd bp.place "
                "'{\"tpl\":\"seal\",\"site\":\"S1\",\"p\":{\"at\":\"54,82,132 floor\"}}'"}
    h = wake.next_hint("DECISION_NEEDED", {"d": d})
    assert h.startswith("tell Gordon: seal y384s1b0 (hatch 55,82,133) has built nothing for 30 days; build it by hand")
    assert '"site":"S1"' in h and "that way in is open" in h


# BUG-336 review: the verifier ran schema.validate_args on the old d.cmd ({"tpl":"seal","at":"refuge"}: $.args.site
# missing). These are the commands tests/lua/test_bug336_seal_escalate.lua locks in, byte for byte: each bp.place half
# must pass the CLI schema and the seal template's own param check.
KERNEL_CMDS = [
    """dfllm cmd bp.cancel '{"proj":"sl"}' then dfllm cmd bp.place """
    """'{"tpl":"seal","site":"S1","p":{"at":"114,73,143 floor","close":"wall"}}'""",
    """dfllm cmd bp.cancel '{"proj":"rf"}' then dfllm cmd bp.place '{"tpl":"seal","site":"S1","p":{"at":"refuge"}}'""",
    """dfllm cmd bp.cancel '{"proj":"rf"}' then dfllm cmd bp.place """
    """'{"tpl":"seal","site":"S1","p":{"at":"115,73,141 floor;114,74,141 floor"}}'""",
]


def _args(cmd: str, verb: str) -> dict:
    part = cmd.split(f"dfllm cmd {verb} ", 1)[1]
    return json.loads(part.split("'")[1])


def test_bug336_review_seal_stalled_commands_pass_the_schema():
    from dfpilot.bp import defense
    lua = (ROOT / "tests" / "lua" / "test_bug336_seal_escalate.lua").read_text(encoding="utf-8")
    for cmd in KERNEL_CMDS:
        for frag in (cmd.split(" then ")[0], cmd.split(" then ")[1].split("bp.place ")[1]):
            assert frag in lua, frag                   # the Lua test locks in the same bytes
        place, cancel = _args(cmd, "bp.place"), _args(cmd, "bp.cancel")
        assert schema.validate_args("bp.place", place) == [], cmd
        assert schema.validate_args("bp.cancel", cancel) == [], cmd
        assert len(cmd.encode()) <= 200
        if place["p"]["at"] != "refuge":
            assert defense.seal_pieces(place["p"])     # raises ValueError on a bad at/close
    assert schema.validate_args("bp.place", {"tpl": "seal", "at": "refuge"}) != []    # the old command


# BUG-336 review: the doors round the stair foot the kernel's seal_stalled offers instead of a hatch nobody builds. Once
# they stand, `seal at=refuge` and the plan check stop demanding the head hatch (cmd.refuge_stair state foot), as the
# kernel's refuge_open / refuge_trust stop calling the refuge open.


def _foot(doors: bool) -> dict:
    """z132: the stair foot 55,82 walled in but for 56,82 and 55,83 (doors there, or floor)."""
    c = "+" if doors else "."
    t = {(x, y, 132): "#" for x in (54, 55, 56) for y in (81, 82, 83)}
    t.update({(55, 82, 132): "<", (56, 82, 132): c, (55, 83, 132): c})
    return t


def test_bug336_review_doors_round_the_stair_foot_close_the_refuge(save):
    earthboat(save, extra=_foot(True))
    rs = cmd.refuge_stair(save)
    assert (rs["state"], rs["head"]) == ("foot", None), "old: the hatch on the head demanded for ever"
    assert "doors close every tile beside the stair foot 55,82,132" in rs["note"]
    st = files.read_state(save)
    st["phase"] = "P1"
    st.setdefault("alert", {"want": "Kern+", "burrow": "Kern+", "tiles": 100, "inside": 5, "ok": 1})
    st["alert"]["ref"] = {"ex": 1, "sep": 1, "beds": 13, "need": 13}
    assert plan.fort_facts(save, st)["refuge"]["head_open"] is False


def test_bug336_review_an_open_tile_beside_the_foot_keeps_the_head_hatch(save):
    earthboat(save, extra=_foot(False))
    assert cmd.refuge_stair(save)["state"] in ("ok", "moved")
    assert not cmd.foot_closed(None, 55, 82, 132)
