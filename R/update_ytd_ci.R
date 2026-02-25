# R/update_ytd_ci.R
# Called by GitHub Actions daily at 6am Pacific
# Fetches live YTD fire perimeters from NIFC and saves updated map
# CI-safe: no hardcoded local paths, no baseline RDS dependency

message("=== YTD CI Update Starting ===")
message("Time: ", Sys.time())
message("R version: ", R.version$version.string)

suppressPackageStartupMessages({
  library(sf)
  library(tidyverse)
  library(httr)
  library(jsonlite)
  library(scales)
  library(patchwork)
})

# ----------------------------------------------------------
# 1. CI-safe output paths
# ----------------------------------------------------------
output_dir  <- "output/figures"
summary_dir <- "output"
dir.create(output_dir,  showWarnings = FALSE, recursive = TRUE)
dir.create(summary_dir, showWarnings = FALSE, recursive = TRUE)

# ----------------------------------------------------------
# 2. Fetch YTD perimeters from NIFC
#    FIXED: correct service name and ArcGIS casing in URL
#    OLD: arcgis/.../WFIGS_Incident_Locations_YTD
#    NEW: ArcGIS/.../WFIGS_Interagency_Perimeters_YearToDate
# ----------------------------------------------------------
message("Fetching NIFC YTD data...")

nifc_url <- paste0(
  "https://services3.arcgis.com/T4QMspbfLg3qTGWY/ArcGIS/rest/services/",
  "WFIGS_Interagency_Perimeters_YearToDate/FeatureServer/0/query"
)

# Build the request — geojson returns geometry + attributes together
resp <- httr::GET(
  nifc_url,
  query = list(
    where             = "attr_POOState IN ('US-CA','US-OR','US-WA')",
    outFields         = paste(c(
      "attr_IncidentName",
      "attr_POOState",
      "attr_POOCounty",
      "attr_FireDiscoveryDateTime",
      "attr_IncidentSize",
      "attr_PercentContained",
      "poly_GISAcres",
      "poly_DateCurrent"
    ), collapse = ","),
    f                 = "geojson",
    resultRecordCount = 2000
  ),
  httr::timeout(60)
)

# ----------------------------------------------------------
# 3. Validate response before parsing
#    Check both HTTP status AND body for ArcGIS error object
#    ArcGIS returns HTTP 200 even for errors — must check body
# ----------------------------------------------------------
if (httr::status_code(resp) != 200) {
  stop(sprintf(
    "NIFC API HTTP error: status %d",
    httr::status_code(resp)
  ))
}

raw_text <- httr::content(resp, as = "text", encoding = "UTF-8")

if (grepl('"error"', raw_text)) {
  stop(sprintf(
    "NIFC API returned an error in the response body:\n%s",
    substr(raw_text, 1, 300)
  ))
}

message("API response received, parsing...")

# ----------------------------------------------------------
# 4. Parse and clean
# ----------------------------------------------------------
fires_ytd_raw <- sf::st_read(raw_text, quiet = TRUE)

message(sprintf("Raw records from API: %d", nrow(fires_ytd_raw)))

# Validate we got something
if (nrow(fires_ytd_raw) == 0) {
  message("WARNING: API returned 0 fires for CA/OR/WA")
  message("This is expected early in the year or during low-activity periods")
  message("Writing empty summary and skipping map generation")
  
  writeLines(
    sprintf("0 fires | 0 acres | %s", format(Sys.Date(), "%Y-%m-%d")),
    file.path(summary_dir, "ytd_summary.txt")
  )
  
  message("=== YTD CI Update Complete (no fires) ===")
  quit(status = 0)
}

fires_ytd <- fires_ytd_raw |>
  # Drop empty geometries — these break st_transform
  dplyr::filter(!sf::st_is_empty(geometry)) |>
  # Fix any invalid geometries from the API
  sf::st_make_valid() |>
  dplyr::mutate(
    # Best available acreage — incident size preferred, GIS acres as fallback
    acres = dplyr::coalesce(attr_IncidentSize, poly_GISAcres),
    # Human-readable state names
    state = dplyr::case_when(
      attr_POOState == "US-CA" ~ "California",
      attr_POOState == "US-OR" ~ "Oregon",
      attr_POOState == "US-WA" ~ "Washington",
      TRUE ~ attr_POOState
    ),
    # Clean fire name
    fire_name = dplyr::coalesce(attr_IncidentName, "Unnamed Fire"),
    # Containment as integer for display
    pct_contained = as.integer(attr_PercentContained)
  )

message(sprintf("Clean fires after geometry filter: %d", nrow(fires_ytd)))
message(sprintf("  California: %d", sum(fires_ytd$state == "California")))
message(sprintf("  Oregon:     %d", sum(fires_ytd$state == "Oregon")))
message(sprintf("  Washington: %d", sum(fires_ytd$state == "Washington")))
message(sprintf("  Total acres: %s",
                format(round(sum(fires_ytd$acres, na.rm = TRUE)), big.mark = ",")))

# ----------------------------------------------------------
# 5. Build state background for context
#    Uses maps package — no tigris/Census dependency in CI
# ----------------------------------------------------------
states_bg <- sf::st_as_sf(
  maps::map("state",
            regions = c("california", "oregon", "washington"),
            fill    = TRUE,
            plot    = FALSE
  )
) |>
  sf::st_transform(4326)

# ----------------------------------------------------------
# 6. Build the map
#    Project fires to WGS84 for plotting
# ----------------------------------------------------------
fires_plot <- fires_ytd |> sf::st_transform(4326)

# Color palette consistent with your existing scripts
state_colors <- c(
  "California"  = "#E07B39",
  "Oregon"      = "#2E7D32",
  "Washington"  = "#1565C0"
)

# Total acres label for subtitle
total_acres_label <- format(
  round(sum(fires_ytd$acres, na.rm = TRUE)),
  big.mark = ","
)

p <- ggplot() +
  # State background
  geom_sf(
    data  = states_bg,
    fill  = "#F5F0E1",
    color = "#CCCCCC",
    linewidth = 0.3
  ) +
  # Fire perimeters — sized by acres, colored by state
  geom_sf(
    data         = fires_plot,
    aes(fill = state, color = state),
    alpha        = 0.7,
    linewidth    = 0.3
  ) +
  scale_fill_manual(values  = state_colors) +
  scale_color_manual(values = state_colors) +
  labs(
    title    = sprintf(
      "West Coast Active Fire Perimeters \u2014 %s",
      format(Sys.Date(), "%Y")
    ),
    subtitle = sprintf(
      "%d fires | %s acres | as of %s",
      nrow(fires_ytd),
      total_acres_label,
      format(Sys.Date(), "%B %d, %Y")
    ),
    caption = paste0(
      "Source: NIFC WFIGS Interagency Perimeters YTD  |  ",
      "github.com/bdgroves/wildfire-response-gaps"
    ),
    fill  = NULL,
    color = NULL
  ) +
  theme_minimal(base_size = 11) +
  theme(
    plot.title       = element_text(face = "bold", size = 13),
    plot.subtitle    = element_text(color = "gray40", size = 10),
    plot.caption     = element_text(color = "gray60", size = 8),
    legend.position  = "bottom",
    panel.grid.major = element_line(color = "gray90", linewidth = 0.2),
    panel.grid.minor = element_blank(),
    plot.background  = element_rect(fill = "white", color = NA)
  )

# ----------------------------------------------------------
# 7. Save map
# ----------------------------------------------------------
out_path <- file.path(output_dir, "ytd_natgeo.png")

ggsave(
  out_path,
  p,
  width  = 10,
  height = 12,
  dpi    = 150,
  bg     = "white"
)

message("Saved: ", out_path)
message("File size: ", round(file.size(out_path) / 1024), " KB")

# ----------------------------------------------------------
# 8. Write summary for logging and commit message
# ----------------------------------------------------------
summary_text <- sprintf(
  "%d fires | %s acres | %s",
  nrow(fires_ytd),
  total_acres_label,
  format(Sys.Date(), "%Y-%m-%d")
)

writeLines(
  summary_text,
  file.path(summary_dir, "ytd_summary.txt")
)

message("Summary: ", summary_text)
message("=== YTD CI Update Complete ===")