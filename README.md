# 🔥 WILDFIRE RESPONSE GAP ANALYSIS

[![Last Updated](https://img.shields.io/github/last-commit/bdgroves/wildfire-response-gaps?label=Last%20Updated&color=ff4500)](https://github.com/bdgroves/wildfire-response-gaps/commits/main)
[![2026 Season](https://img.shields.io/badge/2026%20Season-Live-red)](https://bdgroves.github.io/wildfire-response-gaps/)
[![Daily Update](https://github.com/bdgroves/wildfire-response-gaps/actions/workflows/update_wildfire_map.yml/badge.svg?branch=main)](https://github.com/bdgroves/wildfire-response-gaps/actions/workflows/update_wildfire_map.yml)

---

> When a wildfire ignites in eastern Oregon, help isn't minutes away. It's hours. And it isn't coming from a fire station — because there isn't one within 50 kilometers.
>
> But it's still coming.

## 🌐 [→ OPEN THE LIVE MAP](https://bdgroves.github.io/wildfire-response-gaps/)

Interactive Leaflet map. Fire perimeters refreshed every morning at 5am Pacific. Click any fire for distance to nearest station.

---

## THE FINDING

I set out to measure a coverage gap. I calculated the straight-line distance from every wildfire perimeter on the West Coast to the nearest mapped fire station in OpenStreetMap. California and Washington fires cluster tightly to stations. Oregon doesn't.

Then I overlaid the counties where **Rangeland Fire Protection Associations** operate — the volunteer network authorized by Oregon statute that responds to fires on rangeland with no traditional fire district coverage.

**Of every Oregon fire this year beyond 50 km from any mapped station, 74 of 75 (98.7%) fall inside an RFPA county.**

The "coverage gap" the traditional map shows isn't a gap. It's the boundary between two institutions.

[![2026 YTD](https://github.com/bdgroves/wildfire-response-gaps/raw/main/output/figures/ytd_natgeo.png)](/output/figures/ytd_natgeo.png)

---

## WHAT IS AN RFPA?

<abbr title="Rangeland Fire Protection Association">RFPAs</abbr> are legally recognized volunteer networks of landowners — ranchers, farmers, and local residents — trained and authorized under Oregon Revised Statutes to fight wildfire on private and state lands where no existing state or local protection reaches. They're not informal mutual aid. They're codified in Oregon law with defined authority and structure.

**28 RFPAs protect over 17.5 million acres across 15 eastern and central Oregon counties.** Oregon is the only state in the country with this formal structure at scale. Idaho and Nevada have since authorized their own; Washington is considering legislation.

Ranchers are typically much closer to fire starts than any government resource. They arrive with fire-equipped pickups, slip-on water tanks, and generations of knowledge of the specific terrain. When a traditional station is 100 km away and the fire is running in dry sagebrush, the difference between "on scene in 15 minutes" and "on scene in 2 hours" is often the difference between a two-acre save and a 100,000-acre disaster.

---

## WHY OREGON IS DIFFERENT

Eastern Oregon is enormous, sparsely populated rangeland. The traditional model — municipal fire departments and rural fire protection districts serving population centers — doesn't reach out there because the population isn't out there. Malheur County alone is 9,930 square miles, larger than the entire state of New Hampshire.

Some illustrative geography:

- **Frenchglen** in Harney County has a population of around 12. The Frenchglen Fire Guard Station is the nearest mapped station to more wildfires than any other point on the West Coast.
- **Malheur, Harney, and Lake counties** together are nearly the size of West Virginia and contain fewer people than Redmond, Washington.
- The nearest hospital to some ranches in Owyhee County is a three-hour drive.

Traditional fire protection follows population. RFPAs follow the fires.

---

## HOW THIS MAP WORKS

The map above updates automatically every day, following a repeatable pipeline anyone can inspect:

| Step | What it does |
| --- | --- |
| `python/fetch_fires.py` | Downloads fresh YTD fire perimeters from the NIFC WFIGS API for CA, OR, WA. Handles rate limits and paging. |
| `python/fetch_stations.py` | Pulls fire station points from OpenStreetMap Overpass, monthly, across the three-state bounding boxes. |
| `python/fetch_rfpa.py` | Rebuilds RFPA coverage from Oregon county boundaries. County-approximate; see limitations. |
| `python/build_ytd_map.py` | Reprojects to Albers Equal Area, computes nearest-station distance for every fire, checks RFPA containment for the Oregon "gap" fires, and produces the static map + summary JSON. |
| `.github/workflows/update_wildfire_map.yml` | Runs the whole pipeline at 5am Pacific daily, commits results back to `main`. |

The dashboard is a static HTML page served by GitHub Pages that reads the daily-updated files.

---

## METHODOLOGY & LIMITATIONS

The 98.7% number is honest but comes with important caveats. I'd rather list them than let anyone find them later.

**RFPA territory is shown at county resolution.** Actual RFPA charter boundaries follow specific parcel ownership and often cross or subdivide counties. Counties are a generous approximation — the *real* containment percentage is somewhere between 65% and 99%. The specific value doesn't change the story (nearly all gap fires are in RFPA-eligible geography); it does affect how tight the number is.

**OpenStreetMap undercounts rural fire stations.** BLM and USFS fire guard stations are sometimes tagged with keys other than `amenity=fire_station`. Small volunteer departments in unincorporated communities may not appear at all. This inflates the raw "fires beyond 50 km" count. Even with a more complete station list, Oregon's gap is real (rural station density east of the Cascades is genuinely much lower than west), but the magnitude is likely somewhat overstated.

**Distances are straight-line, perimeter edge to station.** Actual response time depends on road network access. In eastern Oregon, roads are often unpaved and slow; the map's distances are optimistic in absolute terms but useful for comparison across states.

**Fires are counted by perimeter, not by ignition.** Multiple perimeters from the same incident get counted separately in NIFC's YTD service.

---

## RUN LOCALLY

```bash
git clone https://github.com/bdgroves/wildfire-response-gaps.git
cd wildfire-response-gaps
pip install -r requirements.txt

# Refresh RFPA boundaries (once, or when ODF publishes an update)
python python/fetch_rfpa.py

# Grab fresh perimeters
python python/fetch_fires.py

# Build the static map + summary JSON
python python/build_ytd_map.py

# Preview the dashboard
python -m http.server 8000
# → http://localhost:8000
```

Requires Python 3.10+, GDAL, and standard geospatial libraries.

---

## DATA & METHODS

| Source | Used for | Cadence |
| --- | --- | --- |
| [NIFC WFIGS YTD Perimeters](https://data-nifc.opendata.arcgis.com/) | Fire perimeters, active status, acreage | Daily |
| [OpenStreetMap Overpass](https://overpass-api.de/) | Fire station locations (`amenity=fire_station`) | Monthly |
| [US Census Cartographic Boundaries](https://www.census.gov/geographies/mapping-files/time-series/geo/cartographic-boundary.html) | State + county polygons | Static |
| Oregon Department of Forestry ([RFPA program](https://www.oregon.gov/odf/fire/pages/rangeland.aspx)) | RFPA county list (compiled from ODF Board of Forestry 2024 materials) | Rarely changes |

- Projections: analysis and distance in EPSG:5070 (Albers Equal Area CONUS); display in Web Mercator for the interactive map.
- Fire acreage takes the best available of `IncidentSize` (reported) or `poly_GISAcres` (measured from perimeter).
- Active = `PercentContained` is null or below 100.

---

## THE POINT

The gap is real. What's on the other side is not what the map looks like.

This project measures both.

---

*Built by [B. Groves](https://github.com/bdgroves) · MIT License · Data updated daily by [GitHub Actions](https://github.com/bdgroves/wildfire-response-gaps/actions)*
