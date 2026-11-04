"""Shared test setup."""
import pytest


@pytest.fixture(autouse=True)
def _no_automatic_snapshot(monkeypatch):
    """BUG-369: `bp sites`, `plan` and `cmd bp.place` ask the kernel for a new snapshot when the cached one predates a finished
    stage and the heartbeat is fresh. The fixture runtimes have both and no kernel that answers: the request would wait for
    its timeout in every test that ranks. test_bug368_370_depot_fresh_walk.py switches it on again."""
    from dfpilot import cmd
    monkeypatch.setattr(cmd, "AUTO_SNAP", False)
