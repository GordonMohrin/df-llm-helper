"""Old name of the `dfpilot` package (2026-10-02 .. 2026-10-15), kept so that running setups still work.

`python -m df_llm_helper ...` and `python -m df_llm_helper.hook` load the modules of `dfpilot` (this package's
module search path is dfpilot's folder). Use `python -m dfpilot ...` in new setups.
"""
from pathlib import Path as _Path

__path__ = [str(_Path(__file__).resolve().parent.parent / "dfpilot")]
