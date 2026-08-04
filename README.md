# 🔥 WILDFIRE RESPONSE GAP ANALYSIS

> *"It's already on the ground."*

When a wildfire ignites in eastern Oregon, help isn't minutes away. It's hours. Sometimes it isn't coming at all — not from a mapped fire station. This project measures that gap across every wildfire perimeter on the West Coast, names the stations carrying the load, and tracks the current season live.

## 🌐 [→ OPEN THE LIVE MAP](https://bdgroves.github.io/wildfire-response-gaps/)

Interactive Leaflet map. Fire perimeters updated every morning at 5am Pacific.

---

## Architecture

Everything is Python now. One workflow, one NIFC fetch per morning.

```
wildfire-response-gaps/
├── index.html                        # Leaflet dashboard (reads output/*)
├── requirements.txt
├── python/
│   ├── common.py                     # shared config, palette, NIFC client, aliases
│   ├── fetch_fires.py                # NIFC WFIGS → output/fires.geojson
│   ├── fetch_stations.py             # OSM Overpass → output/stations.json
│   └── build_ytd_map.py              # analysis + NatGeo PNG + summary JSON
├── data/                             # Committed boundary shapes (Census cartographic)
│   ├── us_states.geojson
│   └── us_counties.geojson
├── output/                           # Daily-updated artifacts
│   ├── fires.geojson                 # Fire perimeters (feeds the Leaflet map)
│   ├── stations.json                 # Fire stations (feeds the Leaflet map)
│   ├── ytd_summary.json              # Dashboard stats (headline numbers)
│   ├── ytd_summary.txt               # One-liner for badges
│   └── figures/ytd_natgeo.png        # NatGeo-style static map
└── .github/workflows/
    ├── update_wildfire_map.yml       # Daily 5am Pacific (fires + map)
    └── refresh_stations.yml          # Monthly on the 1st (stations only)
```

## What runs when

| Job | Cadence | Time (Pacific) | What it does |
| --- | --- | --- | --- |
| `refresh_stations.yml` | Monthly, 1st | 4am | Rebuilds `output/stations.json` from OpenStreetMap |
| `update_wildfire_map.yml` | Daily | 5am | Fetches fresh NIFC perimeters, computes distances, renders PNG + JSON |

Both write back to `main` via a `github-actions[bot]` commit. Concurrency guards keep two runs from stacking.

## Rate-limit safety

The previous R workflow crashed daily on NIFC's 57,600-request-units-per-minute quota. The rewrite fixes it with:

- **One fetch per morning**, not two. Both the Leaflet map and the static PNG read from the same `fires.geojson`.
- **`geometryPrecision=5`** on every request — 5 decimal degrees is ~1 m, plenty for a state-scale map, and roughly halves per-request quota cost.
- **Paging + polite sleeps** between pages.
- **Retry-on-429 with exponential backoff** honoring the server's `Retry after N` hint. NIFC returns rate-limit errors as HTTP 200 with an error body, so the retry logic parses the body, not just the status.

## Run locally

```bash
pip install -r requirements.txt

# Refresh perimeters and rebuild everything (5 min or so)
python python/fetch_fires.py
python python/build_ytd_map.py

# Refresh stations from OSM (rarely — only if you're changing the bbox)
python python/fetch_stations.py

# Serve the dashboard
python -m http.server 8000
# → open http://localhost:8000
```

## Data & methods

| Source | Used for |
| --- | --- |
| [NIFC WFIGS API](https://data-nifc.opendata.arcgis.com/) | Fire perimeters (YTD, updated daily) |
| [OpenStreetMap Overpass](https://overpass-api.de/) | Fire station locations (refreshed monthly) |
| [US Census Cartographic Boundaries](https://www.census.gov/geographies/mapping-files/time-series/geo/cartographic-boundary.html) | State + county polygons |

- Distances are straight-line (haversine equivalent via Albers Equal Area, EPSG:5070), perimeter edge to nearest mapped station.
- Acreage: best available of `IncidentSize` or `GISAcres`.
- Active = `PercentContained` is null or < 100.

*Built by [B. Groves](https://github.com/bdgroves) · MIT License*
