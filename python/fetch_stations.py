#!/usr/bin/env python3
"""fetch_stations.py — pull fire station locations from OpenStreetMap.

Writes:
  output/stations.json    list of {lon, lat, name, state} dicts

OSM data changes slowly and Overpass is rate-limited, so this doesn't need to
run daily. Once a month via .github/workflows/refresh_stations.yml is plenty.

Design:
  * One Overpass query per state (parallel would be nicer but Overpass frowns
    on it — sequential + small sleep is polite).
  * Falls through a list of mirror endpoints if the primary is down.
  * Preserves the previous cache on complete failure — never overwrites with
    an empty file.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import requests

from common import (
    OVERPASS_ENDPOINTS,
    STATE_BBOX,
    STATIONS_PATH,
    log,
)

OVERPASS_TEMPLATE = """
[out:json][timeout:120];
(
  node["amenity"="fire_station"]({south},{west},{north},{east});
  way["amenity"="fire_station"]({south},{west},{north},{east});
  relation["amenity"="fire_station"]({south},{west},{north},{east});
);
out center tags;
""".strip()


def overpass_query(query: str, *, max_tries: int = 4) -> dict:
    """Try each mirror in order; retry each with exponential backoff on 429/5xx."""
    last_err: Exception | None = None
    for endpoint in OVERPASS_ENDPOINTS:
        for attempt in range(1, max_tries + 1):
            try:
                r = requests.post(endpoint, data={"data": query}, timeout=180)
                if r.status_code == 200:
                    return r.json()
                if r.status_code in (429, 502, 503, 504):
                    wait = 5 * (2 ** (attempt - 1))
                    log(f"{endpoint} → HTTP {r.status_code}, sleeping {wait}s",
                        prefix="stations")
                    time.sleep(wait)
                    continue
                r.raise_for_status()
            except (requests.RequestException, ValueError) as exc:
                last_err = exc
                log(f"{endpoint} error ({exc}); trying next", prefix="stations")
                time.sleep(2)
                break   # move to next endpoint
    raise RuntimeError(f"All Overpass endpoints failed. Last error: {last_err}")


def extract_stations(payload: dict, state_name: str) -> list[dict]:
    rows = []
    for el in payload.get("elements", []):
        if el["type"] == "node":
            lon, lat = el.get("lon"), el.get("lat")
        else:
            center = el.get("center", {})
            lon, lat = center.get("lon"), center.get("lat")
        if lon is None or lat is None:
            continue
        name = el.get("tags", {}).get("name")
        if not name:
            continue    # unnamed stations don't get shown or ranked
        rows.append({
            "lon":   round(lon, 5),
            "lat":   round(lat, 5),
            "name":  name,
            "state": state_name,
            "osm_id": f"{el['type'][0]}{el['id']}",
        })
    return rows


def fetch_all_states() -> list[dict]:
    all_stations: list[dict] = []
    for state, (west, south, east, north) in STATE_BBOX.items():
        log(f"Fetching {state}...", prefix="stations")
        query = OVERPASS_TEMPLATE.format(south=south, west=west, north=north, east=east)
        payload = overpass_query(query)
        rows = extract_stations(payload, state)
        log(f"  → {len(rows)} named stations in {state}", prefix="stations")
        all_stations.extend(rows)
        time.sleep(3)   # be polite to Overpass
    return all_stations


def dedupe_by_location(rows: list[dict]) -> list[dict]:
    """OSM sometimes has near-duplicate entries; collapse anything at the same
    lon/lat rounded to 5 decimals (~1 m)."""
    seen: dict[tuple[float, float], dict] = {}
    for r in rows:
        key = (r["lon"], r["lat"])
        # If both entries have the same coords, prefer the one with a longer
        # name (usually the more complete OSM record).
        prev = seen.get(key)
        if prev is None or len(r.get("name", "")) > len(prev.get("name", "")):
            seen[key] = r
    return list(seen.values())


def write_atomic(rows: list[dict], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(rows, indent=None))
    tmp.replace(path)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=STATIONS_PATH,
                    help=f"output json (default: {STATIONS_PATH})")
    args = ap.parse_args()

    try:
        rows = fetch_all_states()
    except Exception as exc:
        log(f"FAILED: {exc}", prefix="stations")
        if args.out.exists():
            log(f"Preserving existing {args.out}", prefix="stations")
            return 1
        raise

    rows = dedupe_by_location(rows)
    log(f"After dedupe: {len(rows)} stations", prefix="stations")
    write_atomic(rows, args.out)
    log(f"Wrote {args.out}", prefix="stations")
    return 0


if __name__ == "__main__":
    sys.exit(main())
