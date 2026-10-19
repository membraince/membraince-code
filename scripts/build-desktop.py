"""Package the Claude Desktop extension: python scripts/build-desktop.py

The bundle is a zip of the manifest, icon, and bridge, named by manifest version.
"""

import json
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "integrations" / "claude-desktop"
FILES = ["manifest.json", "icon.png", "server/index.js"]

version = json.loads((SOURCE / "manifest.json").read_text(encoding="utf-8"))["version"]
target = ROOT / "dist" / f"membraince-desktop-{version}.mcpb"
target.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as bundle:
    for name in FILES:
        bundle.write(SOURCE / name, name)
print(target)
