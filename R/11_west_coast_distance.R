# =============================================================================
# 11_west_coast_distance.R
# Calculate distances from wildfire perimeter edges to nearest fire stations
#
# Smart radius approach used instead of full matrix:
#   Full matrix:  ~3,600 fires x ~3,700 stations = 13M calculations
#   Smart radius: only compare fires to stations within 150km search radius
#   Reduces calculations ~95% with no meaningful accuracy loss
#   Falls back to all stations if no stations found within radius
#
# Runtime: 20-40 minutes first run
# Results saved to RDS baseline for fast reload on subsequent runs
#
# Depends on: 01_setup.R, 07-10 west coast scripts
# =============================================================================

# Safety check - ensure dependencies are loaded
if (!exists("target_crs")) {
  message("Running dependency scripts first...")
  source("R/01_setup.R")
  source("R/07_west_coast_setup.R")
}

# ---------------------------------------------------------------------------
# Helper: distance calculation with smart radius
# ---------------------------------------------------------------------------
calculate_distances_smart <- function(fires, stations,
                                      search_radius_km = 150,
                                      n_nearest        = 5) {
  search_radius_m <- search_radius_km * 1000
  n_fires         <- nrow(fires)
  results         <- vector("list", n_fires)
  
  message("Calculating distances for ", n_fires, " fires",
          " (radius = ", search_radius_km, "km)...")
  
  for (i in seq_len(n_fires)) {
    
    if (i %% 100 == 0 || i == n_fires) {
      message("  Fire ", i, " of ", n_fires,
              " (", round(i / n_fires * 100), "%)")
    }
    
    # Only calculate distances to stations within search radius
    fire_buffer     <- st_buffer(fires[i, ], search_radius_m)
    nearby_stations <- stations[
      st_intersects(stations, fire_buffer, sparse = FALSE)[, 1], ]
    
    # Fallback: use all stations if none found within radius
    # (handles very remote fires like eastern Malheur County)
    if (nrow(nearby_stations) == 0) {
      message("  No stations within ", search_radius_km,
              "km for fire ", i, " - using all stations")
      nearby_stations <- stations
    }
    
    dists   <- st_distance(fires[i, ], nearby_stations)
    top_idx <- order(dists)[1:min(n_nearest, nrow(nearby_stations))]
    
    results[[i]] <- tibble(
      nearest_station_name  = nearby_stations$name[top_idx[1]],
      nearest_station_state = nearby_stations$state[top_idx[1]],
      dist_nearest_m        = as.numeric(dists[top_idx[1]]),
      dist_nearest_km       = as.numeric(dists[top_idx[1]]) / 1000,
      # Top 5 nearest stored as list column for later use
      top5 = list(tibble(
        rank         = seq_along(top_idx),
        station_name = nearby_stations$name[top_idx],
        dist_km      = round(as.numeric(dists[top_idx]) / 1000, 1)
      ))
    )
  }
  
  bind_rows(results)
}

# ---------------------------------------------------------------------------
# Run distance analysis
# ---------------------------------------------------------------------------
message("Starting distance analysis (est. 20-40 minutes)...")
start_time <- Sys.time()

dist_results_wc <- calculate_distances_smart(
  fires            = fires_wc_clean,
  stations         = all_stations_wc_proj,
  search_radius_km = 150,
  n_nearest        = 5
)

end_time <- Sys.time()
cat("Distance analysis complete in",
    round(difftime(end_time, start_time, units = "mins"), 1),
    "minutes\n")

# Attach distance results to fire polygons
fires_wc_with_dist <- bind_cols(fires_wc_clean, dist_results_wc)

# ---------------------------------------------------------------------------
# Summary statistics
# ---------------------------------------------------------------------------
cat("\n--- Overall Distance Summary ---\n")
fires_wc_with_dist %>%
  st_drop_geometry() %>%
  summarise(
    n_fires         = n(),
    mean_dist_km    = round(mean(dist_nearest_km,   na.rm = TRUE), 1),
    median_dist_km  = round(median(dist_nearest_km, na.rm = TRUE), 1),
    max_dist_km     = round(max(dist_nearest_km,    na.rm = TRUE), 1),
    pct_within_10km = round(mean(dist_nearest_km <= 10) * 100, 1),
    pct_within_25km = round(mean(dist_nearest_km <= 25) * 100, 1),
    pct_within_50km = round(mean(dist_nearest_km <= 50) * 100, 1)
  ) %>%
  as.data.frame() %>%
  print()

cat("\n--- Distance Summary by State ---\n")
fires_wc_with_dist %>%
  st_drop_geometry() %>%
  group_by(attr_POOState) %>%
  summarise(
    n_fires         = n(),
    median_dist_km  = round(median(dist_nearest_km, na.rm = TRUE), 1),
    max_dist_km     = round(max(dist_nearest_km,    na.rm = TRUE), 1),
    total_acres     = comma(sum(attr_IncidentSize,  na.rm = TRUE)),
    pct_within_10km = round(mean(dist_nearest_km <= 10) * 100, 1),
    pct_within_50km = round(mean(dist_nearest_km <= 50) * 100, 1)
  ) %>%
  as.data.frame() %>%
  print()

# ---------------------------------------------------------------------------
# Build fires_summary_df - one row per fire with all derived fields
# This is the main analysis object used by visualization scripts
# ---------------------------------------------------------------------------
fires_summary_df <- fires_wc_with_dist %>%
  st_drop_geometry() %>%
  mutate(
    
    # Size categories
    size_category = case_when(
      attr_IncidentSize <     10 ~ "Micro (<10 ac)",
      attr_IncidentSize <    100 ~ "Small (10-100 ac)",
      attr_IncidentSize <   1000 ~ "Medium (100-1k ac)",
      attr_IncidentSize <  10000 ~ "Large (1k-10k ac)",
      attr_IncidentSize < 100000 ~ "Very Large (10k-100k ac)",
      attr_IncidentSize >= 100000 ~ "Mega (100k+ ac)",
      TRUE ~ "Unknown"
    ),
    size_category = factor(size_category, levels = c(
      "Micro (<10 ac)", "Small (10-100 ac)", "Medium (100-1k ac)",
      "Large (1k-10k ac)", "Very Large (10k-100k ac)", "Mega (100k+ ac)",
      "Unknown"
    )),
    
    # Coverage categories
    coverage_category = case_when(
      dist_nearest_km <  10 ~ "Good (<10 km)",
      dist_nearest_km <  25 ~ "Moderate (10-25 km)",
      dist_nearest_km <  50 ~ "Poor (25-50 km)",
      dist_nearest_km < 100 ~ "Critical (50-100 km)",
      dist_nearest_km >= 100 ~ "Extreme (100+ km)",
      TRUE ~ "Unknown"
    ),
    coverage_category = factor(coverage_category, levels = c(
      "Good (<10 km)", "Moderate (10-25 km)", "Poor (25-50 km)",
      "Critical (50-100 km)", "Extreme (100+ km)", "Unknown"
    )),
    
    # Response time estimates
    # Career dept: 100 km/h, 5 min turnout, 1.3x road factor
    # Volunteer:    80 km/h, 10 min turnout, 1.3x road factor
    # Note: actual times on gravel/two-track roads likely longer
    est_drive_min_career    = round((dist_nearest_km / 100 * 60) * 1.3 + 5,  1),
    est_drive_min_volunteer = round((dist_nearest_km /  80 * 60) * 1.3 + 10, 1),
    
    # Isolation flags
    is_isolated      = dist_nearest_km >= 50,
    is_very_isolated = dist_nearest_km >= 100,
    
    # Season
    season = case_when(
      discovery_month %in% c("Dec", "Jan", "Feb") ~ "Winter",
      discovery_month %in% c("Mar", "Apr", "May") ~ "Spring",
      discovery_month %in% c("Jun", "Jul", "Aug") ~ "Summer",
      discovery_month %in% c("Sep", "Oct", "Nov") ~ "Fall",
      TRUE ~ "Unknown"
    ),
    
    # Clean state label
    state = case_when(
      attr_POOState == "US-CA" ~ "California",
      attr_POOState == "US-OR" ~ "Oregon",
      attr_POOState == "US-WA" ~ "Washington",
      TRUE ~ attr_POOState
    )
  ) %>%
  select(
    fire_name        = attr_IncidentName,
    state,
    state_code       = attr_POOState,
    county           = attr_POOCounty,
    fips             = attr_POOFips,
    year             = discovery_year,
    month            = discovery_month,
    season,
    acres            = attr_IncidentSize,
    size_category,
    cause            = attr_FireCause,
    cause_general    = attr_FireCauseGeneral,
    jurisdiction     = attr_POOJurisdictionalAgency,
    discovery_date,
    containment_date,
    nearest_station  = nearest_station_name,
    station_state    = nearest_station_state,
    dist_km          = dist_nearest_km,
    coverage_category,
    est_drive_min_career,
    est_drive_min_volunteer,
    is_isolated,
    is_very_isolated
  ) %>%
  arrange(desc(acres))

cat("\nSummary dataframe:", nrow(fires_summary_df), 
    "fires x", ncol(fires_summary_df), "columns\n")

# Station burden table - used by visualizations
station_burden_wc <- fires_wc_with_dist %>%
  st_drop_geometry() %>%
  group_by(nearest_station_name, nearest_station_state) %>%
  summarise(
    n_fires      = n(),
    total_acres  = sum(attr_IncidentSize,        na.rm = TRUE),
    mean_acres   = round(mean(attr_IncidentSize, na.rm = TRUE), 1),
    mean_dist_km = round(mean(dist_nearest_km),  1),
    .groups      = "drop"
  ) %>%
  arrange(desc(n_fires))

# County stats - used by choropleth maps
county_stats_wc <- fires_wc_with_dist %>%
  st_drop_geometry() %>%
  group_by(attr_POOFips, attr_POOState) %>%
  summarise(
    n_fires      = n(),
    total_acres  = sum(attr_IncidentSize,        na.rm = TRUE),
    mean_dist_km = round(mean(dist_nearest_km),  1),
    max_dist_km  = round(max(dist_nearest_km),   1),
    .groups      = "drop"
  )

westcoast_map_data <- westcoast_counties %>%
  left_join(county_stats_wc, by = c("GEOID" = "attr_POOFips")) %>%
  mutate(
    n_fires      = replace_na(n_fires,     0),
    total_acres  = replace_na(total_acres, 0),
    has_fires    = n_fires > 0
  )

# ---------------------------------------------------------------------------
# Save baseline RDS - load on future runs to skip distance calculation
#
# To reload quickly without re-running distance analysis:
#   baseline <- readRDS("C:/data/Shapefiles/WestCoast/westcoast_baseline_YYYYMMDD.rds")
#   list2env(baseline, envir = .GlobalEnv)
# ---------------------------------------------------------------------------
saveRDS(
  list(
    fires_wc_with_dist    = fires_wc_with_dist,
    fires_summary_df      = fires_summary_df,
    station_burden_wc     = station_burden_wc,
    county_stats_wc       = county_stats_wc,
    westcoast_map_data    = westcoast_map_data,
    all_stations_wc_clean = all_stations_wc_clean,
    all_stations_wc_proj  = all_stations_wc_proj,
    westcoast_counties    = westcoast_counties,
    westcoast_states      = westcoast_states,
    wc_crs                = wc_crs,
    run_date              = Sys.time()
  ),
  paste0(wc_output_dir, "westcoast_baseline_",
         format(Sys.Date(), "%Y%m%d"), ".rds")
)

cat("Baseline saved - reload with:\n")
cat('baseline <- readRDS("', wc_output_dir, 
    'westcoast_baseline_', format(Sys.Date(), "%Y%m%d"), '.rds")\n',
    sep = "")
cat("list2env(baseline, envir = .GlobalEnv)\n")