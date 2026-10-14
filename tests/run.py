#!/usr/bin/env python3
"""Run the actual block in Luau with a deterministic Tern/process harness."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "host.luau").read_text()
harness = (root / "tests/block.luau").read_text()
with tempfile.TemporaryDirectory() as directory:
    script = Path(directory) / "block.luau"
    script.write_text(harness.replace("-- BLOCK_SOURCE", source))
    subprocess.run([os.environ.get("LUAU", "luau"), str(script)], check=True)
