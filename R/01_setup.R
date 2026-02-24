# =============================================================================
# 01_setup.R
# Load libraries, set global options, define CRS
# Run this first - everything else depends on it
# =============================================================================

library(osmdata)   # OpenStreetMap queries
library(sf)        # Spatial data handling
library(tidyverse) # Data manipulation and plotting
library(tigris)    # US Census boundary files
library(tmap)      # Interactive mapping
library(httr)      # NIFC API requests
library(jsonlite)  # JSON parsing
library(mapview)   # Alternative interactive mapping
library(leaflet)   # Color palettes for mapview
library(patchwork) # Combine ggplots
library(scales)    # Formatted numbers (comma, percent)

options(tigris_use_cache = TRUE)  # Cache Census downloads locally

# UTM Zone 14N - used for all distance calculations (units = meters)
# Good for Texas Panhandle and central US
target_crs <- 32614