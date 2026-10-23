"""Package L1 (BUG-102, FR-82): the drink-nook knobs of care are checked by `lint --config` and documented in the contract."""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from dfpilot import fairplay  # noqa: E402

KEYS = ("mood_nook_r", "mood_nook_rmax", "mood_nook_step", "mood_nook_probes", "mood_nook_tries")


def test_baseline_has_the_nook_keys_with_safe_defaults():
    care = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))["care"]
    assert [care[k] for k in KEYS] == [3, 9, 3, 40, 4]
    assert fairplay.care_errors() == []


def test_the_nook_keys_are_range_checked(tmp_path):
    p = tmp_path / "baseline.json"
    for key, bad in (("mood_nook_r", 0), ("mood_nook_r", 13), ("mood_nook_rmax", 13), ("mood_nook_rmax", -1),
                     ("mood_nook_step", 0), ("mood_nook_probes", 0), ("mood_nook_probes", 201), ("mood_nook_tries", 0),
                     ("mood_nook_tries", "4")):
        p.write_text(json.dumps({"care": {key: bad}}), encoding="utf-8")
        errs = fairplay.care_errors(p)
        assert len(errs) == 1 and key in errs[0], (key, bad, errs)
    p.write_text(json.dumps({"care": {"mood_nook_r": 3, "mood_nook_rmax": 0, "mood_nook_step": 6, "mood_nook_probes": 200,
                                      "mood_nook_tries": 12}}), encoding="utf-8")
    assert fairplay.care_errors(p) == []


def test_the_contract_names_the_nook_keys_and_the_new_module_calls():
    text = (ROOT / "docs" / "v2" / "CONTRACTS.md").read_text(encoding="utf-8")
    for key in KEYS:
        assert re.search(rf"`{key}`", text), key
    assert "`snapshot.item_tiles(" in text and "`runner.nook_state(" in text
