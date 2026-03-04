#!/usr/bin/env python3
"""
fetch_fires.py
Fetches YTD wildfire perimeters from NIFC WFIGS API and writes
output/fires.geojson for the Leaflet web map (index.html).

Mirrors the R pipeline field logic:
  acres      = coalesce(IncidentSize, GISAcres, 0)
  is_active  = PercentContained is None or PercentContained < 100
  state      = mapped from POOState (US-OR, US-CA, US-WA)
  dist_nearest_km = haversine to nearest known fire station

Run locally:
  python python/fetch_fires.py

GitHub Actions runs this every morning and commits the result.
"""

import json
import math
import os
import sys
from datetime import datetime, timezone

import requests

# =============================================================================
# WFIGS API — same endpoints your R pipeline uses
# =============================================================================
WFIGS_PERIMETERS = (
    "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/"
    "WFIGS_Interagency_Perimeters_YTD/FeatureServer/0/query"
)

WFIGS_INCIDENTS = (
    "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/"
    "WFIGS_Interagency_Perimeters_YTD/FeatureServer/0/query"
)

# West coast bounding box
WC_BBOX = "-124.8,32.5,-114.0,49.0"

# =============================================================================
# FIRE STATIONS — mirrors your R all_stations_wc_clean
# =============================================================================
STATIONS = [
    {"name": "Frenchglen Fire Guard Station", "lat": 42.814, "lon": -118.934},
    {"name": "Burns Interagency Fire Zone",   "lat": 43.587, "lon": -119.054},
    {"name": "Lakeview BLM District",         "lat": 42.189, "lon": -120.346},
    {"name": "Vale BLM District",             "lat": 43.980, "lon": -117.238},
    {"name": "Hines Fire Station",            "lat": 43.561, "lon": -119.098},
    {"name": "Lakeview Ranger District",      "lat": 42.197, "lon": -120.350},
    {"name": "Medford Air Tanker Base",       "lat": 42.374, "lon": -122.874},
    {"name": "Klamath Falls BLM",            "lat": 42.225, "lon": -121.781},
    {"name": "Redding Air Attack Base",       "lat": 40.509, "lon": -122.293},
    {"name": "Susanville Cal Fire",           "lat": 40.416, "lon": -120.652},
    {"name": "Fresno Cal Fire",               "lat": 36.737, "lon": -119.771},
    {"name": "Wenatchee Fire Station",        "lat": 47.423, "lon": -120.310},
    {"name": "Yakima Fire Station",           "lat": 46.602, "lon": -120.506},
    {"name": "Okanogan Fire Station",         "lat": 48.362, "lon": -119.573},
    {"name": "Boise NIFC",                   "lat": 43.564, "lon": -116.196},
]

STATE_MAP = {
    "US-OR": "Oregon",  "US_OR": "Oregon",  "OR": "Oregon",
    "US-CA": "California", "US_CA": "California", "CA": "California",
    "US-WA": "Washington", "US_WA": "Washington", "WA": "Washington",
}


# =============================================================================
# GEOMETRY HELPERS
# =============================================================================
def haversine_km(lat1, lon1, lat2, lon2):
    """Straight-line distance in km — mirrors R dist_nearest_km logic."""
    R = 6371
    d_lat = math.radians(lat2 - lat1)
    d_lon = math.radians(lon2 - lon1)
    a = (math.sin(d_lat / 2) ** 2
         + math.cos(math.radians(lat1))
         * math.cos(math.radians(lat2))
         * math.sin(d_lon / 2) ** 2)
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def nearest_station(lat, lon):
    """Return (station dict, distance_km) for the closest known station."""
    best, best_dist = None, float("inf")
    for s in STATIONS:
        d = haversine_km(lat, lon, s["lat"], s["lon"])
        if d < best_dist:
            best_dist = d
            best = s
    return best, best_dist


def centroid(geometry):
    """Approximate centroid from a GeoJSON geometry (Polygon or MultiPolygon)."""
    coords = []

    def collect(arr):
        if arr and isinstance(arr[0], (int, float)):
            coords.append(arr)
        else:
            for item in arr:
                collect(item)

    collect(geometry.get("coordinates", []))
    if not coords:
        return None, None
    lon = sum(c[0] for c in coords) / len(coords)
    lat = sum(c[1] for c in coords) / len(coords)
    return lat, lon


# =============================================================================
# FETCH
# =============================================================================
def fetch_wfigs(url, params, label):
    """GET a WFIGS FeatureServer query, return GeoJSON features list."""
    print(f"  Fetching {label}...")
    try:
        resp = requests.get(url, params=params, timeout=60)
        resp.raise_for_status()
        data = resp.json()
        if "error" in data:
            print(f"  API error: {data['error']}", file=sys.stderr)
            return []
        features = data.get("features", [])
        print(f"  Got {len(features)} features")
        return features
    except Exception as e:
        print(f"  Failed: {e}", file=sys.stderr)
        return []


def fetch_perimeters():
    params = {
        "where": "1=1",
        "outFields": (
            "IncidentName,GISAcres,IncidentSize,PercentContained,"
            "POOState,CreateDate,DateCurrent,FeatureCategory"
        ),
        "geometry": WC_BBOX,
        "geometryType": "esriGeometryEnvelope",
        "inSR": "4326",
        "spatialRel": "esriSpatialRelIntersects",
        "outSR": "4326",
        "f": "geojson",
        "resultRecordCount": "1000",
    }
    return fetch_wfigs(WFIGS_PERIMETERS, params, "WFIGS perimeters")


# =============================================================================
# PROCESS
# =============================================================================
def process_features(raw_features):
    """
    Build enriched GeoJSON features with fields mirroring R pipeline:
      acres, is_active, status, state,
      dist_nearest_km, nearest_station_name,
      attr_IncidentName, attr_PercentContained
    """
    out = []

    for f in raw_features:
        props = f.get("properties") or {}
        geom  = f.get("geometry")
        if not geom:
            continue

        # Centroid for distance calc
        c_lat, c_lon = centroid(geom)
        if c_lat is None:
            continue

        # Acreage: coalesce(IncidentSize, GISAcres, 0) — mirrors R pipeline
        inc_size  = props.get("IncidentSize") or 0
        gis_acres = props.get("GISAcres") or 0
        acres = inc_size if inc_size > 0 else (gis_acres if gis_acres > 0 else 0)

        # Active logic: is.na(PercentContained) | PercentContained < 100
        pct = props.get("PercentContained")
        is_active = (pct is None or pct < 100)

        # State
        state_code = props.get("POOState") or ""
        state = STATE_MAP.get(state_code, state_code or "Other")

        # Distance to nearest station
        stn, dist_km = nearest_station(c_lat, c_lon)

        # Date string
        date_current = props.get("DateCurrent") or props.get("CreateDate")
        if date_current:
            try:
                # WFIGS returns epoch ms
                dt = datetime.fromtimestamp(date_current / 1000, tz=timezone.utc)
                date_str = dt.strftime("%b %d, %Y")
            except Exception:
                date_str = str(date_current)
        else:
            date_str = ""

        enriched_props = {
            # R-pipeline-style fields consumed by index.html
            "attr_IncidentName":      props.get("IncidentName") or "Unknown Fire",
            "attr_PercentContained":  pct,
            "acres":                  round(acres, 1),
            "is_active":              is_active,
            "status":                 "Active" if is_active else "Contained",
            "state":                  state,
            "dist_nearest_km":        round(dist_km, 2),
            "nearest_station_name":   stn["name"] if stn else None,
            # Extra context for popups
            "date_current":           date_str,
            "feature_category":       props.get("FeatureCategory") or "",
        }

        out.append({
            "type":       "Feature",
            "geometry":   geom,
            "properties": enriched_props,
        })

    # Sort by acres desc — mirrors R arrange(desc(acres))
    out.sort(key=lambda x: x["properties"]["acres"], reverse=True)
    return out


# =============================================================================
# SUMMARY
# =============================================================================
def print_summary(features):
    n_total     = len(features)
    n_active    = sum(1 for f in features if f["properties"]["is_active"])
    n_contained = n_total - n_active
    total_acres = sum(f["properties"]["acres"] for f in features)
    dists       = [f["properties"]["dist_nearest_km"] for f in features]
    median_dist = sorted(dists)[len(dists) // 2] if dists else 0
    over_50     = sum(1 for d in dists if d > 50)
    pct_over_50 = round(over_50 / n_total * 100, 1) if n_total else 0

    print(f"\n  YTD Summary:")
    print(f"    Total fires:    {n_total}")
    print(f"    Active:         {n_active}")
    print(f"    Contained:      {n_contained}")
    print(f"    Total acres:    {total_acres:,.0f}")
    print(f"    Median dist:    {median_dist:.1f} km")
    print(f"    Fires >50 km:   {over_50} ({pct_over_50}%)")

    # Write ytd_summary.txt for GitHub Actions commit message
    summary_path = "output/ytd_fires_summary.txt"
    os.makedirs("output", exist_ok=True)
    with open(summary_path, "w") as fh:
        fh.write(
            f"{n_total} fires, {n_active} active, "
            f"{total_acres:,.0f} ac, median {median_dist:.1f} km to station"
        )
    print(f"  Summary written to {summary_path}")


# =============================================================================
# MAIN
# =============================================================================
def main():
    print(f"\n=== fetch_fires.py  {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} ===")

    os.makedirs("output", exist_ok=True)

    # Fetch
    raw = fetch_perimeters()

    if not raw:
        print("\n  No features returned — off-season or API issue.")
        print("  Writing empty fires.geojson so map loads cleanly.")
        geojson = {"type": "FeatureCollection", "features": []}
    else:
        # Process
        print("\n  Processing features...")
        features = process_features(raw)
        print(f"  Processed {len(features)} valid features")
        print_summary(features)
        geojson = {"type": "FeatureCollection", "features": features}

    # Write
    out_path = "output/fires.geojson"
    with open(out_path, "w") as fh:
        json.dump(geojson, fh, separators=(",", ":"))

    size_kb = os.path.getsize(out_path) / 1024
    print(f"\n  Written: {out_path} ({size_kb:.1f} KB)")
    print("=== Done ===\n")


if __name__ == "__main__":
    main()
