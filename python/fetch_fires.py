#!/usr/bin/env python3
"""
fetch_fires.py
Fetches YTD wildfire perimeters from NIFC WFIGS API and writes
output/fires.geojson for the Leaflet web map (index.html).

Station data: queries OpenStreetMap Overpass API for all fire stations
in CA, OR, WA — mirrors R/09_west_coast_stations.R exactly.
Stations cached to output/stations.json to avoid re-querying OSM every run.

Run locally:
  python python/fetch_fires.py

  Force fresh OSM query (e.g. start of season):
  python python/fetch_fires.py --refresh-stations

GitHub Actions runs this every morning and commits the result.
"""

import json
import math
import os
import sys
import time
from datetime import datetime, timezone

import requests

# =============================================================================
# WFIGS API — exact same endpoint as R/10_west_coast_perimeters.R
# =============================================================================
WFIGS_URL = (
    "https://services3.arcgis.com/T4QMspbfLg3qTGWY/ArcGIS/rest/services/"
    "WFIGS_Interagency_Perimeters_YearToDate/FeatureServer/0/query"
)

# State filter — mirrors R pipeline exactly
WC_STATE_FILTER = "attr_POOState IN ('US-CA','US-OR','US-WA')"

# =============================================================================
# OSM OVERPASS — mirrors R/09_west_coast_stations.R
# =============================================================================
OVERPASS_URL = "https://overpass-api.de/api/interpreter"

# Bounding boxes per state [south, west, north, east]
# mirrors R's st_bbox(westcoast_states %>% filter(NAME == state_name))
STATE_BBOXES = {
    "California":  (32.5, -124.4, 42.0, -114.1),
    "Oregon":      (41.9, -124.6, 46.3, -116.5),
    "Washington":  (45.5, -124.7, 49.0, -116.9),
}

# Exclusions from R script manual review
STATIONS_EXCLUDE = {
    "Wallowa Lake Fire Station",
    "Northeast Washington Interagency Communications Center",
}

STATIONS_CACHE = "output/stations.json"

STATE_MAP = {
    "US-OR": "Oregon",  "US_OR": "Oregon",  "OR": "Oregon",
    "US-CA": "California", "US_CA": "California", "CA": "California",
    "US-WA": "Washington", "US_WA": "Washington", "WA": "Washington",
}


# =============================================================================
# GEOMETRY HELPERS
# =============================================================================
def haversine_km(lat1, lon1, lat2, lon2):
    R = 6371
    d_lat = math.radians(lat2 - lat1)
    d_lon = math.radians(lon2 - lon1)
    a = (math.sin(d_lat / 2) ** 2
         + math.cos(math.radians(lat1))
         * math.cos(math.radians(lat2))
         * math.sin(d_lon / 2) ** 2)
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def nearest_station(lat, lon, stations):
    best, best_dist = None, float("inf")
    for s in stations:
        d = haversine_km(lat, lon, s["lat"], s["lon"])
        if d < best_dist:
            best_dist = d
            best = s
    return best, best_dist


def centroid(geometry):
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
# OSM STATION QUERY — mirrors R/09_west_coast_stations.R
# Queries each state separately to avoid OSM timeouts (same as R)
# Caches result to output/stations.json
# =============================================================================
def query_osm_stations_for_state(state_name, bbox, retries=2):
    """
    Query Overpass for fire_station amenities in one state bounding box.
    mirrors R fetch_stations_for_state() including retry logic.
    bbox = (south, west, north, east)
    """
    s, w, n, e = bbox
    query = f"""
[out:json][timeout:120];
(
  node["amenity"="fire_station"]({s},{w},{n},{e});
  way["amenity"="fire_station"]({s},{w},{n},{e});
  relation["amenity"="fire_station"]({s},{w},{n},{e});
);
out center;
"""
    for attempt in range(retries):
        try:
            resp = requests.post(OVERPASS_URL, data={"data": query}, timeout=130)
            resp.raise_for_status()
            data = resp.json()
            stations = []
            for el in data.get("elements", []):
                name = el.get("tags", {}).get("name")
                if not name:
                    continue
                if name in STATIONS_EXCLUDE:
                    continue
                # Points use lat/lon directly; ways/relations use center
                if el["type"] == "node":
                    lat, lon = el["lat"], el["lon"]
                else:
                    center = el.get("center", {})
                    if not center:
                        continue
                    lat, lon = center["lat"], center["lon"]
                stations.append({"name": name, "lat": lat, "lon": lon,
                                  "state": state_name})
            print(f"    {state_name}: {len(stations)} stations")
            return stations
        except Exception as exc:
            print(f"    {state_name} attempt {attempt+1} failed: {exc}",
                  file=sys.stderr)
            if attempt < retries - 1:
                print("    Retrying in 30 seconds...")
                time.sleep(30)
    print(f"    {state_name}: all attempts failed, returning empty",
          file=sys.stderr)
    return []


def load_or_fetch_stations(force_refresh=False):
    """
    Load stations from cache or query OSM fresh.
    mirrors R cache logic: query only runs once unless cache missing.
    """
    os.makedirs("output", exist_ok=True)

    if not force_refresh and os.path.exists(STATIONS_CACHE):
        with open(STATIONS_CACHE) as fh:
            stations = json.load(fh)
        print(f"  Stations loaded from cache: {len(stations)} "
              f"({STATIONS_CACHE})")
        return stations

    print("  Querying OSM for fire stations across CA, OR, WA...")
    print("  (This runs once and caches — mirrors R/09_west_coast_stations.R)")
    all_stations = []
    for state_name, bbox in STATE_BBOXES.items():
        state_stations = query_osm_stations_for_state(state_name, bbox)
        all_stations.extend(state_stations)
        time.sleep(2)  # polite delay between state queries

    # Deduplicate by name + approximate location
    seen = set()
    deduped = []
    for s in all_stations:
        key = (s["name"], round(s["lat"], 3), round(s["lon"], 3))
        if key not in seen:
            seen.add(key)
            deduped.append(s)

    print(f"  Total stations after dedup: {len(deduped)}")
    print(f"  Excluded: {', '.join(STATIONS_EXCLUDE)}")

    with open(STATIONS_CACHE, "w") as fh:
        json.dump(deduped, fh, indent=2)
    print(f"  Stations cached to {STATIONS_CACHE}")

    return deduped


# =============================================================================
# WFIGS FETCH
# =============================================================================
def fetch_wfigs(url, params, label):
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
        "where": WC_STATE_FILTER,
        "outFields": (
            "attr_IncidentName,poly_GISAcres,attr_IncidentSize,"
            "attr_PercentContained,attr_POOState,"
            "poly_DateCurrent,poly_CreateDate,poly_FeatureCategory"
        ),
        "outSR": "4326",
        "f": "geojson",
        "resultRecordCount": "1000",
    }
    return fetch_wfigs(WFIGS_URL, params, "WFIGS YearToDate perimeters")


# =============================================================================
# PROCESS FEATURES
# =============================================================================
def process_features(raw_features, stations):
    out = []

    for f in raw_features:
        props = f.get("properties") or {}
        geom  = f.get("geometry")
        if not geom:
            continue

        c_lat, c_lon = centroid(geom)
        if c_lat is None:
            continue

        # Acreage: coalesce(attr_IncidentSize, poly_GISAcres, 0)
        inc_size  = props.get("attr_IncidentSize") or 0
        gis_acres = props.get("poly_GISAcres") or 0
        acres = inc_size if inc_size > 0 else (gis_acres if gis_acres > 0 else 0)

        # Active: is.na(attr_PercentContained) | attr_PercentContained < 100
        pct = props.get("attr_PercentContained")
        is_active = (pct is None or pct < 100)

        # State
        state_code = props.get("attr_POOState") or ""
        state = STATE_MAP.get(state_code, state_code or "Other")

        # Distance to nearest OSM station
        stn, dist_km = nearest_station(c_lat, c_lon, stations)

        # Date
        date_current = props.get("poly_DateCurrent") or props.get("poly_CreateDate")
        if date_current:
            try:
                dt = datetime.fromtimestamp(date_current / 1000, tz=timezone.utc)
                date_str = dt.strftime("%b %d, %Y")
            except Exception:
                date_str = str(date_current)
        else:
            date_str = ""

        enriched_props = {
            "attr_IncidentName":     props.get("attr_IncidentName") or "Unknown Fire",
            "attr_PercentContained": pct,
            "acres":                 round(acres, 1),
            "is_active":             is_active,
            "status":                "Active" if is_active else "Contained",
            "state":                 state,
            "dist_nearest_km":       round(dist_km, 2),
            "nearest_station_name":  stn["name"] if stn else None,
            "date_current":          date_str,
            "feature_category":      props.get("poly_FeatureCategory") or "",
        }

        out.append({
            "type":       "Feature",
            "geometry":   geom,
            "properties": enriched_props,
        })

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

    os.makedirs("output", exist_ok=True)
    with open("output/ytd_fires_summary.txt", "w") as fh:
        fh.write(
            f"{n_total} fires, {n_active} active, "
            f"{total_acres:,.0f} ac, median {median_dist:.1f} km to station"
        )

    # Print each fire with its nearest station
    print(f"\n  Fires:")
    for f in features:
        p = f["properties"]
        print(f"    {p['attr_IncidentName']:30s} | "
              f"{p['acres']:>8.1f} ac | "
              f"{p['state']:12s} | "
              f"{p['dist_nearest_km']:6.1f} km to {p['nearest_station_name']}")


# =============================================================================
# MAIN
# =============================================================================
def main():
    force_refresh = "--refresh-stations" in sys.argv

    print(f"\n=== fetch_fires.py  "
          f"{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} ===")

    os.makedirs("output", exist_ok=True)

    # Step 1: Load or fetch OSM stations
    print("\n--- Stations ---")
    stations = load_or_fetch_stations(force_refresh=force_refresh)
    if not stations:
        print("  WARNING: No stations loaded — distances will be wrong",
              file=sys.stderr)

    # Step 2: Fetch WFIGS perimeters
    print("\n--- Fire Perimeters ---")
    raw = fetch_perimeters()

    if not raw:
        print("\n  No features returned — off-season or API issue.")
        print("  Writing empty fires.geojson so map loads cleanly.")
        geojson = {"type": "FeatureCollection", "features": []}
    else:
        print("\n  Processing features...")
        features = process_features(raw, stations)
        print(f"  Processed {len(features)} valid features")
        print_summary(features)
        geojson = {"type": "FeatureCollection", "features": features}

    # Step 3: Write GeoJSON
    out_path = "output/fires.geojson"
    with open(out_path, "w") as fh:
        json.dump(geojson, fh, separators=(",", ":"))

    size_kb = os.path.getsize(out_path) / 1024
    print(f"\n  Written: {out_path} ({size_kb:.1f} KB)")
    print("=== Done ===\n")


if __name__ == "__main__":
    main()
