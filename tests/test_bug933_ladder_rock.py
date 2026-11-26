"""NEU20a BUG-933: the ladder names `order.add MakeBarrel mat=rock` only when a boulder a job may take is free (state stock.rock, no stock.rhard); otherwise wood from the caravans."""
from dfpilot import leiter


def _stock(**kw):
    st = {"drink_d": 0, "food_d": 200, "dcx": 1, "dwhy": "Needs empty food storage item", "wood": 0}
    st.update(kw)
    return {"stock": st}


def test_no_free_stone_no_rock_barrel_command():
    lvl, why, cmd, key, _ = leiter.t_versorgung(_stock(rock=0), {}, 1000)
    assert "mat" not in cmd and "rock" not in cmd, cmd
    assert "trade.want" in cmd and "wood" in cmd and key == "trade:wood"


def test_refused_stone_no_rock_barrel_command():
    lvl, why, cmd, key, _ = leiter.t_versorgung(_stock(rock=12, rhard=1), {}, 1000)
    assert "order.add" not in cmd and key == "trade:wood"


def test_free_stone_keeps_the_rock_barrel_command():
    lvl, why, cmd, key, _ = leiter.t_versorgung(_stock(rock=12), {}, 1000)
    assert "order.add" in cmd and '"mat":"rock"' in cmd, cmd
    assert key == "order:barrel"


def test_wood_in_the_fort_names_the_wood_barrel():
    lvl, why, cmd, key, _ = leiter.t_versorgung(_stock(wood=88), {}, 1000)
    assert '"mat":"wood"' in cmd, cmd
