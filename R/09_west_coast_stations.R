# =============================================================================
# 09_west_coast_stations.R
# Fetch fire station locations from OSM for CA, OR, and WA
#
# Notes:
# - Queries each state separately to avoid OSM server timeouts
# - Results cached locally - OSM query only runs once
#   Cache file: wc_output_dir/fire_stations_westcoast_osm.gpkg
# - Retry logic built in - OSM occasionally returns server errors
# - Two non-suppression OSM entries excluded after manual review:
#     1. Wallowa Lake Fire Station     - seasonal campground/state park
#     2. NE WA Interagency Comms Center - comms center, not a station
# - OSM undercounts rural volunteer/RFPA stations - treat as minimum
#
# Depends on: 01_setup.R, 07_west_coast_setup.R, 08_west_coast_study_area.R
# =============================================================================

# Safety check - ensure dependencies are loaded
if (!exists("target_crs")) {
  message("Running dependency scripts first...")
  source("R/01_setup.R")
  source("R/07_west_coast_setup.R")
}

stations_cache_file <- paste0(wc_output_dir, 
                              "fire_stations_westcoast_osm.gpkg")

if (file.exists(stations_cache_file)) {
  
  message("Loading fire stations from cache...")
  all_stations_wc <- st_read(stations_cache_file, quiet = TRUE)
  cat("Stations loaded from cache:", nrow(all_stations_wc), "\n")
  
} else {
  
  message("Querying OSM for fire stations (10-20 minutes)...")
  
  # ---------------------------------------------------------------------------
  # Helper: fetch stations for one state with retry logic
  # ---------------------------------------------------------------------------
  fetch_stations_for_state <- function(state_name, state_sf) {
    
    message("  Querying ", state_name, "...")
    bb <- st_bbox(state_sf %>% filter(NAME == state_name))
    
    run_query <- function() {
      osm <- opq(bbox = as.numeric(bb), timeout = 120) %>%
        add_osm_feature(key = "amenity", value = "fire_station") %>%
        osmdata_sf()
      
      pts <- osm$osm_points %>%
        select(osm_id, name, geometry) %>%
        mutate(source_geom = "point", state = state_name) %>%
        filter(!is.na(name))
      
      polys <- osm$osm_polygons %>%
        st_centroid() %>%
        select(osm_id, name, geometry) %>%
        mutate(source_geom = "polygon_centroid", state = state_name)
      
      bind_rows(pts, polys)
    }
    
    tryCatch(
      run_query(),
      error = function(e) {
        message("  Failed for ", state_name, ": ", e$message)
        message("  Retrying in 30 seconds...")
        Sys.sleep(30)
        tryCatch(
          run_query(),
          error = function(e2) {
            message("  Retry failed for ", state_name, ": ", e2$message)
            NULL
          }
        )
      }
    )
  }
  
  # Run queries for all three states
  state_stations <- map(
    c("California", "Oregon", "Washington"),
    ~fetch_stations_for_state(.x, westcoast_states)
  )
  
  all_stations_wc <- bind_rows(state_stations) %>%
    filter(!is.na(name)) %>%
    st_filter(westcoast_states %>% st_union())
  
  cat("Total stations found:", nrow(all_stations_wc), "\n")
  
  # Cache results - avoids re-querying OSM on subsequent runs
  st_write(all_stations_wc, stations_cache_file, delete_dsn = TRUE)
  message("Stations cached to: ", stations_cache_file)
}

# --- Remove non-fire-suppression entries identified during manual review -----
stations_to_exclude <- c(
  "Wallowa Lake Fire Station",                        # seasonal campground
  "Northeast Washington Interagency Communications Center"  # comms only
)

all_stations_wc_clean <- all_stations_wc %>%
  filter(!name %in% stations_to_exclude)

# Projected version for distance analysis
all_stations_wc_proj <- all_stations_wc_clean %>%
  st_transform(wc_crs)

cat("Total stations:   ", nrow(all_stations_wc),       "\n")
cat("After exclusions: ", nrow(all_stations_wc_clean), "\n")
cat("Excluded:         ", paste(stations_to_exclude, collapse = ", "), "\n")