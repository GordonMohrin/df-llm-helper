"""BUG-751 / BUG-752 (Round 48): act.cancel_stray_job is the third place removeJob is allowed, the act table and the contract agree,
MISSING is a class A seal event known to schema, contract and wake, and the Lua half is registered (seal job `stray`)."""
from pathlib import Path

from dfpilot import lint, schema, wake

ROOT = Path(__file__).resolve().parents[1]



def test_act_owner_in_schema_and_contract():
    assert schema.ACT["cancel_stray_job"] == ["seal"]
    lua = (ROOT / "lua/dfllm/util/contract.lua").read_text(encoding="utf-8")
    assert "cancel_stray_job = {'seal'}" in lua
    assert "MISSING = {cls = 'A', by = 'seal'}" in lua


def test_missing_event_is_class_a_seal():
    cls, by, spec = schema.EVENTS["MISSING"]
    assert (cls, by) == ("A", "seal")
    assert "unit" in spec.req and "why" in spec.req
    assert "job" in schema.EVENTS["CUTOFF"][2].opt
    assert "sep" in schema.EVENTS["STRANDED"][2].opt


def test_lint_allows_remove_job_only_in_the_three_cancel_functions():
    lint_src = (ROOT / "dfpilot/lint.py").read_text(encoding="utf-8")
    assert 'self.in_func("cancel_stray_job")' in lint_src
    act = (ROOT / "lua/dfllm/act.lua").read_text(encoding="utf-8")
    i = act.index("function I.cancel_stray_job")
    assert "dfhack.job.removeJob" in act[i:i + 1500]
    assert act.count("dfhack.job.removeJob") == 3


def test_wake_hint_for_missing():
    assert "MISSING" in (ROOT / "dfpilot/wake.py").read_text(encoding="utf-8")


def test_seal_job_stray_registered():
    seal = (ROOT / "lua/dfllm/seal.lua").read_text(encoding="utf-8")
    assert "'bguard', 'stray'}" in seal and "stray = function(K) M.job_stray(K) end" in seal
