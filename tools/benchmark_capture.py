#!/usr/bin/env python3
"""Read-only benchmark for the supplied HouseCapture archives.

It checks practical data completeness and reports only what is in each archive;
it intentionally makes no geometric-accuracy or sub-millimetre claim.
"""
from __future__ import annotations

import argparse
import json
import zipfile
from collections import Counter
from pathlib import Path

REQUIRED_DEPTHFORGE = {"manifest.json", "frames/index.jsonl"}

def inspect(path: Path) -> dict:
    with zipfile.ZipFile(path) as archive:
        names = [name for name in archive.namelist() if not name.endswith("/")]
    suffixes = Counter(Path(name).suffix.lower() for name in names)
    kinds = {
        "depth_f16z": sum(name.endswith(".f16z") for name in names),
        "confidence": sum(name.endswith(".conf") for name in names),
        "rgb_jpeg": sum(name.lower().endswith((".jpg", ".jpeg")) for name in names),
        "ply": sum(name.endswith(".ply") for name in names),
        "roomplan_usdz": sum(name.endswith(".usdz") for name in names),
        "frame_index": sum(name.endswith("frames.json") or name.endswith("index.jsonl") for name in names),
    }
    return {"archive": path.name, "files": len(names), "kinds": kinds, "suffixes": dict(suffixes)}

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archives", nargs="+", type=Path)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    report = [inspect(path) for path in args.archives]
    print(json.dumps(report, indent=2))
    if args.json: args.json.write_text(json.dumps(report, indent=2), encoding="utf-8")

if __name__ == "__main__": main()
