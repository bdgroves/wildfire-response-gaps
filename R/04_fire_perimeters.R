# =============================================================================
# 04_fire_perimeters.R
# Fetch historical wildfire perimeters from NIFC WFIGS API
#
# Source: WFIGS Interagency Perimeters - All Years
# https://data-nifc.opendata.arcgis.com/
#
# Notes:
# - Queries the REST API directly with TX state filter + panhandle bbox
#   to avoid downloading the entire national dataset
# - NIFC stores timestamps as Unix milliseconds - converted to POSIXct
# - Final perimeters only (not daily snapshots) to avoid double counting
# - 213 TX records fit in one 1000-record page - pagination not needed
#   but the fetch function supports it for future use
#
# Depends on: 01_setup.R, 02_study_area.R
# =============================================================================

nifc_url <- paste0(
  "https://services3.arcgis.com/T4QMspbfLg3qTGWY/ArcGIS/rest/services/",
  "WFIGS_Interagency_Perimeters/FeatureServer/0/query"
)

# -----------------------------------------------------------------------------
# Function to fetch one page of NIFC perimeter data
# Pagination via offset/record_count supports datasets > 1000 records
# -----------------------------------------------------------------------------
fetch_nifc_page <- function(url, offset = 0, record_count = 1000) {
  
  response <- GET(url, query = list(
    where        = "attr_POOState = 'US-TX'",
    outFields    = paste(c(
      "poly_IncidentName",
      "poly_FeatureCategory",
      "poly_GISAcres",
      "attr_IncidentName",
      "attr_POOCounty",
      "attr_POOState",
      "attr_IncidentSize",
      "attr_FireCause",
      "attr_FireCauseGeneral",
      "attr_FireDiscoveryDateTime",
      "attr_ContainmentDateTime",
      "attr_UniqueFireIdentifier",
      "attr_POOFips"
    ), collapse = ","),
    geometry          = "-103.065,34.300,-100.000,36.500",
    geometryType      = "esriGeometryEnvelope",
    spatialRel        = "esriSpatialRelIntersects",
    inSR              = "4326",
    outSR             = "4326",
    returnGeometry    = "true",
    f                 = "geojson",
    resultOffset      = offset,
    resultRecordCount = record_count
  ))
  
  if (status_code(response) != 200) {
    warning("Bad response at offset ", offset, ": ", status_code(response))
    return(NULL)
  }
  
  tryCatch(
    st_read(content(response, as = "text"), quiet = TRUE),
    error = function(e) { warning(e); NULL }
  )
}

message("Fetching historical fire perimeters from NIFC...")
fires_raw <- fetch_nifc_page(nifc_url, offset = 0)
cat("Records returned:", nrow(fires_raw), "\n")

# -----------------------------------------------------------------------------
# Clean and filter to final panhandle perimeters
# -----------------------------------------------------------------------------
fires_clean <- fires_raw %>%
  
  st_make_valid() %>%
  
  # Reproject to UTM Zone 14N for distance analysis
  st_transform(target_crs) %>%
  
  # Clip to panhandle counties
  # (bbox catches some fires just outside the panhandle)
  st_filter(panhandle_counties_sf %>% st_transform(target_crs)) %>%
  
  # Fix timestamps - NIFC stores dates as Unix milliseconds
  mutate(
    discovery_date   = as.POSIXct(attr_FireDiscoveryDateTime / 1000,
                                  origin = "1970-01-01", tz = "UTC"),
    containment_date = as.POSIXct(attr_ContainmentDateTime / 1000,
                                  origin = "1970-01-01", tz = "UTC"),
    discovery_year   = year(discovery_date),
    discovery_month  = month(discovery_date, label = TRUE)
  ) %>%
  
  # Final perimeters only
  # Daily perimeters = snapshots during active fire (same fire multiple times)
  # Final perimeter  = official boundary when fire was contained
  filter(poly_FeatureCategory == "Wildfire Final Fire Perimeter")

cat("Final perimeters in TX Panhandle:", nrow(fires_clean), "\n")

# Quick summary
cat("\n--- Dataset Summary ---\n")
fires_clean %>%
  st_drop_geometry() %>%
  summarise(
    n_fires      = n(),
    year_min     = min(discovery_year, na.rm = TRUE),
    year_max     = max(discovery_year, na.rm = TRUE),
    total_acres  = comma(sum(attr_IncidentSize,    na.rm = TRUE)),
    mean_acres   = round(mean(attr_IncidentSize,   na.rm = TRUE), 1),
    median_acres = round(median(attr_IncidentSize, na.rm = TRUE), 1),
    max_acres    = comma(max(attr_IncidentSize,    na.rm = TRUE))
  ) %>%
  as.data.frame() %>%
  print()