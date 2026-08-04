#!/usr/bin/env python3
"""build_ytd_map.py â€” build the NatGeo-style YTD map + summary JSON.

Reads:
  output/fires.geojson       (from fetch_fires.py, or --fetch to hit NIFC live)
  output/stations.json       (from fetch_stations.py)
  data/us_states.geojson     (auto-downloaded once from Census)
  data/us_counties.geojson   (auto-downloaded once from Census)

Writes:
  output/figures/ytd_natgeo.png    NatGeo-style static map
  output/ytd_summary.json          machine-readable stats for the dashboard
  output/ytd_summary.txt           one-liner for a shields.io-style badge
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

import geopandas as gpd
import matplotlib.patches as mpatches
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.patheffects import withStroke
from shapely.geometry import Point

from common import (
    CENSUS_COUNTIES_URL,
    CENSUS_STATES_URL,
    COUNTIES_JSON,
    DATA_DIR,
    FIGURES_DIR,
    FIRES_PATH,
    FIRE_ACTIVE,
    FIRE_ACTIVE_EDGE,
    FIRE_CONTAINED,
    FIRE_CONTAINED_E,
    INK_BLACK,
    INK_BROWN,
    INK_GRAY,
    NATGEO_YELLOW,
    NATGEO_YELLOW_DK,
    OUTPUT_DIR,
    PARCHMENT,
    PARCHMENT_DARK,
    PNG_PATH,
    RFPA_EDGE,
    RFPA_FILL,
    RFPA_JSON,
    STATES_JSON,
    STATE_CODE_MAP,
    STATE_ORDER,
    STATIONS_PATH,
    SUMMARY_JSON,
    SUMMARY_TXT,
    WC_CRS,
    log,
    nifc_fetch_all,
    resolve_field,
)

try:
    from adjustText import adjust_text
    HAVE_ADJUSTTEXT = True
except ImportError:
    HAVE_ADJUSTTEXT = False


SERIF = "DejaVu Serif"

plt.rcParams.update({
    "font.family":       SERIF,
    "font.serif":        [SERIF, "Liberation Serif", "Times New Roman", "serif"],
    "figure.facecolor":  PARCHMENT,
    "axes.facecolor":    PARCHMENT,
    "savefig.facecolor": PARCHMENT,
    "savefig.edgecolor": "none",
    "text.color":        INK_BLACK,
})


def _mylog(msg: str) -> None:
    log(msg, prefix="build")


def format_acres(x: float) -> str:
    if pd.isna(x) or x == 0:
        return "0"
    if x >= 1000:
        return f"{round(x):,}"
    if x >= 1:
        return f"{round(x, 1)}"
    return f"{round(x, 2)}"


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_fires(allow_fetch: bool) -> gpd.GeoDataFrame:
    if FIRES_PATH.exists():
        _mylog(f"Reading {FIRES_PATH}")
        gdf = gpd.read_file(FIRES_PATH)
        if len(gdf) > 0:
            return gdf
        _mylog("cache exists but is empty (pre-season / no fires)")
        return gdf
    if not allow_fetch:
        raise FileNotFoundError(
            f"{FIRES_PATH} missing. Run python/fetch_fires.py first, "
            "or pass --fetch to hit NIFC directly."
        )
    _mylog("Cache missing â€” fetching from NIFC directly")
    from common import NIFC_STATE_CODES
    states = ",".join(f"'{c}'" for c in NIFC_STATE_CODES)
    where = f"attr_POOState IN ({states})"
    feats = list(nifc_fetch_all(where))
    if not feats:
        return gpd.GeoDataFrame(geometry=[], crs=4326)
    return gpd.GeoDataFrame.from_features(feats, crs=4326)


def load_stations() -> gpd.GeoDataFrame:
    if not STATIONS_PATH.exists():
        raise FileNotFoundError(
            f"{STATIONS_PATH} missing. Run python/fetch_stations.py first."
        )
    with STATIONS_PATH.open() as f:
        raw = json.load(f)

    if isinstance(raw, dict) and raw.get("type") == "FeatureCollection":
        gdf = gpd.GeoDataFrame.from_features(raw["features"], crs=4326)
    elif isinstance(raw, list):
        df = pd.DataFrame(raw)
        if "lon" not in df.columns or "lat" not in df.columns:
            raise ValueError("stations.json entries need 'lon' and 'lat'")
        gdf = gpd.GeoDataFrame(
            df,
            geometry=[Point(r.lon, r.lat) for r in df.itertuples()],
            crs=4326,
        )
    else:
        raise ValueError("Unrecognized stations.json shape")

    if "name" not in gdf.columns:
        gdf["name"] = "Unnamed station"
    gdf["name"] = gdf["name"].fillna("Unnamed station")
    return gdf


def load_boundaries() -> tuple[gpd.GeoDataFrame, gpd.GeoDataFrame]:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if not STATES_JSON.exists():
        _mylog("Downloading Census state boundaries (one-time)...")
        gpd.read_file(CENSUS_STATES_URL).to_file(STATES_JSON, driver="GeoJSON")
    if not COUNTIES_JSON.exists():
        _mylog("Downloading Census county boundaries (one-time)...")
        gpd.read_file(CENSUS_COUNTIES_URL).to_file(COUNTIES_JSON, driver="GeoJSON")
    states = gpd.read_file(STATES_JSON).to_crs(4326)
    counties = gpd.read_file(COUNTIES_JSON).to_crs(4326)
    return states, counties


def load_rfpa() -> gpd.GeoDataFrame | None:
    """Optional Rangeland Fire Protection Association boundaries.
    File is manually curated (see python/fetch_rfpa.py). Returns None if
    the file isn't present so the pipeline degrades gracefully."""
    if not RFPA_JSON.exists():
        _mylog("No RFPA boundaries found â€” skipping overlay")
        return None
    gdf = gpd.read_file(RFPA_JSON).to_crs(4326)
    if "name" not in gdf.columns:
        gdf["name"] = "Unnamed RFPA"
    _mylog(f"RFPA polygons: {len(gdf)}")
    return gdf


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

def prep_fires(fires: gpd.GeoDataFrame) -> gpd.GeoDataFrame:
    """Filter to CA/OR/WA and add normalized columns."""
    cols = fires.columns
    name_col  = resolve_field(cols, "incident_name")
    state_col = resolve_field(cols, "state")
    size_col  = resolve_field(cols, "size")
    cont_col  = resolve_field(cols, "contained")
    gisac_col = resolve_field(cols, "gis_acres")
    if state_col is None:
        raise ValueError("No state field found in fires data")

    raw_state = fires[state_col].astype(str)
    fires = fires.copy()
    fires["state"] = raw_state.map(STATE_CODE_MAP).fillna(raw_state)
    fires = fires[fires["state"].isin(STATE_ORDER)].copy()

    fires["incident_name"] = fires[name_col] if name_col else "UNNAMED"
    if size_col and gisac_col:
        size = pd.to_numeric(fires[size_col], errors="coerce").replace(0, np.nan)
        gis  = pd.to_numeric(fires[gisac_col], errors="coerce")
        fires["acres"] = size.combine_first(gis).fillna(0)
    elif size_col:
        fires["acres"] = pd.to_numeric(fires[size_col], errors="coerce").fillna(0)
    elif gisac_col:
        fires["acres"] = pd.to_numeric(fires[gisac_col], errors="coerce").fillna(0)
    else:
        fires["acres"] = 0.0

    if cont_col:
        pct = pd.to_numeric(fires[cont_col], errors="coerce")
        fires["is_active"] = pct.isna() | (pct < 100)
    else:
        fires["is_active"] = True

    fires["geometry"] = fires.geometry.buffer(0)   # fix invalid rings
    return fires.reset_index(drop=True)


def compute_distances(
    fires: gpd.GeoDataFrame, stations: gpd.GeoDataFrame
) -> gpd.GeoDataFrame:
    fires_p    = fires.to_crs(WC_CRS)
    stations_p = stations.to_crs(WC_CRS)
    joined = fires_p.sjoin_nearest(
        stations_p[["name", "geometry"]].rename(columns={"name": "nearest_station_name"}),
        how="left",
        distance_col="dist_nearest_m",
    ).drop(columns="index_right")
    joined = joined.loc[~joined.index.duplicated(keep="first")]
    joined["dist_nearest_km"] = joined["dist_nearest_m"] / 1000
    return joined.to_crs(4326)


def empty_stats() -> dict:
    return {
        "n_total": 0, "n_active": 0, "n_contained": 0,
        "total_acres": 0.0, "median_dist": 0.0, "n_over_50": 0,
        "pct_over_50": 0.0, "season_stage": "early",
        "by_state": [], "top_stations": None, "rfpa": None,
        "generated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
    }


def summarize(fires: gpd.GeoDataFrame, rfpa: gpd.GeoDataFrame | None = None) -> dict:
    n_total     = len(fires)
    n_active    = int(fires["is_active"].sum())
    total_acres = round(float(fires["acres"].sum()), 1)
    median_dist = float(np.round(fires["dist_nearest_km"].median(), 1)) if n_total else 0.0
    n_over_50   = int((fires["dist_nearest_km"] >= 50).sum())
    pct_over_50 = round(n_over_50 / n_total * 100, 1) if n_total else 0.0
    stage       = "peak" if n_total >= 50 else "building" if n_total >= 10 else "early"

    by_state = (
        fires.groupby("state", as_index=False)
             .agg(
                 n_fires=("incident_name", "size"),
                 n_active=("is_active", "sum"),
                 total_acres=("acres", "sum"),
                 median_dist=("dist_nearest_km", lambda s: round(s.median(), 1)),
                 pct_over_50=(
                     "dist_nearest_km",
                     lambda s: round((s > 50).mean() * 100, 1),
                 ),
             )
             .assign(total_acres=lambda d: d["total_acres"].round(1),
                     n_active=lambda d: d["n_active"].astype(int))
             .sort_values("n_fires", ascending=False)
             .to_dict(orient="records")
    )

    burden = None
    if n_total >= 10:
        burden = (
            fires.groupby("nearest_station_name", as_index=False)
                 .agg(
                     n_fires=("incident_name", "size"),
                     n_active=("is_active", "sum"),
                     total_acres=("acres", "sum"),
                     mean_dist=("dist_nearest_km", lambda s: round(s.mean(), 1)),
                     max_dist=("dist_nearest_km", lambda s: round(s.max(), 1)),
                     states=("state", lambda s: "/".join(sorted(set(s)))),
                 )
                 .assign(total_acres=lambda d: d["total_acres"].round(1),
                         n_active=lambda d: d["n_active"].astype(int))
                 .sort_values("n_fires", ascending=False)
                 .head(5)
                 .to_dict(orient="records")
        )

    return {
        "n_total":       n_total,
        "n_active":      n_active,
        "n_contained":   n_total - n_active,
        "total_acres":   total_acres,
        "median_dist":   median_dist,
        "n_over_50":     n_over_50,
        "pct_over_50":   pct_over_50,
        "season_stage":  stage,
        "by_state":      by_state,
        "top_stations":  burden,
        "rfpa":          rfpa_stats(fires, rfpa),
        "generated_at":  datetime.now().astimezone().isoformat(timespec="seconds"),
    }


def rfpa_stats(fires: gpd.GeoDataFrame, rfpa: gpd.GeoDataFrame | None) -> dict | None:
    """How many of the >50km 'coverage gap' Oregon fires actually fall inside
    an RFPA polygon? That's the whole story: gap on the map â‰  uncovered."""
    if rfpa is None or len(rfpa) == 0:
        return None
    or_fires = fires[fires["state"] == "Oregon"]
    if len(or_fires) == 0:
        return {"n_rfpa": len(rfpa),
                "or_gap_fires": 0, "or_gap_in_rfpa": 0, "or_gap_in_rfpa_pct": 0.0,
                "total_acres_covered": float(rfpa.to_crs(WC_CRS).area.sum() * 0.000247105)}

    # Union RFPA polygons for a single containment test
    rfpa_union = rfpa.to_crs(4326).geometry.union_all()
    gap_mask = or_fires["dist_nearest_km"] >= 50
    gap = or_fires[gap_mask]
    if len(gap) == 0:
        in_rfpa = 0
    else:
        # Fire "in RFPA" if its representative point falls inside any polygon
        pts = gap.geometry.representative_point()
        in_rfpa = int(pts.within(rfpa_union).sum())
    return {
        "n_rfpa":              int(len(rfpa)),
        "or_gap_fires":        int(len(gap)),
        "or_gap_in_rfpa":      in_rfpa,
        "or_gap_in_rfpa_pct":  round(in_rfpa / len(gap) * 100, 1) if len(gap) else 0.0,
        "total_acres_covered": round(float(rfpa.to_crs(WC_CRS).area.sum() * 0.000247105), 0),
    }


# ---------------------------------------------------------------------------
# Plotting helpers
# ---------------------------------------------------------------------------

def _bar(ax, color: str) -> None:
    ax.set_xlim(0, 1); ax.set_ylim(0, 1)
    ax.set_facecolor(color)
    ax.set_xticks([]); ax.set_yticks([])
    for s in ax.spines.values():
        s.set_visible(False)


def _panel(ax) -> None:
    ax.set_xlim(0, 1); ax.set_ylim(0, 1)
    ax.set_facecolor(PARCHMENT)
    ax.set_xticks([]); ax.set_yticks([])
    for s in ax.spines.values():
        s.set_edgecolor(INK_BROWN); s.set_linewidth(0.6)


def draw_title(ax, year: int) -> None:
    _bar(ax, NATGEO_YELLOW)
    ax.text(0.02, 0.55, f"{year} WEST COAST WILDFIRE SEASON",
            fontsize=22, weight="bold", color=INK_BLACK, va="center")
    ax.text(0.98, 0.55, "YEAR TO DATE",
            fontsize=13, weight="bold", color=(0.10, 0.10, 0.10, 0.5),
            va="center", ha="right")


def draw_subtitle(ax, stats: dict) -> None:
    _bar(ax, PARCHMENT)
    parts = [
        f"{stats['n_total']:,} fire perimeters across California, Oregon, "
        f"and Washington as of {datetime.now():%B %d, %Y}. ",
        f"{stats['n_active']} fires remain active",
    ]
    if stats["total_acres"] > 0:
        parts.append(f" covering {round(stats['total_acres']):,} total acres")
    parts.append(f". Median distance to nearest station: {stats['median_dist']} km.")
    r = stats.get("rfpa")
    if r and r["or_gap_fires"] > 0:
        parts.append(
            f"  Of {r['or_gap_fires']} Oregon fires beyond 50 km, "
            f"{r['or_gap_in_rfpa']} ({r['or_gap_in_rfpa_pct']}%) "
            f"fall within Rangeland Fire Protection Association volunteer coverage."
        )
    ax.text(0.02, 0.5, "".join(parts), fontsize=11, color=INK_BROWN, va="center")


def draw_legend_strip(ax, has_rfpa: bool = False) -> None:
    _bar(ax, PARCHMENT)
    ax.add_patch(mpatches.Rectangle((0.02, 0.25), 0.03, 0.5,
                                    facecolor=FIRE_ACTIVE, alpha=0.7,
                                    edgecolor="none"))
    ax.text(0.055, 0.5, "Active fire", fontsize=9, color=INK_BROWN, va="center")

    ax.add_patch(mpatches.Rectangle((0.15, 0.25), 0.03, 0.5,
                                    facecolor=FIRE_CONTAINED, alpha=0.5,
                                    edgecolor="none"))
    ax.text(0.185, 0.5, "Contained", fontsize=9, color=INK_BROWN, va="center")

    ax.scatter([0.28], [0.5], marker="^", s=25, color=INK_BROWN)
    ax.text(0.295, 0.5, "Fire station", fontsize=9, color=INK_BROWN, va="center")

    ax.plot([0.40, 0.44], [0.5, 0.5], color=NATGEO_YELLOW_DK,
            linewidth=1.2, linestyle="--")
    ax.text(0.45, 0.5, "Distance to station (>25 km)",
            fontsize=9, color=INK_BROWN, va="center")

    if has_rfpa:
        ax.add_patch(mpatches.Rectangle((0.66, 0.25), 0.03, 0.5,
                                        facecolor=RFPA_FILL, alpha=0.28,
                                        edgecolor=RFPA_EDGE, linewidth=0.4))
        ax.text(0.695, 0.5, "RFPA volunteer coverage",
                fontsize=9, color=INK_BROWN, va="center")


def draw_caption(ax) -> None:
    _bar(ax, PARCHMENT)
    txt = (
        "DATA: NIFC WFIGS YTD Interagency Perimeters + OpenStreetMap fire stations  |  "
        "Straight-line distances, perimeter edge to station  |  "
        "Acreage: best of IncidentSize / GISAcres  |  "
        "Analysis by B. Groves  |  "
        f"{datetime.now():%B %d, %Y %H:%M}"
    )
    ax.text(0.02, 0.55, txt, fontsize=8, color=INK_GRAY, va="center")
    ax.add_patch(mpatches.Rectangle((0, 0), 1, 0.12, facecolor=NATGEO_YELLOW,
                                    edgecolor="none"))


def draw_stat_overview(ax, stats: dict) -> None:
    _panel(ax)
    year = datetime.now().year
    ax.text(0.5, 0.93, f"{year} SEASON AT A GLANCE",
            ha="center", weight="bold", fontsize=11)
    ax.text(0.5, 0.72, f"{stats['n_total']:,}",
            ha="center", weight="bold", fontsize=32, color=FIRE_ACTIVE)
    ax.text(0.5, 0.60, "FIRE PERIMETERS", ha="center", fontsize=9, color=INK_GRAY)
    ax.plot([0.1, 0.9], [0.52, 0.52], color=INK_BROWN, alpha=0.3, linewidth=0.6)
    ax.text(0.25, 0.42, f"{stats['n_active']}\nACTIVE",
            ha="center", weight="bold", fontsize=10, color=FIRE_ACTIVE)
    ax.text(0.75, 0.42, f"{stats['n_contained']}\nCONTAINED",
            ha="center", weight="bold", fontsize=10, color=FIRE_CONTAINED)
    ax.plot([0.1, 0.9], [0.28, 0.28], color=INK_BROWN, alpha=0.3, linewidth=0.6)
    acres = (
        f"{round(stats['total_acres']):,} TOTAL ACRES"
        if stats["total_acres"] > 0 else "ACRES NOT YET REPORTED"
    )
    ax.text(0.5, 0.20, acres, ha="center", weight="bold", fontsize=10, color=INK_BROWN)
    ax.text(0.5, 0.08, f"Updated {datetime.now():%B %d, %Y %H:%M}",
            ha="center", style="italic", fontsize=7, color=INK_GRAY)


def draw_stat_coverage(ax, stats: dict) -> None:
    _panel(ax)
    year = datetime.now().year
    ax.text(0.5, 0.93, "RESPONSE COVERAGE", ha="center", weight="bold", fontsize=10)
    ax.text(0.5, 0.72, f"{stats['median_dist']} km",
            ha="center", weight="bold", fontsize=26, color=INK_BROWN)
    ax.text(0.5, 0.60, "MEDIAN DISTANCE TO STATION",
            ha="center", fontsize=8, color=INK_GRAY)
    ax.plot([0.1, 0.9], [0.52, 0.52], color=INK_BROWN, alpha=0.3, linewidth=0.6)
    ax.text(0.5, 0.42, f"{stats['n_over_50']} FIRES BEYOND 50KM",
            ha="center", weight="bold", fontsize=10, color=FIRE_ACTIVE)
    ax.text(0.5, 0.32, f"{stats['pct_over_50']}% of all {year} fires",
            ha="center", fontsize=8, color=INK_GRAY)

    r = stats.get("rfpa")
    if r and r["or_gap_fires"] > 0:
        ax.plot([0.1, 0.9], [0.24, 0.24], color=INK_BROWN, alpha=0.3, linewidth=0.6)
        ax.text(0.5, 0.16,
                f"{r['or_gap_in_rfpa']} of {r['or_gap_fires']} OR fires >50km",
                ha="center", weight="bold", fontsize=8.5, color=INK_BROWN)
        ax.text(0.5, 0.08,
                f"inside RFPA coverage ({r['or_gap_in_rfpa_pct']}%)",
                ha="center", fontsize=7.5, color=INK_GRAY)
    else:
        ax.plot([0.1, 0.9], [0.22, 0.22], color=INK_BROWN, alpha=0.3, linewidth=0.6)
        ax.text(0.5, 0.10, "Straight-line, perimeter edge to station",
                ha="center", style="italic", fontsize=7, color=INK_GRAY)


def draw_stat_states(ax, stats: dict) -> None:
    _panel(ax)
    ax.text(0.5, 0.93, "BY STATE", ha="center", weight="bold", fontsize=10)
    lines = []
    for row in stats["by_state"]:
        lines.append(
            f"{row['state'].upper()}\n"
            f"{row['n_fires']} fires  |  {row['n_active']} active  |  "
            f"{format_acres(row['total_acres'])} ac"
        )
    ax.text(0.08, 0.48, "\n\n".join(lines),
            fontsize=8, color=INK_BROWN, va="center", linespacing=1.4)
    year = datetime.now().year
    ax.text(0.5, 0.06, f"CA/OR/WA | {year} season to date",
            ha="center", style="italic", fontsize=7, color=INK_GRAY)


def draw_stat_states_mini(ax, stats: dict) -> None:
    """Compact one-row-per-state strip for building/peak layouts."""
    _panel(ax)
    ax.text(0.5, 0.85, "BY STATE", ha="center", weight="bold", fontsize=9)
    if not stats["by_state"]:
        return
    xs = np.linspace(0.15, 0.85, len(stats["by_state"]))
    for x, row in zip(xs, stats["by_state"]):
        ax.text(x, 0.55, row["state"].upper(),
                ha="center", weight="bold", fontsize=7.5, color=INK_BROWN)
        ax.text(x, 0.35, f"{row['n_fires']} fires",
                ha="center", fontsize=7, color=INK_BROWN)
        ax.text(x, 0.18, f"{format_acres(row['total_acres'])} ac",
                ha="center", fontsize=6.5, color=INK_GRAY)


def draw_stat_stations(ax, stats: dict) -> None:
    _panel(ax)
    ax.text(0.5, 0.95, "MOST BURDENED STATIONS",
            ha="center", weight="bold", fontsize=10)
    if not stats["top_stations"]:
        ax.text(0.5, 0.5, "Not enough fires yet",
                ha="center", style="italic", fontsize=8, color=INK_GRAY)
        return
    lines = []
    for row in stats["top_stations"]:
        tag = f"{row['n_active']} active" if row["n_active"] > 0 else "all contained"
        lines.append(
            f"{row['nearest_station_name'].upper()}\n"
            f"{row['n_fires']} fires  |  {tag}\n"
            f"{format_acres(row['total_acres'])} ac  |  {row['mean_dist']} km avg"
        )
    ax.text(0.05, 0.48, "\n\n".join(lines),
            fontsize=7.5, color=INK_BROWN, va="center", linespacing=1.35)
    ax.text(0.5, 0.03, "Ranked by number of fires as nearest station",
            ha="center", style="italic", fontsize=6.5, color=INK_GRAY)


def draw_inset(ax, states: gpd.GeoDataFrame) -> None:
    ax.set_facecolor(PARCHMENT)
    ax.set_xticks([]); ax.set_yticks([])
    for s in ax.spines.values():
        s.set_edgecolor(INK_BROWN); s.set_linewidth(0.8)
    conus = states[~states["STUSPS"].isin(["AK", "HI", "PR"])]
    conus.plot(ax=ax, facecolor=PARCHMENT_DARK, edgecolor="white", linewidth=0.3)
    wc = states[states["STUSPS"].isin(["CA", "OR", "WA"])]
    wc.plot(ax=ax, facecolor=INK_BROWN, alpha=0.4, edgecolor="white", linewidth=0.4)
    ax.set_xlim(-125, -66); ax.set_ylim(24, 50)


def draw_main_map(
    ax,
    fires: gpd.GeoDataFrame,
    stations: gpd.GeoDataFrame,
    states: gpd.GeoDataFrame,
    counties: gpd.GeoDataFrame,
    rfpa: gpd.GeoDataFrame | None,
) -> None:
    """All map layers plotted in EPSG:5070 (Albers) â€” equal-area, real proportions."""
    ax.set_facecolor(PARCHMENT)
    ax.set_xticks([]); ax.set_yticks([])
    for s in ax.spines.values():
        s.set_visible(False)

    wc_states = states[states["NAME"].isin(STATE_ORDER)].to_crs(WC_CRS)
    if "STATE_NAME" in counties.columns:
        wc_counties = counties[counties["STATE_NAME"].isin(STATE_ORDER)]
    else:
        wc_state_fps = set(states[states["NAME"].isin(STATE_ORDER)]["STATEFP"])
        wc_counties = counties[counties["STATEFP"].isin(wc_state_fps)]
    wc_counties = wc_counties.to_crs(WC_CRS)

    fires_p    = fires.to_crs(WC_CRS)
    stations_p = stations.to_crs(WC_CRS)

    wc_counties.plot(ax=ax, facecolor=PARCHMENT_DARK,
                     edgecolor=INK_BROWN, alpha=0.4, linewidth=0.2)

    # RFPA coverage â€” sits between the county fill and the fire polygons,
    # so it reads as "protected differently" rather than clashing with fires
    if rfpa is not None and len(rfpa) > 0:
        rfpa.to_crs(WC_CRS).plot(
            ax=ax, facecolor=RFPA_FILL, alpha=0.28,
            edgecolor=RFPA_EDGE, linewidth=0.35, zorder=2,
        )

    wc_states.plot(ax=ax, facecolor="none", edgecolor=INK_BLACK, linewidth=1.0, zorder=3)

    minx, miny, maxx, maxy = wc_states.total_bounds
    sta_wc = stations_p.cx[minx:maxx, miny:maxy]
    sta_wc.plot(ax=ax, marker="^", markersize=6, color=INK_BROWN, alpha=0.35)

    contained = fires_p[~fires_p["is_active"]]
    active    = fires_p[fires_p["is_active"]]
    if len(contained):
        contained.plot(ax=ax, facecolor=FIRE_CONTAINED, alpha=0.35,
                       edgecolor=FIRE_CONTAINED_E, linewidth=0.2)
    if len(active):
        active.plot(ax=ax, facecolor=FIRE_ACTIVE, alpha=0.55,
                    edgecolor=FIRE_ACTIVE_EDGE, linewidth=0.3)

    stn_lookup = stations_p.set_index("name")
    label_fires = fires_p.sort_values("acres", ascending=False).head(min(10, len(fires_p)))
    for _, row in label_fires.iterrows():
        if row["dist_nearest_km"] < 25:
            continue
        name = row["nearest_station_name"]
        if name not in stn_lookup.index:
            continue
        stn = stn_lookup.loc[[name]]
        pt = row.geometry.representative_point()
        ax.plot([pt.x, stn.geometry.iloc[0].x],
                [pt.y, stn.geometry.iloc[0].y],
                color=NATGEO_YELLOW_DK, linewidth=0.7,
                linestyle="--", alpha=0.55, zorder=3)

    padx = (maxx - minx) * 0.02
    pady = (maxy - miny) * 0.02
    ax.set_xlim(minx - padx, maxx + padx)
    ax.set_ylim(miny - pady, maxy + pady)
    ax.set_aspect("equal")

    for _, row in wc_states.iterrows():
        c = row.geometry.representative_point()
        ax.text(c.x, c.y, row["NAME"].upper(),
                fontsize=14, weight="bold", color=INK_BROWN, alpha=0.55,
                ha="center", va="center", zorder=4,
                path_effects=[withStroke(linewidth=2.5, foreground=PARCHMENT)])

    texts = []
    for _, row in label_fires.iterrows():
        pt = row.geometry.representative_point()
        active_tag = "  â€¢  ACTIVE" if row["is_active"] else ""
        text = f"{str(row['incident_name']).upper()}\n{format_acres(row['acres'])} ac{active_tag}"
        color = FIRE_ACTIVE if row["is_active"] else INK_BROWN
        t = ax.text(pt.x, pt.y, text, fontsize=6.5, weight="bold", color=color,
                    ha="center", va="center",
                    bbox=dict(facecolor=PARCHMENT, alpha=0.9,
                              edgecolor=INK_BROWN, linewidth=0.4,
                              boxstyle="round,pad=0.25"),
                    zorder=6)
        texts.append(t)

    if HAVE_ADJUSTTEXT and texts:
        adjust_text(
            texts, ax=ax,
            expand=(1.5, 1.8),
            arrowprops=dict(arrowstyle="-", color=INK_BROWN, lw=0.4, alpha=0.7),
            force_text=(0.6, 0.9),
            force_static=(0.3, 0.4),
        )

    # 100 km scale bar in the bottom-left
    scale_m = 100_000
    x0 = minx + (maxx - minx) * 0.03
    y0 = miny + (maxy - miny) * 0.03
    ax.plot([x0, x0 + scale_m], [y0, y0], color=INK_BROWN, linewidth=1.8)
    ax.text(x0 + scale_m / 2, y0 - (maxy - miny) * 0.015, "100 km",
            fontsize=7.5, ha="center", va="top", color=INK_BROWN)


# ---------------------------------------------------------------------------
# Assembly
# ---------------------------------------------------------------------------

def build_figure(
    fires: gpd.GeoDataFrame,
    stations: gpd.GeoDataFrame,
    states: gpd.GeoDataFrame,
    counties: gpd.GeoDataFrame,
    rfpa: gpd.GeoDataFrame | None,
    stats: dict,
) -> plt.Figure:
    fig = plt.figure(figsize=(18, 14), facecolor=PARCHMENT)
    outer = fig.add_gridspec(
        5, 1,
        height_ratios=[0.05, 0.04, 0.028, 0.85, 0.032],
        hspace=0.02,
        left=0.005, right=0.995, top=0.995, bottom=0.005,
    )
    draw_title(fig.add_subplot(outer[0]), datetime.now().year)
    draw_subtitle(fig.add_subplot(outer[1]), stats)
    draw_legend_strip(fig.add_subplot(outer[2]), has_rfpa=(rfpa is not None))

    map_row = outer[3].subgridspec(1, 2, width_ratios=[0.72, 0.28], wspace=0.02)
    draw_main_map(fig.add_subplot(map_row[0]), fires, stations, states, counties, rfpa)

    stage = stats["season_stage"]
    if stage == "early":
        heights = [0.28, 0.28, 0.27, 0.17]
        panels  = ["overview", "coverage", "states", "inset"]
    elif stage == "building":
        heights = [0.24, 0.22, 0.28, 0.11, 0.15]
        panels  = ["overview", "coverage", "stations", "states_mini", "inset"]
    else:   # peak
        heights = [0.22, 0.20, 0.30, 0.11, 0.17]
        panels  = ["overview", "coverage", "stations", "states_mini", "inset"]

    sidebar = map_row[1].subgridspec(len(panels), 1,
                                     height_ratios=heights, hspace=0.08)
    for i, kind in enumerate(panels):
        ax = fig.add_subplot(sidebar[i])
        if kind == "overview":
            draw_stat_overview(ax, stats)
        elif kind == "coverage":
            draw_stat_coverage(ax, stats)
        elif kind == "states":
            draw_stat_states(ax, stats)
        elif kind == "states_mini":
            draw_stat_states_mini(ax, stats)
        elif kind == "stations":
            draw_stat_stations(ax, stats)
        elif kind == "inset":
            draw_inset(ax, states)

    draw_caption(fig.add_subplot(outer[4]))
    return fig


# ---------------------------------------------------------------------------
# I/O
# ---------------------------------------------------------------------------

def write_summary(stats: dict) -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    with SUMMARY_JSON.open("w") as f:
        json.dump(stats, f, indent=2, default=str)
    text = (
        f"{stats['n_total']} fires | "
        f"{round(stats['total_acres']):,} acres | "
        f"{datetime.now():%Y-%m-%d} | "
        f"stage: {stats['season_stage']}"
    )
    SUMMARY_TXT.write_text(text)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fetch", action="store_true",
                    help="Fall back to NIFC directly if fires.geojson is missing")
    args = ap.parse_args()

    _mylog(f"=== YTD build starting @ {datetime.now().isoformat(timespec='seconds')} ===")
    FIGURES_DIR.mkdir(parents=True, exist_ok=True)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    fires_raw = load_fires(allow_fetch=args.fetch)
    _mylog(f"Raw fires: {len(fires_raw)}")

    if len(fires_raw) == 0:
        _mylog("No fires â€” writing empty summary and exiting")
        write_summary(empty_stats())
        return 0

    fires = prep_fires(fires_raw)
    _mylog(f"After CA/OR/WA filter: {len(fires)}")
    if len(fires) == 0:
        write_summary(empty_stats())
        return 0

    stations = load_stations()
    _mylog(f"Stations: {len(stations)}")
    fires = compute_distances(fires, stations)

    rfpa = load_rfpa()
    stats = summarize(fires, rfpa)
    _mylog(
        f"n={stats['n_total']} active={stats['n_active']} "
        f"acres={round(stats['total_acres']):,} median={stats['median_dist']}km "
        f"stage={stats['season_stage']}"
    )
    if stats["rfpa"]:
        r = stats["rfpa"]
        _mylog(
            f"RFPA: {r['or_gap_in_rfpa']}/{r['or_gap_fires']} "
            f"({r['or_gap_in_rfpa_pct']}%) of Oregon >50km fires inside RFPA coverage"
        )
    write_summary(stats)

    states, counties = load_boundaries()
    fig = build_figure(fires, stations, states, counties, rfpa, stats)
    fig.savefig(PNG_PATH, dpi=150, bbox_inches="tight", facecolor=PARCHMENT)
    plt.close(fig)
    _mylog(f"Wrote {PNG_PATH} ({PNG_PATH.stat().st_size / 1024:.0f} KB)")
    _mylog("=== Done ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
