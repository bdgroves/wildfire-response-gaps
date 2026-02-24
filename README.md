# 🔥 Wildfire Response Gap Analysis

**How far is the nearest fire station when a wildfire breaks out?**

A portfolio project built in R using open federal data. What started as a 
spatial data science learning exercise uncovered a structural coverage gap 
in Oregon that is fundamentally different from its neighbors — and the 
volunteer system that fills it.

![Oregon's Wildfire Response Gap — National Geographic Style](output/figures/oregon_natgeo.png)

---

## The Finding That Surprised Me

I calculated the distance from every wildfire perimeter to the nearest fire 
station across three West Coast states. California and Washington looked 
normal. Oregon didn't.

| State | Fires | Median Distance | % Fires >50km |
|-------|-------|----------------|---------------|
| Washington | 1,388 | 8.6 km | 1.9% |
| California | 1,051 | 10.8 km | 1.5% |
| **Oregon** | **1,196** | **26.7 km** | **30.1%** |

I checked the data twice. The pattern held.

![State Comparison](output/figures/oregon_comparison_bar.png)

---

## Why Oregon Is Different

Eastern Oregon is enormous, sparsely populated rangeland. Traditional fire 
station coverage — the model that works in western Oregon, in California's 
populated corridors, in western Washington — doesn't extend there.

**Malheur County** alone is 9,930 square miles (larger than New Hampshire). 
Median fire-to-station distance: **139.1 km**. Every single fire is beyond 
50km from any mapped station.

Oregon's response: **Rangeland Fire Protection Associations (RFPAs)**.

RFPAs are legally recognized volunteer networks — ranchers and landowners 
organized to protect over **17.5 million acres** that have no existing state 
or local fire protection. This isn't informal mutual aid. It's codified in 
Oregon statute with defined authority and structure.

![Oregon Coverage Map](output/figures/oregon_coverage_gap.png)

---

## Frenchglen Fire Guard Station

![Frenchglen Coverage Zone](output/figures/oregon_frenchglen_zoom.png)

Frenchglen Fire Guard Station in Harney County is the nearest mapped station 
to **148 wildfires** covering **516,867 acres**.

| Metric | Value |
|--------|-------|
| Fires as nearest station | 148 |
| Total acres in coverage zone | 516,867 |
| Mean distance to fires | 106.9 km |
| Mean estimated response time | 114 minutes |
| Largest fire | Falls Fire — 151,683 ac (2024) |

But Frenchglen isn't operating alone. It's one node in a network that 
includes the **Frenchglen RFPA**, BLM resources, and US Fish & Wildlife. 
The ranchers in these associations are often on scene hours before federal 
resources arrive — with fire-equipped trucks, slip-on water tanks, and 
generations of knowledge of this land.

The infrastructure gap is real. The people filling it are remarkable.

---

## Distance Distribution

![Distance Histogram](output/figures/oregon_distance_histogram.png)

California and Washington fires cluster under 25km. Oregon has a long tail 
stretching past 200km — not as outliers, but as the norm for the eastern 
half of the state.

---

## West Coast Full Picture

![West Coast Combined](output/figures/west_coast_combined.png)

Three states, 3,635 fire perimeters, one map. The contrast between 
Oregon's eastern half and everything else is visible at a glance.

---

## 2026 Fire Season — Live YTD Tracker

This map rebuilds automatically from the NIFC WFIGS API each time the 
script runs. During fire season it shows every current perimeter, 
distance to nearest station, and adaptive stat panels that evolve as 
the season progresses.

![2026 YTD](output/figures/ytd_natgeo.png)

**Adaptive panels by season stage:**

| Stage | Fires | Sidebar panels |
|-------|-------|----------------|
| Early (<10) | Feb–May | Overview + Coverage + State Breakdown |
| Building (10-49) | Jun | Overview + Coverage + Top 5 Stations |
| Peak (50+) | Jul–Oct | Overview + Top 5 Stations + Worst 5 Counties |

```r
# One command to update during fire season:
source("R/19_ytd_natgeo.R")
```

---

## Full Regional Summary

| Region | Fires | Median Distance | % >50km | Key Finding |
|--------|-------|----------------|---------|-------------|
| TX Panhandle | 51 | 10.3 km | 0% | Best coverage — Fritch FD covers 65% of fires |
| Washington | 1,388 | 8.6 km | 1.9% | Good coverage, gaps in Okanogan |
| California | 1,051 | 10.8 km | 1.5% | CAL FIRE network investment shows |
| Oregon | 1,196 | 26.7 km | 30.1% | Structural gaps in eastern counties |
| Malheur Co. OR | 127 | 139.1 km | 100% | Every fire is a critical gap |

### Coverage Categories (West Coast, 3,635 fires)

| Category | Distance | Fires | % |
|----------|----------|-------|---|
| Good | <10 km | 1,471 | 40.5% |
| Moderate | 10–25 km | 1,179 | 32.4% |
| Poor | 25–50 km | 582 | 16.0% |
| Critical | 50–100 km | 232 | 6.4% |
| Extreme | 100+ km | 171 | 4.7% |

---

## Sample Visualizations

<table>
<tr>
<td><img src="output/figures/oregon_natgeo.png" width="400"/><br><em>NatGeo-style Oregon layout</em></td>
<td><img src="output/figures/ytd_natgeo.png" width="400"/><br><em>Live YTD tracker</em></td>
</tr>
<tr>
<td><img src="output/figures/oregon_frenchglen_zoom.png" width="400"/><br><em>Frenchglen detail with range rings</em></td>
<td><img src="output/figures/west_coast_combined.png" width="400"/><br><em>West Coast combined</em></td>
</tr>
</table>

---

## Methodology

### Distance Calculation
- Distances measured from **fire perimeter edge** to nearest station 
  (not centroid-to-centroid)
- Edge distance is more meaningful for large fires — a station adjacent 
  to the edge of a 100,000-acre fire is very different from one near 
  the centroid
- `st_distance()` from the `sf` package
- CRS: UTM Zone 14N (EPSG 32614) for Texas, NAD83 Conus Albers 
  (EPSG 5070) for West Coast

### Acreage
- Historical fires: `attr_IncidentSize` from NIFC
- YTD fires: `coalesce(attr_IncidentSize, poly_GISAcres)` — NIFC 
  sometimes reports size as NA for new fires; GISAcres calculated 
  from perimeter geometry is more reliable for early-season data

### Response Time Estimates
- Straight-line distance × 1.3 road factor at 80 km/h
- Standard rule of thumb for rural areas
- Actual times on gravel/two-track roads in Malheur and Harney counties 
  are likely significantly longer — treat as minimum estimates

### Fire Perimeters
- **Final perimeters only** for historical analysis — daily snapshots 
  excluded to avoid double-counting
- **All perimeter types** for YTD — includes initial through final 
  to capture active fires
- Source: NIFC WFIGS Interagency Perimeters (all years + YTD)
- Queried via REST API with state and bbox filters

### Fire Stations
- Source: OpenStreetMap via `osmdata` R package
- **Important caveat:** OSM likely undercounts rural volunteer 
  departments and RFPAs
- Real coverage in remote areas may be modestly better than shown
- Treat station counts as minimum estimates

### What This Analysis Does NOT Capture
- RFPA coverage zones and volunteer capacity
- BLM and USFS dispatch resources
- Mutual aid agreements between agencies
- Road network distances (straight-line only)
- Actual operational response times

The distance metric reveals structural coverage patterns. Actual 
wildfire response involves layers of coordination not visible in 
station location data alone.

---

## Project Structure

```
R/
  00_run_all.R                 Run everything in order
  01_setup.R                   Libraries and global settings
  02_study_area.R              TX Panhandle county boundaries
  03_fire_stations.R           OSM fire station fetch and clean
  04_fire_perimeters.R         NIFC API fetch and clean
  05_distance_analysis.R       Distance matrix and statistics
  06_visualizations.R          TX Panhandle plots and maps
  07_west_coast_setup.R        West Coast CRS, themes, output dir
  08_west_coast_study_area.R   CA/OR/WA county boundaries
  09_west_coast_stations.R     OSM stations with cache + retry
  10_west_coast_perimeters.R   NIFC paginated fetch with type fix
  11_west_coast_distance.R     Smart radius distance + RDS baseline
  12_west_coast_viz.R          Oregon hero map + comparison charts
  13_west_coast_ytd.R          Current fire season YTD data fetch
  14_state_maps.R              CA and WA coverage maps
  15_west_coast_combined_map.R All 3 states on one map
  16_west_coast_ytd_maps.R     YTD maps (standard ggplot style)
  17_oregon_deep_dive.R        Oregon story visuals for narrative
  18_oregon_natgeo.R           NatGeo-style Oregon layout
  19_ytd_natgeo.R              NatGeo-style YTD live tracker

output/
  figures/                     All saved PNGs for README + sharing
```

---

## Data Sources

| Data | Source | Access |
|------|--------|--------|
| Fire perimeters | [NIFC WFIGS](https://data-nifc.opendata.arcgis.com/) | REST API |
| Fire stations | [OpenStreetMap](https://www.openstreetmap.org/) | `osmdata` package |
| County boundaries | [US Census Bureau](https://www.census.gov/geographies/mapping-files.html) | `tigris` package |

---

## How to Run

### Requirements
```r
install.packages(c(
  "sf",        # Spatial data
  "tidyverse", # Data manipulation
  "osmdata",   # OpenStreetMap queries
  "tigris",    # Census boundaries
  "httr",      # API requests
  "jsonlite",  # JSON parsing
  "ggrepel",   # Label placement
  "ggspatial", # Scale bars + north arrows
  "cowplot",   # Plot composition
  "patchwork", # Combine ggplots
  "scales",    # Number formatting
  "maps"       # US state outlines for insets
))
```

### Full pipeline
```r
source("R/00_run_all.R")
```

### Quick reload from baseline
```r
source("R/01_setup.R")
source("R/07_west_coast_setup.R")
baseline <- readRDS("C:/data/Shapefiles/WestCoast/westcoast_baseline_YYYYMMDD.rds")
list2env(baseline, envir = .GlobalEnv)
```

### NatGeo Oregon map (no API calls needed)
```r
source("R/18_oregon_natgeo.R")
```

### Live YTD update during fire season
```r
source("R/19_ytd_natgeo.R")
```

---

## Built With

R • sf • ggplot2 • cowplot • osmdata • tigris • ggspatial • ggrepel

---

## License

This project is for educational and portfolio purposes. Data sourced from 
public federal APIs and OpenStreetMap (ODbL 1.0).