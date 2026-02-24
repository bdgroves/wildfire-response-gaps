# =============================================================================
# 07_west_coast_setup.R
# West Coast specific setup - CRS, output directory, study area
#
# Note: target_crs changes from 32614 (UTM 14N used for TX Panhandle)
#       to 5070 (NAD83 Conus Albers) - covers all 3 states in a single
#       equal-area projection with meter units
#
# Depends on: 01_setup.R (libraries already loaded)
# =============================================================================

library(ggspatial)  # north arrow and scale bar for maps
library(ggrepel)    # non-overlapping labels
library(cowplot)    # inset map composition
library(maps)       # USA state boundaries for inset

# Install if needed:
# install.packages(c("ggspatial", "ggrepel", "cowplot", "maps"))

# West Coast CRS - NAD83 Conus Albers
# Chosen over UTM because it covers all 3 states accurately
wc_crs <- 5070

# Output directory
wc_output_dir <- "C:/data/Shapefiles/WestCoast/"
dir.create(wc_output_dir, showWarnings = FALSE, recursive = TRUE)

# Bounding box for NIFC API queries
wc_bbox <- "-124.8,32.5,-114.0,49.0"

# Consistent color palette across all West Coast plots
state_colors <- c(
  "California"  = "firebrick",
  "Oregon"      = "steelblue",
  "Washington"  = "forestgreen"
)

# Shared ggplot theme
theme_wildfire <- theme_minimal(base_size = 12) +
  theme(
    plot.title    = element_text(face = "bold", size = 14),
    plot.subtitle = element_text(size = 10, color = "gray40"),
    plot.caption  = element_text(size = 8,  color = "gray50"),
    plot.margin   = margin(10, 15, 10, 15)
  )

# Shared map theme
theme_map <- theme_void() +
  theme(
    plot.title    = element_text(face = "bold", size = 12),
    plot.subtitle = element_text(size = 9, color = "gray40"),
    plot.caption  = element_text(size = 7, color = "gray50"),
    plot.margin   = margin(5, 5, 5, 5),
    legend.title  = element_text(size = 9),
    legend.text   = element_text(size = 8)
  )

cat("West Coast setup complete\n")
cat("CRS:        EPSG", wc_crs, "(NAD83 Conus Albers)\n")
cat("Output dir:", wc_output_dir, "\n")