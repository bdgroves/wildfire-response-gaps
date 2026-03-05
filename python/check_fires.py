import requests

url = "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/WFIGS_Interagency_Perimeters_YTD/FeatureServer/0/query"
params = {
    "where": "1=1",
    "outFields": "IncidentName,GISAcres,PercentContained,POOState",
    "geometry": "-124.8,32.5,-114.0,49.0",
    "geometryType": "esriGeometryEnvelope",
    "inSR": "4326",
    "spatialRel": "esriSpatialRelIntersects",
    "f": "json",
    "resultRecordCount": "50"
}
r = requests.get(url, params=params, timeout=30)
features = r.json().get("features", [])
print("Total:", len(features), "fires")
for f in features:
    p = f["attributes"]
    name = (p.get("IncidentName") or "?")[:30]
    acres = p.get("GISAcres") or 0
    state = p.get("POOState") or "?"
    pct = p.get("PercentContained")
    print(f"  {name:30s} | {acres:>10,.0f} ac | {state:6s} | {pct}% contained")
