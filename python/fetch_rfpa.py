#!/usr/bin/env python3
"""fetch_rfpa.py — one-shot fetch of Oregon Rangeland Fire Protection
Association boundaries.

RFPA boundaries change slowly (a new association forms maybe once a year), so
this doesn't need a scheduled workflow. Run it locally once, commit the
resulting file, and update it when ODF adjusts a boundary.

Writes: data/rfpa_boundaries.geojson

Source:
  Oregon State University GIS Sci — "Oregon Rangeland Protection Associations"
  hosted on ArcGIS Online. The underlying authority is the Oregon Department
  of Forestry; OSU republishes with attribution.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import geopandas as gpd
import requests
from shapely.geometry import Polygon, MultiPolygon, Point

from common import RFPA_JSON, log

ITEM_INFO_URL = (
    "https://osugisci.maps.arcgis.com/sharing/rest/content/items/"
    "291ab6964ed8413caeb6c9af89e1fdf6?f=json"
)


def discover_feature_service() -> str:
    log("Discovering RFPA FeatureServer URL from ArcGIS item metadata...",
        prefix="rfpa")
    r = requests.get(ITEM_INFO_URL, timeout=60)
    r.raise_for_status()
    info = r.json()
    url = info.get("url")
    if not url:
        raise RuntimeError(
            "ArcGIS item did not expose a service URL. The item may have been "
            "unpublished. Update this script with an alternative source."
        )
    url = url.rstrip("/")
    if not url.endswith("/FeatureServer"):
        url = f"{url}/FeatureServer"
    log(f"Feature service: {url}", prefix="rfpa")
    return url


def _ring_is_clockwise(ring: list) -> bool:
    """Shoelace formula. Positive area = clockwise in an x-east / y-north
    coordinate system (which is what lon/lat is)."""
    s = 0.0
    for i in range(len(ring) - 1):
        s += (ring[i + 1][0] - ring[i][0]) * (ring[i + 1][1] + ring[i][1])
    return s > 0


def _esri_to_shapely(geom: dict):
    """Convert Esri JSON geometry to a Shapely geometry.
    Handles the outer/inner ring convention flip between Esri (CW outer)
    and GeoJSON/Shapely (CCW outer)."""
    if geom is None:
        return None
    if "x" in geom and "y" in geom:
        return Point(geom["x"], geom["y"])
    if "rings" not in geom:
        return None

    outer_rings, inner_rings = [], []
    for ring in geom["rings"]:
        (outer_rings if _ring_is_clockwise(ring) else inner_rings).append(ring)

    # Defensive: if nothing identified as outer, treat all as outer
    if not outer_rings:
        outer_rings = geom["rings"]
        inner_rings = []

    polygons = []
    for outer in outer_rings:
        outer_poly = Polygon(outer)
        my_holes = [
            inner for inner in inner_rings
            if outer_poly.contains(Polygon(inner).representative_point())
        ]
        polygons.append(Polygon(outer, holes=my_holes))

    if len(polygons) == 1:
        return polygons[0]
    return MultiPolygon(polygons)


def fetch_all_features(feature_server: str, layer_id: int = 0) -> gpd.GeoDataFrame:
    """Page through the layer using f=json (universally supported by ArcGIS
    FeatureServers), converting to Shapely as we go."""
    query_url = f"{feature_server}/{layer_id}/query"
    rows: list[dict] = []
    offset = 0
    page_size = 500

    while True:
        params = {
            "where":             "1=1",
            "outFields":         "*",
            "f":                 "json",
            "outSR":             4326,
            "geometryPrecision": 5,
            "returnGeometry":    "true",
            "resultOffset":      offset,
            "resultRecordCount": page_size,
        }
        r = requests.get(query_url, params=params, timeout=120)
        if r.status_code != 200:
            log(f"HTTP {r.status_code}: {r.text[:400]}", prefix="rfpa")
            r.raise_for_status()
        page = r.json()
        if "error" in page:
            raise RuntimeError(f"ArcGIS error: {page['error']}")

        feats = page.get("features", [])
        if not feats:
            break

        for f in feats:
            shape = _esri_to_shapely(f.get("geometry"))
            if shape is None or shape.is_empty:
                continue
            attrs = dict(f.get("attributes", {}))
            attrs["geometry"] = shape
            rows.append(attrs)

        log(f"page @offset {offset}: {len(feats)} features", prefix="rfpa")
        if len(feats) < page_size:
            break
        offset += page_size

    if not rows:
        raise RuntimeError("Zero features returned by the service")
    return gpd.GeoDataFrame(rows, crs=4326)


def normalize_columns(gdf: gpd.GeoDataFrame) -> gpd.GeoDataFrame:
    lc = {c.lower(): c for c in gdf.columns}
    name_col = next(
        (lc[k] for k in ["name", "rfpa_name", "association", "rfpa", "assoc_name"] if k in lc),
        None,
    )
    acres_col = next(
        (lc[k] for k in ["acres", "gis_acres", "gisacres", "shape_area", "shape__area"] if k in lc),
        None,
    )
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
    ap.add_argument("--out", type=Path, default=RFPA_JSON)
    ap.add_argument("--service", type=str, default=None,
                    help="Override FeatureServer URL")
    args = ap.parse_args()

    service = args.service or discover_feature_service()
    gdf = fetch_all_features(service)
    gdf = normalize_columns(gdf)
    log(f"Loaded {len(gdf)} RFPA polygons", prefix="rfpa")
    write_atomic(gdf, args.out)
    log(f"Wrote {args.out}", prefix="rfpa")
    return 0


if __name__ == "__main__":
    sys.exit(main())
