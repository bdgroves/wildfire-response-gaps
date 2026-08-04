#!/usr/bin/env python3
"""fetch_rfpa.py — build approximate RFPA coverage from county boundaries.

Uses a county-based approximation because the authoritative RFPA GeoJSON
isn't stably available via a public API. RFPAs are chartered to cover a
known set of ~15 eastern/central Oregon counties (ODF, 2024). For
distance-to-station analysis, county resolution is adequate.

Reads:  data/us_counties.geojson  (already in the repo)
        data/us_states.geojson    (to resolve Oregon's STATEFP)
Writes: data/rfpa_boundaries.geojson

The pipeline treats this file the same whether it comes from a live ArcGIS
service or this fallback — the layer just needs `name` and `acres` columns.
"""
from __future__ import annotations

import sys
from pathlib import Path

import geopandas as gpd

from common import COUNTIES_JSON, RFPA_JSON, STATES_JSON, log


# ODF's 28 RFPAs cover ~17.5M acres across these 15 Oregon counties.
# Source: ODF Board of Forestry materials (June 2024) + RFPA Summit rosters.
# Some counties are only partially covered; some RFPAs cross county lines.
# This mapping is a simplification for visual context, not a legal boundary.
RFPA_COUNTIES = {
    "Baker":     "Pine Creek / Keating / Lookout Mountain",
    "Crook":     "Post-Paulina",
    "Gilliam":   "Central Oregon RFPAs",
    "Grant":     "Long Creek / Monument",
    "Harney":    "Frenchglen / Silvies / Crane / Diamond",
    "Jefferson": "Ashwood-Antelope",
    "Klamath":   "Klamath Basin (partial)",
    "Lake":      "Warner Valley / Silver Creek / Paisley",
    "Malheur":   "Ironside / Vale / Jordan Valley",
    "Morrow":    "Butter Creek",
    "Sherman":   "Sherman County",
    "Umatilla":  "Ukiah / WC Ranches / Sixshooter",
    "Union":     "North Powder",
    "Wasco":     "Bakeoven-Shaniko / Lone Pine",
    "Wheeler":   "Wheeler County",
}


def main() -> int:
    if not COUNTIES_JSON.exists() or not STATES_JSON.exists():
        raise SystemExit(
            "Census boundaries not present yet. Run build_ytd_map.py first "
            "(or wait for the daily CI run) to populate data/us_*.geojson."
        )

    log(f"Reading {COUNTIES_JSON}", prefix="rfpa")
    counties = gpd.read_file(COUNTIES_JSON)
    states = gpd.read_file(STATES_JSON)

    oregon_fp = states.loc[states["NAME"] == "Oregon", "STATEFP"].iloc[0]
    log(f"Oregon STATEFP: {oregon_fp}", prefix="rfpa")

    or_counties = counties[counties["STATEFP"] == oregon_fp].copy()
    log(f"Oregon counties in cartographic file: {len(or_counties)}", prefix="rfpa")

    matched = or_counties[or_counties["NAME"].isin(RFPA_COUNTIES.keys())].copy()
    missing = set(RFPA_COUNTIES) - set(matched["NAME"])
    if missing:
        log(f"WARNING: counties not found in Census file: {sorted(missing)}",
            prefix="rfpa")
    log(f"Matched RFPA counties: {len(matched)}", prefix="rfpa")

    # Human-friendly label + approximate area
    matched["name"] = matched["NAME"].map(
        lambda n: f"{n} County RFPA area ({RFPA_COUNTIES.get(n, '')})".rstrip(" ()")
    )
    # Area in Albers Equal Area (EPSG:5070), m^2 -> acres
    proj = matched.to_crs(5070)
    matched["acres"] = (proj.area * 0.000247105).round(0)

    out = matched[["name", "acres", "NAME", "geometry"]].to_crs(4326).reset_index(drop=True)

    RFPA_JSON.parent.mkdir(parents=True, exist_ok=True)
    tmp = RFPA_JSON.with_suffix(RFPA_JSON.suffix + ".tmp")
    out.to_file(tmp, driver="GeoJSON")
    tmp.replace(RFPA_JSON)
    total_ac = int(out["acres"].sum())
    log(f"Wrote {RFPA_JSON} — {len(out)} polygons, {total_ac:,} acres total",
        prefix="rfpa")
    return 0


if __name__ == "__main__":
    sys.exit(main())
