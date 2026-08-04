#!/usr/bin/env python3
"""fetch_rfpa.py — Oregon Rangeland Fire Protection Association boundaries.

Writes: data/rfpa_boundaries.geojson

Paging strategy:
  1. Ask the service for the object-ID field name and every object ID.
  2. Fetch geometry in ID-batched chunks. This works on every ArcGIS
     FeatureServer since 10.0 — no dependency on resultOffset, pagination
     support, or geometryPrecision.
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
    log("Discovering RFPA FeatureServer URL from ArcGIS item metadata...", prefix="rfpa")
    r = requests.get(ITEM_INFO_URL, timeout=60)
    r.raise_for_status()
    info = r.json()
    url = info.get("url")
    if not url:
        raise RuntimeError("ArcGIS item exposed no service URL")
    url = url.rstrip("/")
    if not url.endswith("/FeatureServer"):
        url = f"{url}/FeatureServer"
    log(f"Feature service: {url}", prefix="rfpa")
    return url


def get_layer_info(feature_server: str, layer_id: int = 0) -> dict:
    """Get layer metadata: objectIdField, maxRecordCount, etc."""
    r = requests.get(f"{feature_server}/{layer_id}", params={"f": "json"}, timeout=60)
    r.raise_for_status()
    info = r.json()
    if "error" in info:
        raise RuntimeError(f"Layer metadata error: {info['error']}")
    return info


def get_all_object_ids(feature_server: str, layer_id: int = 0) -> tuple[list[int], str]:
    """Return (all_object_ids, objectIdFieldName)."""
    r = requests.get(
        f"{feature_server}/{layer_id}/query",
        params={"where": "1=1", "returnIdsOnly": "true", "f": "json"},
        timeout=120,
    )
    r.raise_for_status()
    data = r.json()
    if "error" in data:
        raise RuntimeError(f"objectIds error: {data['error']}")
    oid_field = data.get("objectIdFieldName", "OBJECTID")
    oids = data.get("objectIds") or []
    return oids, oid_field


def _ring_is_clockwise(ring: list) -> bool:
    s = 0.0
    for i in range(len(ring) - 1):
        s += (ring[i + 1][0] - ring[i][0]) * (ring[i + 1][1] + ring[i][1])
    return s > 0


def _esri_to_shapely(geom):
    if geom is None:
        return None
    if "x" in geom and "y" in geom:
        return Point(geom["x"], geom["y"])
    if "rings" not in geom:
        return None

    outer, inner = [], []
    for ring in geom["rings"]:
        (outer if _ring_is_clockwise(ring) else inner).append(ring)
    if not outer:
        outer = geom["rings"]
        inner = []

    polys = []
    for o in outer:
        op = Polygon(o)
        holes = [
            h for h in inner
            if op.contains(Polygon(h).representative_point())
        ]
        polys.append(Polygon(o, holes=holes))
    return polys[0] if len(polys) == 1 else MultiPolygon(polys)


def fetch_by_ids(feature_server: str, oids: list[int], oid_field: str,
                 layer_id: int = 0, chunk: int = 100) -> gpd.GeoDataFrame:
    """Fetch features by explicit object-ID batches."""
    query_url = f"{feature_server}/{layer_id}/query"
    rows: list[dict] = []
    for i in range(0, len(oids), chunk):
        batch = oids[i:i + chunk]
        params = {
            "objectIds":      ",".join(str(x) for x in batch),
            "outFields":      "*",
            "outSR":          4326,
            "returnGeometry": "true",
            "f":              "json",
        }
        r = requests.get(query_url, params=params, timeout=120)
        if r.status_code != 200:
            log(f"HTTP {r.status_code} on batch starting {batch[0]}: {r.text[:300]}",
                prefix="rfpa")
            r.raise_for_status()
        page = r.json()
        if "error" in page:
            raise RuntimeError(f"ArcGIS error: {page['error']}")
        for f in page.get("features", []):
            shape = _esri_to_shapely(f.get("geometry"))
            if shape is None or shape.is_empty:
                continue
            attrs = dict(f.get("attributes", {}))
            attrs["geometry"] = shape
            rows.append(attrs)
        log(f"batch {i // chunk + 1}: {len(page.get('features', []))} features",
            prefix="rfpa")
    if not rows:
        raise RuntimeError("Zero valid features after ID fetch")
    return gpd.GeoDataFrame(rows, crs=4326)


def normalize_columns(gdf: gpd.GeoDataFrame) -> gpd.GeoDataFrame:
    lc = {c.lower(): c for c in gdf.columns}
    name_col = next(
        (lc[k] for k in
         ["name", "rfpa_name", "association", "rfpa", "assoc_name", "assn_name"]
         if k in lc), None
    )
    acres_col = next(
        (lc[k] for k in
         ["acres", "gis_acres", "gisacres", "shape_area", "shape__area", "sq_miles"]
         if k in lc), None
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
    ap.add_argument("--service", type=str, default=None)
    ap.add_argument("--layer", type=int, default=0)
    args = ap.parse_args()

    service = args.service or discover_feature_service()

    info = get_layer_info(service, args.layer)
    log(f"Layer: {info.get('name', '?')} | type: {info.get('geometryType', '?')} | "
        f"maxRecord: {info.get('maxRecordCount', '?')}", prefix="rfpa")

    oids, oid_field = get_all_object_ids(service, args.layer)
    log(f"Object IDs: {len(oids)} total (field: {oid_field})", prefix="rfpa")
    if not oids:
        raise RuntimeError("No object IDs — layer may be empty or restricted")

    chunk = min(100, int(info.get("maxRecordCount", 100)))
    gdf = fetch_by_ids(service, oids, oid_field, args.layer, chunk=chunk)
    gdf = normalize_columns(gdf)
    log(f"Loaded {len(gdf)} RFPA polygons", prefix="rfpa")
    write_atomic(gdf, args.out)
    log(f"Wrote {args.out}", prefix="rfpa")
    return 0


if __name__ == "__main__":
    sys.exit(main())
