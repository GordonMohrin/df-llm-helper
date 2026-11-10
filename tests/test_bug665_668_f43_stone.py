"""BUG-665 / BUG-666 / BUG-667 (Run 16 round 19 stone and wood: Valleyhame / Basementflew boulders counted usable beside DF's "Needs non-economic
hard stone", Trumpetrealms door orders in rock only, depot and seal wall waiting for building material with stone 0). The Lua side is
tests/lua/test_bug665_668_stone_wood.lua; here the contract:
- order.add takes `mat` (wood | rock) and refuses it together with material / material_category;
- the no_hard_stone hint passes the wooden-door command on."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from dfpilot import schema, wake                                              # noqa: E402


def test_order_add_takes_mat_wood_or_rock():
    assert schema.validate_args("order.add", {"job": "ConstructDoor", "amount": 4, "mat": "wood"}) == []
    assert schema.validate_args("order.add", {"job": "ConstructDoor", "amount": 4, "mat": "rock"}) == []
    assert schema.validate_args("order.add", {"job": "ConstructDoor", "amount": 4, "mat": "glass"}) != []


def test_order_add_mat_clashes_with_material():
    errs = schema.validate_args("order.add", {"job": "ConstructDoor", "amount": 4, "mat": "wood", "material": "INORGANIC"})
    assert errs and "mat replaces" in " ".join(errs), errs
    errs = schema.validate_args("order.add", {"job": "ConstructDoor", "amount": 4, "mat": "wood", "material_category": ["wood"]})
    assert errs, errs


def test_the_hard_stone_hint_names_the_wooden_door():
    d = {"q": "no non-economic hard stone: 100 boulders, 0 usable", "cause": "none",
         "cmds": ["dfllm cmd trade.want '{\"add\":[\"stone\"]}'", "dfllm plan propose",
                  "dfllm cmd order.add '{\"job\":\"ConstructDoor\",\"amount\":4,\"mat\":\"wood\"}'"]}
    txt = wake.no_hard_stone_hint(d)
    assert "doors from wood: dfllm cmd order.add" in txt and '"mat":"wood"' in txt, txt
    assert "doors from wood" not in wake.no_hard_stone_hint(dict(d, cmds=d["cmds"][:2]))
