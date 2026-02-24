# =============================================================================
# 10_west_coast_perimeters.R
# Fetch and clean historical fire perimeters for CA, OR, WA from NIFC WFIGS
#
# Notes:
# - Paginated fetch handles datasets > 1000 records
# - Retry logic handles HTTP/2 stream errors from ESRI servers
# - Smaller page size (500) reduces connection timeout risk
# - Type coercion applied per page before binding to handle ESRI
#   inconsistency where attr_PercentContained returns as integer
#   on some pages and character on others
# - Final perimeters only to avoid double counting active fires
# - Adds jurisdiction field - useful for OR federal lands analysis
#
# Depends on: 01_setup.R, 07_west_coast_setup.R, 08_west_coast_study_area.R
# =============================================================================

if (!exists("westcoast_states")) {
  message("Running dependency scripts first...")
  source("R/01_setup.R")
  source("R/07_west_coast_setup.R")
  source("R/08_west_coast_study_area.R")
}

nifc_url_wc <- paste0(
  "https://services3.arcgis.com/T4QMspbfLg3qTGWY/ArcGIS/rest/services/",
  "WFIGS_Interagency_Perimeters/FeatureServer/0/query"
)

nifc_ytd_url_wc <- paste0(
  "https://services3.arcgis.com/T4QMspbfLg3qTGWY/ArcGIS/rest/services/",
  "WFIGS_Interagency_Perimeters_YearToDate/FeatureServer/0/query"
)

# ---------------------------------------------------------------------------
# Helper: fetch one page with retry logic
# Handles HTTP/2 framing errors via progressive backoff
# ---------------------------------------------------------------------------
fetch_nifc_wc_page <- function(url, state_filter, bbox_str,
                               offset       = 0,
                               record_count = 500,
                               max_retries  = 3) {
  for (attempt in seq_len(max_retries)) {
    
    tryCatch({
      
      response <- GET(
        url,
        query = list(
          where        = state_filter,
          outFields    = paste(c(
            "poly_IncidentName", "poly_FeatureCategory",
            "poly_GISAcres",     "poly_DateCurrent",
            "attr_IncidentName", "attr_POOCounty",
            "attr_POOState",     "attr_IncidentSize",
            "attr_FireCause",    "attr_FireCauseGeneral",
            "attr_FireDiscoveryDateTime",
            "attr_ContainmentDateTime",
            "attr_PercentContained",
            "attr_UniqueFireIdentifier",
            "attr_POOFips",
            "attr_POOJurisdictionalAgency"
          ), collapse = ","),
          geometry          = bbox_str,
          geometryType      = "esriGeometryEnvelope",
          spatialRel        = "esriSpatialRelIntersects",
          inSR              = "4326",
          outSR             = "4326",
          returnGeometry    = "true",
          f                 = "geojson",
          resultOffset      = offset,
          resultRecordCount = record_count
        ),
        # Force HTTP/1.1 - prevents HTTP/2 framing layer errors from ESRI
        config = config(http_version = 2)
      )
      
      if (status_code(response) != 200) {
        message("  Bad status ", status_code(response),
                " at offset ", offset,
                " (attempt ", attempt, "/", max_retries, ")")
        if (attempt < max_retries) {
          Sys.sleep(10 * attempt)
          next
        }
        return(NULL)
      }
      
      result <- st_read(content(response, as = "text"), quiet = TRUE)
      return(result)
      
    }, error = function(e) {
      message("  Error at offset ", offset,
              " (attempt ", attempt, "/", max_retries, "): ", e$message)
      if (attempt < max_retries) {
        message("  Waiting ", 15 * attempt, " seconds before retry...")
        Sys.sleep(15 * attempt)
      }
    })
  }
  
  message("  All retries failed at offset ", offset)
  return(NULL)
}

# ---------------------------------------------------------------------------
# Helper: fetch all pages until exhausted
# Coerces inconsistent column types per page before binding
# ESRI sometimes returns attr_PercentContained as integer, sometimes character
# Solution: cast all potentially inconsistent columns to character per page
#           then convert to numeric after all pages are bound
# ---------------------------------------------------------------------------
fetch_nifc_wc_all <- function(url, state_filter, bbox_str,
                              record_count = 500) {
  all_pages  <- list()
  offset     <- 0
  page_count <- 0
  
  # Columns known to have type inconsistency across pages
  coerce_to_char <- c(
    "attr_PercentContained",
    "attr_IncidentSize",
    "attr_FireStrategyConfinePercent",
    "attr_FireStrategyFullSuppPrcnt",
    "attr_FireStrategyMonitorPercent"
  )
  
  repeat {
    message("  Fetching records ", offset + 1,
            " to ", offset + record_count, "...")
    
    page <- fetch_nifc_wc_page(
      url          = url,
      state_filter = state_filter,
      bbox_str     = bbox_str,
      offset       = offset,
      record_count = record_count
    )
    
    if (is.null(page) || nrow(page) == 0) {
      message("  No more records - fetch complete")
      break
    }
    
    # Coerce problem columns to character before storing
    # Prevents bind_rows type conflict errors
    page <- page %>%
      mutate(across(any_of(coerce_to_char), as.character))
    
    all_pages[[length(all_pages) + 1]] <- page
    page_count <- page_count + 1
    cat("  Page", page_count, "returned:", nrow(page), "records",
        "| Running total:", sum(sapply(all_pages, nrow)), "\n")
    
    if (nrow(page) < record_count) break
    
    offset <- offset + record_count
    Sys.sleep(2)
  }
  
  if (length(all_pages) == 0) return(NULL)
  
  # Bind all pages then convert back to numeric
  result <- bind_rows(all_pages) %>%
    mutate(across(any_of(c(
      "attr_PercentContained",
      "attr_IncidentSize"
    )), as.numeric))
  
  cat("Fetch complete:", nrow(result), "total records\n")
  return(result)
}

# ---------------------------------------------------------------------------
# Fetch historical perimeters
# ---------------------------------------------------------------------------
message("Fetching historical fire perimeters from NIFC (paginated)...")
message("500 record pages | retry logic | type coercion enabled")

fires_wc_raw <- fetch_nifc_wc_all(
  url          = nifc_url_wc,
  state_filter = "attr_POOState IN ('US-CA','US-OR','US-WA')",
  bbox_str     = wc_bbox,
  record_count = 500
)

cat("Total raw records returned:", nrow(fires_wc_raw), "\n")

# ---------------------------------------------------------------------------
# Clean and filter to final perimeters only
# ---------------------------------------------------------------------------
fires_wc_clean <- fires_wc_raw %>%
  st_make_valid() %>%
  st_transform(wc_crs) %>%
  st_filter(westcoast_states %>% st_transform(wc_crs)) %>%
  mutate(
    discovery_date   = as.POSIXct(attr_FireDiscoveryDateTime / 1000,
                                  origin = "1970-01-01", tz = "UTC"),
    containment_date = as.POSIXct(attr_ContainmentDateTime / 1000,
                                  origin = "1970-01-01", tz = "UTC"),
    discovery_year   = year(discovery_date),
    discovery_month  = month(discovery_date, label = TRUE)
  ) %>%
  filter(poly_FeatureCategory == "Wildfire Final Fire Perimeter")

cat("Final perimeters after cleaning:", nrow(fires_wc_clean), "\n")

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat("\n--- Fires by State ---\n")
fires_wc_clean %>%
  st_drop_geometry() %>%
  group_by(attr_POOState) %>%
  summarise(
    n_fires     = n(),
    total_acres = comma(sum(attr_IncidentSize, na.rm = TRUE)),
    max_acres   = comma(max(attr_IncidentSize, na.rm = TRUE)),
    year_min    = min(discovery_year, na.rm = TRUE),
    year_max    = max(discovery_year, na.rm = TRUE)
  ) %>%
  as.data.frame() %>%
  print()

cat("\n--- Top 10 Largest Fires ---\n")
fires_wc_clean %>%
  st_drop_geometry() %>%
  select(
    Name   = attr_IncidentName,
    State  = attr_POOState,
    County = attr_POOCounty,
    Acres  = attr_IncidentSize,
    Cause  = attr_FireCause,
    Year   = discovery_year
  ) %>%
  arrange(desc(Acres)) %>%
  head(10) %>%
  as.data.frame() %>%
  print()