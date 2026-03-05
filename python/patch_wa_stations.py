#!/usr/bin/env python3
"""
patch_wa_stations.py
Fetches Washington fire stations from OSM and merges them into
the existing output/stations.json cache.

Run when Washington failed due to OSM rate limiting:
  python python/patch_wa_stations.py
"""
import json, os, time, requests

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
CACHE = "output/stations.json"
BBOX = (45.5, -124.7, 49.0, -116.9)  # Washington

def fetch_wa():
    s, w, n, e = BBOX
    query = f"""
[out:json][timeout:120];
(
  node["amenity"="fire_station"]({s},{w},{n},{e});
  way["amenity"="fire_station"]({s},{w},{n},{e});
  relation["amenity"="fire_station"]({s},{w},{n},{e});
);
out center;
"""
    print("Querying OSM for Washington fire stations...")
    for attempt in range(3):
        try:
            resp = requests.post(OVERPASS_URL, data={"data": query}, timeout=130)
            resp.raise_for_status()
            data = resp.json()
            stations = []
            for el in data.get("elements", []):
                name = el.get("tags", {}).get("name")
                if not name:
                    continue
                if el["type"] == "node":
                    lat, lon = el["lat"], el["lon"]
                else:
                    center = el.get("center", {})
                    if not center:
                        continue
                    lat, lon = center["lat"], center["lon"]
                stations.append({"name": name, "lat": lat, "lon": lon, "state": "Washington"})
            print(f"  Got {len(stations)} Washington stations")
            return stations
        except Exception as e:
            print(f"  Attempt {attempt+1} failed: {e}")
            if attempt < 2:
                print("  Waiting 60 seconds...")
                time.sleep(60)
    return []

def main():
    wa_stations = fetch_wa()
    if not wa_stations:
        print("Failed to get Washington stations. Try again later.")
        return

    existing = []
    if os.path.exists(CACHE):
        with open(CACHE) as fh:
            existing = json.load(fh)
        # Remove any existing WA entries
        existing = [s for s in existing if s.get("state") != "Washington"]
        print(f"  Kept {len(existing)} non-WA stations from cache")

    merged = existing + wa_stations

    # Deduplicate
    seen, deduped = set(), []
    for s in merged:
        key = (s["name"], round(s["lat"], 3), round(s["lon"], 3))
        if key not in seen:
            seen.add(key)
            deduped.append(s)

    with open(CACHE, "w") as fh:
        json.dump(deduped, fh, indent=2)

    print(f"  Cache updated: {len(deduped)} total stations")
    print(f"  Washington: {len(wa_stations)}")
    print(f"  Saved to {CACHE}")

if __name__ == "__main__":
    main()
