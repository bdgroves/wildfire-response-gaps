# =============================================================================
# 13_west_coast_ytd.R
# Current fire season - Year to Date analysis
#
# Designed to be re-run anytime during fire season for live picture
# Includes ALL perimeter types - final perimeters rare for active fires
#
# Off season behavior: detects no data and exits gracefully
#
# Quick reload after first run (skip distance calculation):
#   baseline <- readRDS("C:/data/Shapefiles/WestCoast/westcoast_baseline_YYYYMMDD.rds")
#   list2env(baseline, envir = .GlobalEnv)
#   source("R/13_west_coast_ytd.R")
#
# Depends on: 07-09 west coast scripts (stations + study area)
# =============================================================================

# Safety check - ensure dependencies are loaded
if (!exists("target_crs")) {
  message("Running dependency scripts first...")
  source("R/01_setup.R")
  source("R/07_west_coast_setup.R")
}

message("Fetching current season fire perimeters from NIFC YTD...")

# Explicit state filter - prevents AZ/NV fires slipping through bbox
fires_ytd_raw <- fetch_nifc_wc_page(
  url          = nifc_ytd_url_wc,
  state_filter = "attr_POOState IN ('US-CA','US-OR','US-WA')",
  bbox_str     = wc_bbox,
  offset       = 0,
  record_count = 1000
)

cat("Raw YTD records returned:", 
    if (is.null(fires_ytd_raw)) 0 else nrow(fires_ytd_raw), "\n")

# ---------------------------------------------------------------------------
# Handle off-season gracefully
# ---------------------------------------------------------------------------
if (is.null(fires_ytd_raw) || nrow(fires_ytd_raw) == 0) {
  
  message("
  ============================================================
  No fires in West Coast YTD dataset
  Expected outside of fire season:
    - Southern California: March/April
    - Oregon/Washington:   June/July
    - Peak season:         July - October
  Re-run this script when fire season starts
  ============================================================
  ")
  
} else {
  
  # Clean YTD fires
  fires_ytd <- fires_ytd_raw %>%
    st_transform(wc_crs) %>%
    st_make_valid() %>%
    st_filter(westcoast_states %>% st_transform(wc_crs)) %>%
    mutate(
      discovery_date   = as.POSIXct(attr_FireDiscoveryDateTime / 1000,
                                    origin = "1970-01-01", tz = "UTC"),
      containment_date = as.POSIXct(attr_ContainmentDateTime / 1000,
                                    origin = "1970-01-01", tz = "UTC"),
      last_updated     = as.POSIXct(poly_DateCurrent / 1000,
                                    origin = "1970-01-01", tz = "UTC"),
      discovery_month  = month(discovery_date, label = TRUE),
      days_burning     = as.numeric(difftime(Sys.time(), discovery_date,
                                             units = "days"))
    )
  
  cat("YTD fires in study area:", nrow(fires_ytd), "\n")
  
  # Distance analysis for YTD fires
  message("Calculating YTD distances...")
  dist_matrix_ytd <- st_distance(fires_ytd, all_stations_wc_proj)
  
  fires_ytd_dist <- fires_ytd %>%
    mutate(
      nearest_station_idx  = apply(dist_matrix_ytd, 1, which.min),
      nearest_station_name = all_stations_wc_clean$name[nearest_station_idx],
      dist_nearest_m       = apply(dist_matrix_ytd, 1, min),
      dist_nearest_km      = as.numeric(dist_nearest_m) / 1000
    )
  
  # Active vs contained
  active_ytd <- fires_ytd_dist %>%
    filter(is.na(attr_PercentContained) | attr_PercentContained < 100)
  
  cat("\n--- Current Season Summary ---\n")
  fires_ytd_dist %>%
    st_drop_geometry() %>%
    summarise(
      n_total        = n(),
      n_active       = sum(is.na(attr_PercentContained) |
                             attr_PercentContained < 100),
      total_acres    = comma(sum(attr_IncidentSize,    na.rm = TRUE)),
      active_acres   = comma(sum(attr_IncidentSize[
        is.na(attr_PercentContained) | attr_PercentContained < 100],
        na.rm = TRUE)),
      median_dist_km = round(median(dist_nearest_km), 1),
      max_dist_km    = round(max(dist_nearest_km),    1)
    ) %>%
    as.data.frame() %>%
    print()
  
  # --- Situation report -------------------------------------------------------
  cat("
╔══════════════════════════════════════════════════════════╗
║  WEST COAST WILDFIRE SITUATION REPORT                    ║")
  cat("║ ", format(Sys.time(), "%Y-%m-%d %H:%M UTC"), "                       ║")
  cat("
╚══════════════════════════════════════════════════════════╝
")
  
  active_ytd %>%
    st_drop_geometry() %>%
    arrange(desc(attr_IncidentSize)) %>%
    select(
      Fire    = attr_IncidentName,
      State   = attr_POOState,
      Acres   = attr_IncidentSize,
      Pct     = attr_PercentContained,
      Station = nearest_station_name,
      Dist_km = dist_nearest_km
    ) %>%
    mutate(Acres = comma(Acres)) %>%
    as.data.frame() %>%
    print()
  
  # Save YTD results
  st_write(
    fires_ytd_dist %>% st_transform(4326),
    paste0(wc_output_dir, "westcoast_ytd_",
           format(Sys.Date(), "%Y%m%d"), ".gpkg"),
    delete_dsn = TRUE
  )
  
  cat("\nYTD results saved to", wc_output_dir, "\n")
  cat("Re-run this script for updated picture\n")
}