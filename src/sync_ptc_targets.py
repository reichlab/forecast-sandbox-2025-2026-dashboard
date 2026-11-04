#!/usr/bin/env python3
"""
Copy the fan chart's observed-data ("target") JSON files from reichlab/flusight-dashboard's `ptc/data` branch into a
checkout of this repo's `ptc/data` branch.

This dashboard only rebuilds forecast data (see issue #4): the sandbox hub has no time-series.csv, so the target JSON
files that predtimechart shows as observed data are copied from the FluSight dashboard instead. During a season, run
this weekly after the FluSight dashboard updates, then commit and push the `ptc/data` checkout.

    git worktree add ../ptc-data ptc/data        # once
    python3 src/sync_ptc_targets.py ../ptc-data  # copies new files for as-of dates >= 2026-10-10
    git -C ../ptc-data add targets && git -C ../ptc-data commit -m "add target data" && git -C ../ptc-data push

Only files for the sandbox's step-ahead targets are copied, and existing files are left alone unless --overwrite.
Standard library only.
"""
import argparse
import json
import re
import sys
import urllib.request
from pathlib import Path

SOURCE = "reichlab/flusight-dashboard"
BRANCH = "ptc/data"
TARGET_PREFIXES = ("wk-inc-flu-hosp_", "wk-inc-flu-prop-ed-visits_")
NAME_RE = re.compile(r"^(?P<target>[a-z-]+)_(?P<loc>[0-9A-Z]+)_(?P<as_of>\d{4}-\d{2}-\d{2})\.json$")


def get(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read()


def source_target_files() -> list[str]:
    api = f"https://api.github.com/repos/{SOURCE}/git/trees/{BRANCH}"
    root = json.loads(get(api))
    targets_sha = next(t["sha"] for t in root["tree"] if t["path"] == "targets")
    tree = json.loads(get(f"https://api.github.com/repos/{SOURCE}/git/trees/{targets_sha}"))
    if tree.get("truncated"):
        sys.exit("GitHub tree listing truncated; cannot list all source files")
    return [t["path"] for t in tree["tree"]]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ptc_data_dir", help="checkout of this repo's ptc/data branch")
    parser.add_argument("--since", default="2026-10-10", help="first as-of date to copy (default: 2026-10-10)")
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()

    out_dir = Path(args.ptc_data_dir) / "targets"
    if not (Path(args.ptc_data_dir) / "predtimechart-options.json").exists() or not out_dir.is_dir():
        sys.exit(f"{args.ptc_data_dir} does not look like a ptc/data checkout")

    n_new = 0
    for name in source_target_files():
        m = NAME_RE.match(name)
        if not m or not name.startswith(TARGET_PREFIXES) or m["as_of"] < args.since:
            continue
        out = out_dir / name
        if out.exists() and not args.overwrite:
            continue
        data = get(f"https://raw.githubusercontent.com/{SOURCE}/{BRANCH}/targets/{name}")
        json.loads(data)  # must be valid JSON
        out.write_bytes(data)
        n_new += 1
    print(f"{n_new} target files written to {out_dir}")


if __name__ == "__main__":
    main()
