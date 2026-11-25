"""BUG-864 / BUG-867: the new baseline keys are linted (military.elite_off, economy.cancel.cx_off_n / cx_off_days) and the shipped file passes."""
import json

from dfpilot import fairplay


def test_elite_off_is_a_bool(tmp_path):
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"military": {"elite_off": "yes"}}), encoding="utf-8")
    errs = fairplay.military_errors(p)
    assert any("elite_off" in e and "true or false" in e for e in errs), errs
    p.write_text(json.dumps({"military": {"elite_off": True}}), encoding="utf-8")
    assert fairplay.military_errors(p) == []


def test_shipped_baseline_has_the_keys_and_lints():
    doc = json.loads(open(fairplay.BASELINE_PATH, encoding="utf-8").read())
    assert doc["military"]["elite_off"] is False
    assert doc["economy"]["cancel"]["cx_off_n"] == 2 and doc["economy"]["cancel"]["cx_off_days"] == 14
    assert fairplay.military_errors() == []
