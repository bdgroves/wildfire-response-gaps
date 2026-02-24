# =============================================================================
# 00_run_all.R
# Run the complete analysis from scratch
#
# TX Panhandle:  ~3-5 minutes
# West Coast:    ~1 hour first run (OSM queries + distance analysis)
#                ~30 min subsequent runs (uses cached stations + baseline RDS)
#
# To reload West Coast baseline without re-running distance analysis:
#   baseline <- readRDS("C:/data/Shapefiles/WestCoast/westcoast_baseline_YYYYMMDD.rds")
#   list2env(baseline, envir = .GlobalEnv)
# =============================================================================

# --- TX Panhandle (scripts 01-06) --------------------------------------------
source("R/01_setup.R")
source("R/02_study_area.R")
source("R/03_fire_stations.R")
source("R/04_fire_perimeters.R")
source("R/05_distance_analysis.R")
source("R/06_visualizations.R")

cat("\nTX Panhandle analysis complete\n")

# --- West Coast (scripts 07-13) ----------------------------------------------
source("R/07_west_coast_setup.R")
source("R/08_west_coast_study_area.R")
source("R/09_west_coast_stations.R")
source("R/10_west_coast_perimeters.R")
source("R/11_west_coast_distance.R")
source("R/12_west_coast_viz.R")
source("R/13_west_coast_ytd.R")

cat("\nWest Coast analysis complete\n")
cat("All outputs saved\n")
cat("\nLinkedIn hero images:\n")
cat(" 1. C:/data/Shapefiles/WestCoast/oregon_coverage_crisis_",
    format(Sys.Date(), "%Y%m%d"), ".png\n", sep = "")
cat(" 2. C:/data/Shapefiles/WestCoast/coverage_comparison_",
    format(Sys.Date(), "%Y%m%d"), ".png\n", sep = "")