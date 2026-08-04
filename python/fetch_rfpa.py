#!/usr/bin/env python3
"""fetch_rfpa.py — one-shot fetch of Oregon Rangeland Fire Protection
Association boundaries.

RFPA boundaries change slowly (a new association forms maybe once a year), so
this doesn't need a scheduled workflow. Run it locally once, commit the
resulting file, and update it when ODF adjusts a boundary.

Writes: data/rfpa_boundaries.geojson

Usage:
  python python/fetch_rfpa.py

Source:
  Oregon State University GIS Sci — "Oregon Rangeland Protection Associations"
  hosted on ArcGIS Online. Ultimate authority is the Oregon Department of
  Forestry; OSU republishes with attribution.

If ODF publishes a first-party ArcGIS endpoint in the future, swap the URL.
"""
from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

import geopandas as gpd
import requests

from common import RFPA_JSON, log

# ArcGIS Online item: "Oregon Rangeland Protection Associations (2023)"
# The public item page:
#   https://osugisci.maps.arcgis.com/home/item.html?id=291ab6964ed8413caeb6c9af89e1fdf6
# Its item info endpoint gives the FeatureServer URL:
#   https://osugisci.maps.arcgis.com/sharing/rest/content/items/291ab6964ed8413caeb6c9af89e1fdf6?f=json
# Which resolves to the hosted service:
ITEM_INFO_URL = (
    "https://osugisci.maps.arcgis.com/sharing/rest/content/items/"
    "291ab6964ed8413caeb6c9af89e1fdf6?f=json"
)


def discover_feature_service() -> str:
    """Ask ArcGIS Online for the item's live FeatureServer URL, so we don't
    hardcode something that could rotate."""
    log("Discovering RFPA FeatureServer URL from ArcGIS item metadata...",
        prefix="rfpa")
    r = requests.get(ITEM_INFO_URL, timeout=60)
    r.raise_for_status()
    info = r.json()
    url = info.get("url")
    if not url:
        raise RuntimeError(
            "ArcGIS item did not expose a service URL. The item may have been "
            "unpublished. Check the item page in a browser and update this "
            "script with a working alternative source."
        )
    if not url.endswith("/FeatureServer"):
        # ArcGIS sometimes returns the layer URL directly; normalize
        url = url.rstrip("/")
        if not url.endswith("/FeatureServer"):
            url = f"{url}/FeatureServer"
    log(f"Feature service: {url}", prefix="rfpa")
    return url


def fetch_all_features(feature_server: str, layer_id: int = 0) -> dict:
    """Page through the layer, collecting every polygon as GeoJSON."""
    query_url = f"{feature_server}/{layer_id}/query"
    features: list[dict] = []
    offset = 0
    page_size = 500
    while True:
        params = {
            "where":             "1=1",
            "outFields":         "*",
            "f":                 "geojson",
            "outSR":             4326,
            "geometryPrecision": 5,
            "returnGeometry":    "true",
            "resultOffset":      offset,
            "resultRecordCount": page_size,
        }
        r = requests.get(query_url, params=params, timeout=120)
        r.raise_for_status()
        page = r.json()
        feats = page.get("features", [])
        if not feats:
            break
        features.extend(feats)
        log(f"page @offset {offset}: {len(feats)} features", prefix="rfpa")
        if len(feats) < page_size:
            break
        offset += page_size
    return {"type": "FeatureCollection", "features": features}


def normalize_columns(gdf: gpd.GeoDataFrame) -> gpd.GeoDataFrame:
    """Standardize on the two columns the pipeline actually uses (name, acres).
    Everything else stays but isn't required."""
    lc = {c.lower(): c for c in gdf.columns}
    name_col = next((lc[k] for k in ["name", "rfpa_name", "association", "rfpa"] if k in lc), None)
    acres_col = next((lc[k] for k in ["acres", "gis_acres", "gisacres", "shape_area"] if k in lc), None)
    if name_col and name_col != "name":
        gdf = gdf.rename(columns={name_col: "name"})
    if acres_col and acres_col != "acres":
        gdf = gdf.rename(columns={acres_col: "acres"})
    if "name" not in gdf.columns:
        gdf["name"] = [f"RFPA {i}" for i in range(len(gdf))]
    return gdf


def write_atomic(gdf: gpd.GeoDataFrame, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    gdf.to_file(tmp, driver="GeoJSON")
    tmp.replace(path)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=RFPA_JSON,
                    help=f"output geojson (default: {RFPA_JSON})")
    ap.add_argument("--service", type=str, default=None,
                    help="Override FeatureServer URL if the OSU item moves")
    args = ap.parse_args()

    service = args.service or discover_feature_service()
    payload = fetch_all_features(service)
    if not payload["features"]:
        log("Zero features returned — refusing to overwrite an existing file",
            prefix="rfpa")
        return 1
    gdf = gpd.GeoDataFrame.from_features(payload["features"], crs=4326)
    gdf = normalize_columns(gdf)
    log(f"Loaded {len(gdf)} RFPA polygons", prefix="rfpa")
    write_atomic(gdf, args.out)
    log(f"Wrote {args.out}", prefix="rfpa")
    return 0


if __name__ == "__main__":
    sys.exit(main())
