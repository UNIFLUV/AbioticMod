"""Run Lua 5.4 probe tests without requiring the Windows game or UE4SS."""
from pathlib import Path
import os
import subprocess
import sys

from lupa.lua54 import LuaRuntime

root = Path(__file__).resolve().parents[1]
os.chdir(root)
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("package.path = 'mods/AbioticSplitScreen/Scripts/?.lua;' .. package.path")
lua.execute((root / "tests" / "split_probe_spec.lua").read_text(encoding="utf-8"))
lua.execute((root / "tests" / "session_tools_spec.lua").read_text(encoding="utf-8"))
lua.execute((root / "tests" / "player_bindings_spec.lua").read_text(encoding="utf-8"))
lua.execute((root / "tests" / "hud_link_spec.lua").read_text(encoding="utf-8"))
lua.execute((root / "tests" / "inventory_ui_spec.lua").read_text(encoding="utf-8"))
lua.execute((root / "tests" / "waypoint_ui_spec.lua").read_text(encoding="utf-8"))
lua.execute((root / "tests" / "main_runtime_spec.lua").read_text(encoding="utf-8"))
lua.execute((root / "tests" / "ui_context_spec.lua").read_text(encoding="utf-8"))
lua.execute((root / "tests" / "container_ui_spec.lua").read_text(encoding="utf-8"))
lua.execute((root / "tests" / "container_handoff_spec.lua").read_text(encoding="utf-8"))
lua.execute((root / "tests" / "container_actions_spec.lua").read_text(encoding="utf-8"))
lua.execute((root / "tests" / "container_delegates_spec.lua").read_text(encoding="utf-8"))
lua.execute((root / "tests" / "script_probe_spec.lua").read_text(encoding="utf-8"))
lua.execute((root / "tests" / "shared_pause_spec.lua").read_text(encoding="utf-8"))
lua.execute((root / "tests" / "preview_ui_spec.lua").read_text(encoding="utf-8"))
subprocess.run([sys.executable, str(root / 'tests/script_report_spec.py')], check=True)
