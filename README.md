# 🔥 Wildfire Response Gap Analysis

![Last Updated](https://img.shields.io/github/last-commit/bdgroves/wildfire-response-gaps?label=Last%20Updated&style=flat-square)
![YTD Status](https://img.shields.io/badge/2026%20YTD-Live%20Tracker-orange?style=flat-square)
![R](https://img.shields.io/badge/Built%20With-R%20%2B%20sf%20%2B%20ggplot2-blue?style=flat-square)
![CI](https://github.com/bdgroves/wildfire-response-gaps/actions/workflows/ytd_update.yml/badge.svg)

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
Oregon statute with defined authority and structure. Oregon is the only state
in the country with this formal structure — no other western state has
replicated it.

![Oregon Coverage Map](output/figures/oregon_coverage_gap.png)

---

## Frenchglen Fire Guard Station

![Frenchglen Coverage Zone](output/figures/oregon_frenchglen_zoom.png)

Frenchglen Fire Guard Station in Harney County — population approximately 12
— is the nearest mapped station to **148 wildfires** covering **516,867 acres**.

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

Updated automatically every day at 6am Pacific via GitHub Actions.
Fetches fresh data from the NIFC WFIGS API, recomputes distances to
the nearest fire station, and commits an updated map to this repo —
no manual intervention required.

![2026 YTD](output/figures/ytd_natgeo.png)

### How to read this map

| Symbol | Meaning |
|--------|---------|
| Red polygon | Active fire perimeter |
| Green polygon | Contained fire perimeter |
| Triangle marker | Fire station (OpenStreetMap) |
| Dashed line | Fire more than 25km from nearest station |
| Fire label | Top fires by acres — name, size, active status |

### Sidebar panels adapt as the season builds

| Stage | Fire Count | When | Panels Shown |
|-------|-----------|------|--------------|
| Early | < 10 fires | Feb–May | Season overview + Response coverage + State breakdown |
| Building | 10–49 fires | Jun | Season overview + Response coverage + Top 5 burdened stations |
| Peak | 50+ fires | Jul–Oct | Season overview + Top 5 burdened stations + Worst 5 coverage counties |

### What updates every morning at 6am Pacific

| Metric | Where it appears |
|--------|-----------------|
| Fire count | Title bar + overview panel |
| Active vs contained split | Overview panel |
| Total acres | Overview panel + subtitle bar |
| Median distance to nearest station | Coverage panel |
| Fires beyond 50km + percentage | Coverage panel |
| Per-state breakdown | States panel (early season) |
| Top 5 most burdened stations | Stations panel (building + peak) |
| Worst 5 coverage counties | Counties panel (peak season) |
| Fire perimeter shapes | Main map |
| Top 10 fire labels with acreage | Main map callouts |
| Connector lines to distant stations | Dashed lines on main map |
| Timestamp | Caption bar + overview panel |

### What the map will show at peak season

By July and August, when Oregon's rangeland fires are active, the map
will surface the same structural gaps documented in the historical
analysis — Malheur and Harney counties with median distances exceeding
100km, Frenchglen Fire Guard Station as the nearest station to dozens
of active fires, and the RFPA volunteer network as the primary response
mechanism for millions of acres.

```r
# Run locally anytime for a fresh map during fire season
source("R/19_ytd_natgeo.R")