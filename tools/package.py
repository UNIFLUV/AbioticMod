"""Build a source-only UE4SS mod ZIP; never include game files or UE4SS binaries."""
from pathlib import Path
import argparse
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
args.output.parent.mkdir(parents=True, exist_ok=True)
mod = root / "mods" / "AbioticSplitScreen"
files = [mod / "enabled.txt", mod / "Scripts" / "main.lua", mod / "Scripts" / "split_probe.lua", mod / "Scripts" / "session_tools.lua", mod / "Scripts" / "player_bindings.lua", mod / "Scripts" / "hud_link.lua", mod / "Scripts" / "routing_probe.lua", mod / "Scripts" / "inventory_ui.lua", mod / "Scripts" / "waypoint_ui.lua"]
with ZipFile(args.output, "w", compression=ZIP_DEFLATED) as archive:
    for path in files:
        entry = ZipInfo(path.relative_to(mod.parent).as_posix(), date_time=(2026, 1, 1, 0, 0, 0))
        entry.compress_type = ZIP_DEFLATED
        entry.external_attr = 0o100644 << 16
        archive.writestr(entry, path.read_bytes())
    entry = ZipInfo("AbioticSplitScreen/INSTALL.ru.md", date_time=(2026, 1, 1, 0, 0, 0))
    entry.compress_type = ZIP_DEFLATED
    entry.external_attr = 0o100644 << 16
    archive.writestr(entry, (root / "docs" / "PROTOTYPE.ru.md").read_bytes())
print(args.output)
