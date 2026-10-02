import os
import shutil
from pathlib import Path

import pytest

from df_llm_helper.client import MAX_REPORT_ID_CMD, SERVICES_CMD, MockClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.config import load_config
from df_llm_helper.store import Store

HERE = Path(__file__).resolve().parent
HOME = HERE.parent
FIX = HOME / "fixtures" / "run5"
REPO = HOME.parent

# synthetic responses for commands without a real fixture (gap noted in CHANGELOG.md)
SERVICES_ALL_ON = " ".join(f"claude-{k}=true" for k in
                           ["watchdog", "arbeit", "trinken", "ueberwacher", "essen", "orders", "gesund",
                            "auslastung", "material", "tempo", "migranten", "schau"])


@pytest.fixture
def clock():
    return FakeClock(1_790_840_000.0)


@pytest.fixture
def mock(clock):
    m = MockClient.from_fixture_dir(FIX, clock=clock)
    m.set(MAX_REPORT_ID_CMD, "5000")
    m.set(SERVICES_CMD, SERVICES_ALL_ON)
    return m


@pytest.fixture
def tools_dir(tmp_path):
    t = tmp_path / "tools"
    (t / "scopes").mkdir(parents=True)
    shutil.copy(FIX / "scopes_sample" / "inbox-orchestrator.md", t / "scopes" / "inbox-orchestrator.md")
    (t / "events.log").write_text("info 10:00:00 [X] start\n", encoding="utf-8")
    (t / "last-report-id.txt").write_text("4990", encoding="utf-8")
    return t


@pytest.fixture
def cfg(tools_dir, tmp_path):
    return load_config(path=tmp_path / "nonexistent.yaml",
                       overrides={"paths": {"tools": str(tools_dir), "scopes": str(tools_dir / "scopes"),
                                            "state_db": str(tmp_path / "state.db"),
                                            "exceptions": str(tmp_path / "exceptions.jsonl")}})


@pytest.fixture
def store():
    return Store(":memory:")


def set_age(path: Path, clock: FakeClock, minutes: float) -> None:
    t = clock.now().epoch - minutes * 60
    os.utime(path, (t, t))
