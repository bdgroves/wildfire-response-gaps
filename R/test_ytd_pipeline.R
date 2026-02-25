# =============================================================================
# test_ytd_pipeline.R
# Manual test to verify the YTD NatGeo pipeline works
# Run this anytime to confirm everything is wired up
# =============================================================================

cat("
============================================================
  YTD Pipeline Test
  Testing all components end to end
============================================================
\n")

# --- Test 1: Setup loads cleanly -------------------------------------------
cat("TEST 1: Setup scripts...\n")
tryCatch({
  source("R/01_setup.R")
  source("R/07_west_coast_setup.R")
  cat("  PASS: Setup loaded\n")
}, error = function(e) {
  cat("  FAIL:", e$message, "\n")
})

# --- Test 2: Baseline loads ------------------------------------------------
cat("\nTEST 2: Baseline RDS...\n")
tryCatch({
  baseline_files <- list.files(wc_output_dir,
                               pattern = "westcoast_baseline.*\\.rds$",
                               full.names = TRUE)
  if (length(baseline_files) == 0) {
    cat("  FAIL: No baseline RDS found in", wc_output_dir, "\n")
  } else {
    latest <- sort(baseline_files, decreasing = TRUE)[1]
    baseline <- readRDS(latest)
    list2env(baseline, envir = .GlobalEnv)
    cat("  PASS: Loaded", latest, "\n")
    cat("  fires_summary_df:", nrow(fires_summary_df), "rows\n")
    cat("  fires_wc_with_dist:", nrow(fires_wc_with_dist), "rows\n")
    cat("  stations:", nrow(all_stations_wc_clean), "\n")
  }
}, error = function(e) {
  cat("  FAIL:", e$message, "\n")
})

# --- Test 3: Fetch function exists -----------------------------------------
cat("\nTEST 3: Fetch function...\n")
tryCatch({
  source("R/10_west_coast_perimeters.R")
  if (exists("fetch_nifc_wc_page")) {
    cat("  PASS: fetch_nifc_wc_page loaded\n")
  } else {
    cat("  FAIL: Function not found after sourcing script 10\n")
  }
}, error = function(e) {
  cat("  FAIL:", e$message, "\n")
})

# --- Test 4: NIFC API responds ---------------------------------------------
cat("\nTEST 4: NIFC YTD API...\n")
tryCatch({
  test_url <- paste0(
    "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/",
    "WFIGS_Interagency_Perimeters/FeatureServer/0/query",
    "?where=1%3D1&returnCountOnly=true&f=json"
  )
  resp <- httr::GET(test_url, httr::timeout(15))
  if (httr::status_code(resp) == 200) {
    count <- jsonlite::fromJSON(httr::content(resp, "text", encoding = "UTF-8"))$count
    cat("  PASS: API responded. YTD perimeters available:", count, "\n")
  } else {
    cat("  WARN: API returned status", httr::status_code(resp), "\n")
  }
}, error = function(e) {
  cat("  FAIL:", e$message, "\n")
  cat("  (API may be temporarily down - try again later)\n")
})

# --- Test 5: YTD data fetch ------------------------------------------------
cat("\nTEST 5: YTD data fetch...\n")
tryCatch({
  if (exists("fires_ytd_dist")) rm(fires_ytd_dist)
  source("R/13_west_coast_ytd.R")
  
  if (exists("fires_ytd_dist") && !is.null(fires_ytd_dist) &&
      nrow(fires_ytd_dist) > 0) {
    cat("  PASS:", nrow(fires_ytd_dist), "YTD fires fetched\n")
    
    # Check acreage columns
    has_gis_acres <- "poly_GISAcres" %in% names(fires_ytd_dist)
    has_inc_size  <- "attr_IncidentSize" %in% names(fires_ytd_dist)
    cat("  poly_GISAcres column:", has_gis_acres, "\n")
    cat("  attr_IncidentSize column:", has_inc_size, "\n")
    
    # Test acreage coalesce
    test_acres <- fires_ytd_dist %>%
      st_drop_geometry() %>%
      mutate(
        acres = coalesce(na_if(attr_IncidentSize, 0), poly_GISAcres, 0)
      )
    cat("  Acreage coalesce works. Total acres:",
        round(sum(test_acres$acres, na.rm = TRUE), 1), "\n")
    
    # Show sample
    cat("\n  Sample fires:\n")
    test_acres %>%
      select(attr_IncidentName, attr_IncidentSize,
             poly_GISAcres, acres) %>%
      head(5) %>%
      as.data.frame() %>%
      print()
    
  } else {
    cat("  INFO: No YTD fires returned (expected off-season)\n")
    cat("  Pipeline will work when fire season starts\n")
  }
}, error = function(e) {
  cat("  FAIL:", e$message, "\n")
})

# --- Test 6: NatGeo map builds ---------------------------------------------
cat("\nTEST 6: NatGeo YTD map build...\n")
if (exists("fires_ytd_dist") && !is.null(fires_ytd_dist) &&
    nrow(fires_ytd_dist) > 0) {
  tryCatch({
    source("R/19_ytd_natgeo.R")
    out <- paste0(wc_output_dir, "ytd_natgeo_",
                  format(Sys.Date(), "%Y%m%d"), ".png")
    if (file.exists(out)) {
      file_size <- round(file.size(out) / 1024 / 1024, 1)
      cat("  PASS: Map saved (", file_size, "MB)\n")
      cat("  File:", out, "\n")
    } else {
      cat("  FAIL: Map file not created\n")
    }
  }, error = function(e) {
    cat("  FAIL:", e$message, "\n")
  })
} else {
  cat("  SKIP: No YTD data to map\n")
}

# --- Test 7: Output files exist --------------------------------------------
cat("\nTEST 7: Output files...\n")
expected_files <- c(
  "output/figures/oregon_natgeo.png",
  "output/figures/oregon_coverage_gap.png",
  "output/figures/oregon_comparison_bar.png",
  "output/figures/oregon_frenchglen_zoom.png",
  "output/figures/oregon_distance_histogram.png",
  "output/figures/west_coast_combined.png",
  "output/figures/ytd_natgeo.png"
)

for (f in expected_files) {
  if (file.exists(f)) {
    cat("  PASS:", f, "\n")
  } else {
    cat("  MISSING:", f, "\n")
  }
}

# --- Summary ----------------------------------------------------------------
cat("\n
============================================================
  Pipeline Test Complete
  
  If all tests passed, your fire season workflow is:
  
    source(\"R/19_ytd_natgeo.R\")
  
  Then git add/commit/push to update the README image.
============================================================
\n")