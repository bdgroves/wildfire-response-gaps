# =============================================================================
# 00_run_all.R
# Run the complete analysis from scratch
# Expected runtime: 2-3 minutes (API calls are the slow part)
# =============================================================================

source("R/01_setup.R")
source("R/02_study_area.R")
source("R/03_fire_stations.R")
source("R/04_fire_perimeters.R")
source("R/05_distance_analysis.R")
source("R/06_visualizations.R")

cat("\nAnalysis complete!\n")
cat("Figures saved to output/figures/\n")