#!/usr/bin/env python3
"""fetch_fires.py — pull YTD wildfire perimeters from NIFC WFIGS.

Writes:
  output/fires.geojson    all CA/OR/WA perimeters year-to-date, raw NIFC schema

Design:
  * Paginated at 1000 features/page with a 1.5s pause between pages.
  * Retries on 429 (returned as HTTP 200 with an error body — nice).
  * geometryPrecision=5 to keep per-request quota cost reasonable.
  * Only writes fires.geojson if the fetch succeeds — a partial failure leaves
    the previous day's file in place so the dashboard doesn't go blank.
"""
from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

from common import (
    FIRES_PATH,
    NIFC_STATE_CODES,
    OUTPUT_DIR,
    log,
    nifc_fetch_all,
)


def build_where_clause() -> str:
    states = ",".join(f"'{c}'" for c in NIFC_STATE_CODES)
    return f"attr_POOState IN ({states})"


def fetch() -> dict:
    where = build_where_clause()
    log(f"Fetching WFIGS YTD perimeters where {where}", prefix="fires")
    features = list(nifc_fetch_all(where))
    log(f"Total features: {len(features)}", prefix="fires")
    return {"type": "FeatureCollection", "features": features}


def write_atomic(payload: dict, path: Path) -> None:
    """Write to a temp file then rename — an interrupted run never leaves a
    truncated GeoJSON in the repo."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", dir=path.parent, delete=False, suffix=".tmp", encoding="utf-8"
    ) as f:
        json.dump(payload, f)
        tmp = Path(f.name)
    tmp.replace(path)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=FIRES_PATH,
                    help=f"output geojson (default: {FIRES_PATH})")
    args = ap.parse_args()

    payload = fetch()
    write_atomic(payload, args.out)
    log(f"Wrote {args.out} ({len(payload['features'])} features, "
        f"{args.out.stat().st_size / 1024:.0f} KB)", prefix="fires")
    return 0


if __name__ == "__main__":
    sys.exit(main())
