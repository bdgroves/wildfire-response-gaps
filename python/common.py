"""Shared configuration and utilities for the wildfire-response-gaps pipeline.

Everything that needs to be consistent between fetch_fires.py,
fetch_stations.py, and build_ytd_map.py lives here so we don't drift.
"""

from __future__ import annotations

import re
import sys
import time
from pathlib import Path
from typing import Any, Iterator

import requests

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

REPO_ROOT      = Path(__file__).resolve().parent.parent
DATA_DIR       = REPO_ROOT / "data"
OUTPUT_DIR     = REPO_ROOT / "output"
FIGURES_DIR    = OUTPUT_DIR / "figures"

FIRES_PATH     = OUTPUT_DIR / "fires.geojson"
STATIONS_PATH  = OUTPUT_DIR / "stations.json"
SUMMARY_JSON   = OUTPUT_DIR / "ytd_summary.json"
SUMMARY_TXT    = OUTPUT_DIR / "ytd_summary.txt"
PNG_PATH       = FIGURES_DIR / "ytd_natgeo.png"

STATES_JSON    = DATA_DIR / "us_states.geojson"
COUNTIES_JSON  = DATA_DIR / "us_counties.geojson"

# ---------------------------------------------------------------------------
# Geographic scope
# ---------------------------------------------------------------------------

# Order matters for stable output — CA first, then OR, then WA
STATE_ORDER      = ["California", "Oregon", "Washington"]
NIFC_STATE_CODES = ["US-CA", "US-OR", "US-WA"]
STATE_CODE_MAP   = dict(zip(NIFC_STATE_CODES, STATE_ORDER))

# Bounding box for OSM Overpass fetches, per state (lon_w, lat_s, lon_e, lat_n)
STATE_BBOX = {
    "California": (-124.5, 32.5, -114.1, 42.0),
    "Oregon":     (-124.6, 41.9, -116.5, 46.3),
    "Washington": (-124.7, 45.5, -116.9, 49.0),
}

WC_CRS = 5070   # Albers Equal Area CONUS — for accurate distance + display

# ---------------------------------------------------------------------------
# NIFC endpoint
# ---------------------------------------------------------------------------

NIFC_URL = (
    "https://services3.arcgis.com/T4QMspbfLg3qTGWY/ArcGIS/rest/services/"
    "WFIGS_Interagency_Perimeters_YearToDate/FeatureServer/0/query"
)

NIFC_FIELDS = [
    "attr_IncidentName", "attr_POOState", "attr_POOCounty",
    "attr_FireDiscoveryDateTime", "attr_IncidentSize",
    "attr_PercentContained", "poly_GISAcres", "poly_DateCurrent",
]

# ---------------------------------------------------------------------------
# Census cartographic (small — a few MB total, cache once)
# ---------------------------------------------------------------------------

CENSUS_STATES_URL   = "https://www2.census.gov/geo/tiger/GENZ2022/shp/cb_2022_us_state_20m.zip"
CENSUS_COUNTIES_URL = "https://www2.census.gov/geo/tiger/GENZ2022/shp/cb_2022_us_county_20m.zip"

# ---------------------------------------------------------------------------
# OSM Overpass
# ---------------------------------------------------------------------------

OVERPASS_ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.osm.ch/api/interpreter",
]

# ---------------------------------------------------------------------------
# NatGeo palette (also referenced by the dashboard CSS via docs/notes)
# ---------------------------------------------------------------------------

NATGEO_YELLOW    = "#FFCE00"
NATGEO_YELLOW_DK = "#E8B800"
PARCHMENT        = "#F5F0E1"
PARCHMENT_DARK   = "#EDE5D0"
INK_BLACK        = "#1A1A1A"
INK_BROWN        = "#3D2B1F"
INK_GRAY         = "#5C5C5C"
FIRE_ACTIVE      = "#8B1A1A"
FIRE_ACTIVE_EDGE = "#5C1A0A"
FIRE_CONTAINED   = "#5B7E5E"
FIRE_CONTAINED_E = "#3D5C3F"

# ---------------------------------------------------------------------------
# Fire attribute schema — resilient to different producers
# ---------------------------------------------------------------------------

FIELD_ALIASES: dict[str, list[str]] = {
    "incident_name": ["attr_IncidentName", "IncidentName", "incident_name", "name"],
    "state":         ["attr_POOState", "POOState", "state_code", "state"],
    "county":        ["attr_POOCounty", "POOCounty", "county"],
    "size":          ["attr_IncidentSize", "IncidentSize", "incident_size", "acres"],
    "contained":     ["attr_PercentContained", "PercentContained", "percent_contained"],
    "gis_acres":     ["poly_GISAcres", "GISAcres", "gis_acres"],
    "discovery":     ["attr_FireDiscoveryDateTime", "FireDiscoveryDateTime", "discovery"],
}


def resolve_field(columns, key: str) -> str | None:
    """First matching alias present in `columns`, or None."""
    for cand in FIELD_ALIASES[key]:
        if cand in columns:
            return cand
    return None


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def log(msg: str, *, prefix: str = "wildfire") -> None:
    print(f"[{prefix}] {msg}", flush=True, file=sys.stderr)


# ---------------------------------------------------------------------------
# NIFC client — the ONE place we know how to talk to the WFIGS service.
# Handles 429s (which arrive as HTTP 200 with an error body), paging,
# and exponential backoff.
# ---------------------------------------------------------------------------

class NIFCRateLimit(Exception):
    pass


def _sleep_from_hint(text: str, attempt: int) -> int:
    """Extract 'Retry after N' from a NIFC error body, add exponential jitter."""
    m = re.search(r"Retry after (\d+)", text)
    base = int(m.group(1)) if m else 10
    return max(base, 5) + 2 ** (attempt - 1)


def nifc_fetch_page(
    *,
    where: str,
    offset: int,
    page_size: int = 1000,
    max_tries: int = 6,
    timeout: int = 90,
) -> dict[str, Any]:
    """Fetch one page of WFIGS features. Returns the parsed GeoJSON dict."""
    params = {
        "where":             where,
        "outFields":         ",".join(NIFC_FIELDS),
        "f":                 "geojson",
        "outSR":             4326,
        "geometryPrecision": 5,
        "returnGeometry":    "true",
        "resultOffset":      offset,
        "resultRecordCount": page_size,
    }
    for attempt in range(1, max_tries + 1):
        r = requests.get(NIFC_URL, params=params, timeout=timeout)
        txt = r.text
        low = txt.lower()
        is_rate_limited = (
            '"code":429' in txt
            or "quota exceeded" in low
            or "too many requests" in low
        )
        if is_rate_limited:
            wait = _sleep_from_hint(txt, attempt)
            log(f"NIFC rate-limited — sleeping {wait}s (try {attempt}/{max_tries})",
                prefix="nifc")
            time.sleep(wait)
            continue
        if r.status_code != 200 or '"error"' in txt:
            raise RuntimeError(f"NIFC error (HTTP {r.status_code}): {txt[:400]}")
        return r.json()
    raise NIFCRateLimit(f"NIFC quota still hot after {max_tries} attempts")


def nifc_fetch_all(where: str, *, page_size: int = 1000, page_sleep: float = 1.5) -> Iterator[dict]:
    """Iterate every WFIGS feature matching `where`, one at a time."""
    offset = 0
    while True:
        page = nifc_fetch_page(where=where, offset=offset, page_size=page_size)
        feats = page.get("features", [])
        if not feats:
            return
        for f in feats:
            yield f
        log(f"page @offset {offset}: {len(feats)} features", prefix="nifc")
        if len(feats) < page_size:
            return
        offset += page_size
        time.sleep(page_sleep)
