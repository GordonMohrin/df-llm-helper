"""BUG-544 to BUG-547 (round 35, stone and link jobs): the file-level contracts that need no Lua.

The Lua behaviour is in tests/lua/test_bug544_547_stone_manager.lua, test_bug546_link_reissue.lua (the siege / drill traffic test) and
test_bug546_547_acts.lua. Here: the lint lets exactly the new act functions write what they write (labor_set: mechanic on / farm off,
cancel_link_job: removeJob), the act table mirrors the contract, and the wake line of the new decision names its commands.
"""
import textwrap
from pathlib import Path

from dfpilot import lint as L
from dfpilot import schema, wake

ROOT = Path(__file__).resolve().parent.parent


def test_lint_labor_write_allowed_in_labor_set_only():
    src = textwrap.dedent("""
        local I = {}
        function I.labor_set(id, which, on)
          local u = df.unit.find(id)
          u.status.labors[df.unit_labor.PLANT] = on
        end
        function I.other(u) u.status.labors[0] = true end
        return I
    """)
    found = [(f["line"], f["rule"]) for f in L.lua_source(src, "lua/dfllm/act.lua")]
    assert found == [(7, "labor-write")]
    assert "labor-write" in {f["rule"] for f in L.lua_source(src, "lua/dfllm/economy.lua")}


def test_lint_removejob_allowed_in_cancel_link_job_and_cancel_own_lever_job_only():
    src = textwrap.dedent("""
        local I = {}
        function I.cancel_link_job(id)
          for _, j in ipairs(x) do dfhack.job.removeJob(j) end
        end
        function I.cancel_own_lever_job(id) dfhack.job.removeJob(id) end
        function I.other(j) dfhack.job.removeJob(j) end
        return I
    """)
    found = [(f["line"], f["rule"]) for f in L.lua_source(src, "lua/dfllm/act.lua")]
    assert found == [(7, "remove-job")]
    assert "remove-job" in {f["rule"] for f in L.lua_source(src, "lua/dfllm/gate.lua")}


def test_the_new_acts_are_owned_and_mirror_the_contract():
    assert schema.ACT["cancel_link_job"] == ["gate"]
    assert schema.ACT["labor_set"] == ["economy"]
    lua = (ROOT / "lua" / "dfllm" / "util" / "contract.lua").read_text(encoding="utf-8")
    assert "cancel_link_job = {'gate'}" in lua and "labor_set = {'economy'}" in lua


def test_the_real_act_lua_passes_the_lint():
    assert L.lua_source((ROOT / "lua" / "dfllm" / "act.lua").read_text(encoding="utf-8"), "lua/dfllm/act.lua") == []


def test_no_hard_stone_wake_line_names_the_commands():
    cmds = ["dfllm cmd trade.want '{\"add\":[\"stone\",\"mechanism\"]}'", "dfllm plan propose", "dfllm cmd inspect '{\"what\":\"workload\"}'"]
    d = {"id": "no_hard_stone", "cause": "none", "n": 0, "cmds": cmds,
         "q": "no non-economic hard stone: 101 boulders, 0 usable (14 economic/soft, 2 ore/flux, 0 out of reach); no mechanisms"}
    hint = wake.next_hint("DECISION_NEEDED", {"d": d})
    assert cmds[0] in hint and "plan propose" in hint and "101 boulders" in hint, hint
