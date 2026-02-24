# =============================================================================
# 05_distance_analysis.R
# Calculate distances from wildfire perimeter edges to nearest fire stations
#
# Notes:
# - Uses perimeter EDGE distance not centroid - more realistic for large fires
#   A station near the edge of a 100k acre fire is far more relevant than
#   one near the centroid
# - st_distance() returns a matrix: rows = fires, cols = stations
# - Units are meters (UTM Zone 14N)
#
# Depends on: 01_setup.R, 03_fire_stations.R, 04_fire_perimeters.R
# =============================================================================

message("Calculating distance matrix (", nrow(fires_clean), 
        " fires x ", nrow(all_stations_proj), " stations)...")

dist_matrix <- st_distance(fires_clean, all_stations_proj)

cat("Distance matrix dimensions:", 
    nrow(dist_matrix), "fires x", ncol(dist_matrix), "stations\n")

# --- Attach nearest station info to each fire --------------------------------
fires_with_dist <- fires_clean %>%
  mutate(
    nearest_station_idx  = apply(dist_matrix, 1, which.min),
    nearest_station_name = all_stations$name[nearest_station_idx],
    dist_nearest_m       = apply(dist_matrix, 1, min),
    dist_nearest_km      = as.numeric(dist_nearest_m) / 1000
  )

# --- Summary statistics ------------------------------------------------------
cat("\n--- Distance Summary ---\n")
fires_with_dist %>%
  st_drop_geometry() %>%
  summarise(
    mean_dist_km     = round(mean(dist_nearest_km),            1),
    median_dist_km   = round(median(dist_nearest_km),          1),
    min_dist_km      = round(min(dist_nearest_km),             1),
    max_dist_km      = round(max(dist_nearest_km),             1),
    sd_dist_km       = round(sd(dist_nearest_km),              1),
    pct_within_10km  = round(mean(dist_nearest_km <= 10) * 100, 1),
    pct_within_25km  = round(mean(dist_nearest_km <= 25) * 100, 1),
    pct_within_50km  = round(mean(dist_nearest_km <= 50) * 100, 1)
  ) %>%
  as.data.frame() %>%
  print()

# --- Station burden analysis -------------------------------------------------
cat("\n--- Station Burden (fires + acres) ---\n")
fires_with_dist %>%
  st_drop_geometry() %>%
  group_by(nearest_station_name) %>%
  summarise(
    n_fires     = n(),
    total_acres = comma(sum(attr_IncidentSize, na.rm = TRUE)),
    mean_acres  = round(mean(attr_IncidentSize, na.rm = TRUE), 1),
    max_acres   = comma(max(attr_IncidentSize, na.rm = TRUE)),
    mean_dist   = round(mean(dist_nearest_km), 1)
  ) %>%
  arrange(desc(n_fires)) %>%
  as.data.frame() %>%
  print()

# --- County level summary ----------------------------------------------------
county_fire_stats <- fires_with_dist %>%
  st_drop_geometry() %>%
  group_by(attr_POOCounty) %>%
  summarise(
    n_fires      = n(),
    total_acres  = sum(attr_IncidentSize, na.rm = TRUE),
    mean_dist_km = round(mean(dist_nearest_km), 1),
    max_dist_km  = round(max(dist_nearest_km),  1)
  )

# Join stats back to county spatial data for mapping
panhandle_with_stats <- panhandle_counties_sf %>%
  left_join(county_fire_stats, by = c("NAME" = "attr_POOCounty")) %>%
  mutate(
    n_fires      = replace_na(n_fires, 0),
    total_acres  = replace_na(total_acres, 0),
    mean_dist_km = replace_na(mean_dist_km, NA_real_)
  )