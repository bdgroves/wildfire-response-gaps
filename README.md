# 🔥 Wildfire Response Gap Analysis

**How far is the nearest fire station when a wildfire breaks out?**

A Friday afternoon curiosity project that turned into something I couldn't stop 
working on. Built entirely in R using open data - no proprietary software required.

![Oregon Coverage Map](output/figures/oregon_wildfire_coverage.png)

---

## The Finding

Frenchglen Fire Guard Station in Harney County, Oregon serves a permanent 
community of approximately 12 people. This analysis found it is the nearest 
recorded fire station to **148 wildfires** covering **516,867 acres**, with a 
mean estimated response time of **114 minutes**.

But the real story is more nuanced than the numbers suggest.

The station operates in partnership with the **Frenchglen Rangeland Fire 
Protection Association (RFPA)** - a network of local ranchers across the 
surrounding high desert who respond with their own equipment: fire-equipped 
semi-trucks, slip-on water tanks, and generations of knowledge of this land. 
These ranchers are often on scene *hours* before federal resources arrive. 
The infrastructure gap is real - the people filling it are remarkable.

---

## Regional Summary

| Region | Fires | Median Distance | % Fires >50km | Key Finding |
|--------|-------|----------------|---------------|-------------|
| Washington | 1,388 | 8.6 km | 1.9% | Good coverage, gaps in Okanogan |
| TX Panhandle | 51 | 10.3 km | 0% | Fritch FD (pop ~2,000) covers 65% of fires |
| California | 1,051 | 10.8 km | 1.5% | CAL FIRE network investment pays off |
| Oregon | 1,196 | 26.7 km | 30.1% | Serious gaps in eastern counties |
| Malheur Co. OR | 127 | 139.1 km | 100% | Every recorded fire is a critical gap |

---

## Key Findings

### Texas Panhandle
- 51 final fire perimeters | 2020-2026
- 47 fire stations identified via OpenStreetMap
- **100% of fires within 50km** of a station - best coverage of all regions studied
- **Fritch Fire Department** (population ~2,000) is nearest station to 33 of 51 
  fires (65%) and over 150,000 total acres
- Most isolated fire: RB 93 in Dallam County at 42.5km from Dalhart FD

### Oregon
- 1,196 final fire perimeters | 2020-2025
- **30% of fires more than 50km** from nearest recorded station
- **171 fires more than 100km** from nearest station
- Oregon's crisis is concentrated in the southeast - Malheur and Harney counties
- 2024 was a record-breaking fire season that exposed these gaps in real time

### The Durkee Fire (2024)
- 294,265 acres in Baker County, Oregon
- Nearest station: La Grande Fire House - **87km away**
- Estimated response time: **95 minutes**
- Part of a record 2024 fire season in eastern Oregon

### Frenchglen Deep Dive
- 148 fires as nearest station | 516,867 total acres
- Mean distance to fires: 107 km
- Mean estimated response time: 114 minutes  
- 8 fires over 10,000 acres in coverage zone
- Largest single fire: Falls Fire, 151,683 acres (Harney Co., 2024)

---

## Methodology

### Distance Calculation
- Distances measured from **fire perimeter EDGE to nearest station** 
  (not centroid)
- Edge distance is more meaningful for large fires - a station adjacent 
  to the edge of a 100,000 acre fire is very different from one near the centroid
- `st_distance()` from the R `sf` package, units in meters (UTM Zone 14N)

### Response Time Estimates
- Straight-line distance × **1.3 road factor** at **80 km/h**
- Standard rule of thumb for rural areas
- Actual times on gravel/two-track roads in Malheur and Harney counties 
  are likely **significantly longer** - treat as a minimum estimate

### Fire Perimeters
- **Final perimeters only** - daily perimeter snapshots excluded to avoid 
  double-counting active fires
- Source: NIFC WFIGS Interagency Perimeters - All Years
- Queried via REST API filtered to study area - no full national download needed

### Fire Stations
- Source: OpenStreetMap via `osmdata` R package
- **Important caveat:** OSM likely undercounts rural volunteer departments 
  and Rangeland Fire Protection Associations (RFPAs)
- Real coverage in remote areas may be modestly better than shown
- Treat station counts as **minimum estimates**

---

## Data Sources

| Data | Source | Access Method |
|------|--------|---------------|
| Fire perimeters | [NIFC WFIGS Interagency Perimeters](https://data-nifc.opendata.arcgis.com/) | REST API |
| Fire stations | [OpenStreetMap](https://www.openstreetmap.org/) | `osmdata` R package |
| County boundaries | [US Census Bureau](https://www.census.gov/geographies/mapping-files.html) | `tigris` R package |

---

## How to Run

### Requirements
```r
install.packages(c(
  "osmdata",   # OpenStreetMap queries
  "sf",        # Spatial data handling
  "tidyverse", # Data manipulation and plotting
  "tigris",    # US Census boundary files
  "tmap",      # Interactive mapping
  "httr",      # NIFC API requests
  "jsonlite",  # JSON parsing
  "mapview",   # Alternative interactive mapping
  "leaflet",   # Color palettes
  "patchwork", # Combine ggplots
  "scales"     # Formatted numbers
))