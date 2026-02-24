# =============================================================================
# 03_fire_stations.R
# Fetch fire station locations from OpenStreetMap for the TX Panhandle
#
# Notes:
# - OSM uses a bounding box for queries, so we clip precisely to county 
#   boundaries afterward to remove stations in NM, OK, and southern TX
# - OSM returns fire stations as both points AND polygon building footprints
#   Polygons also return all vertex nodes as individual points
# - Solution: keep named points + polygon centroids, drop bare vertex nodes
# - OSM likely undercounts rural/volunteer stations - treat as minimum estimate
#
# Depends on: 01_setup.R, 02_study_area.R
# =============================================================================

# Bounding box slightly larger than panhandle - clipped precisely below
panhandle_bbox <- c(
  xmin = -103.065,  # west
  ymin =  34.300,   # south
  xmax = -100.000,  # east
  ymax =  36.500    # north
)

message("Querying OSM for fire stations (this may take a moment)...")

fire_stations_osm <- opq(bbox = panhandle_bbox) %>%
  add_osm_feature(key = "amenity", value = "fire_station") %>%
  osmdata_sf()

# Named points only - bare polygon vertex nodes have no name
stations_pts <- fire_stations_osm$osm_points %>%
  select(osm_id, name, geometry) %>%
  mutate(source_geom = "point") %>%
  filter(!is.na(name))

# Convert building footprint polygons to centroids
stations_polys <- fire_stations_osm$osm_polygons %>%
  st_centroid() %>%
  select(osm_id, name, geometry) %>%
  mutate(source_geom = "polygon_centroid")

# Combine and clip precisely to panhandle county boundaries
all_stations <- bind_rows(stations_pts, stations_polys) %>%
  st_filter(panhandle_counties_sf %>% st_union())

# Reproject to UTM for distance analysis
all_stations_proj <- all_stations %>%
  st_transform(target_crs)

cat("Fire stations in TX Panhandle:", nrow(all_stations), "\n")