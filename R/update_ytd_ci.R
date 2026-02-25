message("=== YTD CI Update Starting ===")
message("Time: ", Sys.time())

suppressPackageStartupMessages({
  library(sf)
  library(tidyverse)
  library(httr)
  library(jsonlite)
  library(scales)
  library(patchwork)
})

# CI-safe output paths
output_dir  <- "output/figures"
summary_dir <- "output"
dir.create(output_dir,  showWarnings = FALSE, recursive = TRUE)
dir.create(summary_dir, showWarnings = FALSE, recursive = TRUE)

# Fetch YTD from NIFC
message("Fetching NIFC YTD data...")

nifc_url <- paste0(
  "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/",
  "WFIGS_Incident_Locations_YTD/FeatureServer/0/query"
)

resp <- httr::GET(
  nifc_url,
  query = list(
    where             = "attr_POOState IN ('US-CA','US-OR','US-WA')",
    outFields         = paste(c(
      "attr_IncidentName", "attr_POOState", "attr_POOCounty",
      "attr_FireDiscoveryDateTime", "attr_IncidentSize", "poly_GISAcres"
    ), collapse = ","),
    f                 = "geojson",
    resultRecordCount = 2000
  ),
  httr::timeout(60)
)

if (httr::status_code(resp) != 200) {
  stop(sprintf("NIFC API returned status %d", httr::status_code(resp)))
}

fires_ytd <- sf::st_read(
  httr::content(resp, as = "text", encoding = "UTF-8"),
  quiet = TRUE
) |>
  dplyr::filter(!sf::st_is_empty(geometry)) |>
  dplyr::mutate(
    acres = dplyr::coalesce(attr_IncidentSize, poly_GISAcres),
    state = dplyr::case_when(
      attr_POOState == "US-CA" ~ "California",
      attr_POOState == "US-OR" ~ "Oregon",
      attr_POOState == "US-WA" ~ "Washington",
      TRUE ~ attr_POOState
    )
  )

message(sprintf("Fetched %d YTD fires", nrow(fires_ytd)))

# Build map
p <- ggplot(sf::st_transform(fires_ytd, 4326)) +
  geom_sf(aes(color = state), size = 2.5, alpha = 0.8) +
  scale_color_manual(values = c(
    "California" = "#E07B39",
    "Oregon"     = "#2E7D32",
    "Washington" = "#1565C0"
  )) +
  labs(
    title    = sprintf("West Coast Active Fires - YTD %s", format(Sys.Date(), "%Y")),
    subtitle = sprintf("%d fires as of %s",
                       nrow(fires_ytd),
                       format(Sys.Date(), "%B %d, %Y")),
    caption  = "Source: NIFC WFIGS API | bdgroves/wildfire-response-gaps",
    color    = NULL
  ) +
  theme_minimal(base_size = 11) +
  theme(
    plot.title      = element_text(face = "bold"),
    legend.position = "bottom"
  )

out_path <- file.path(output_dir, "ytd_natgeo.png")
ggsave(out_path, p, width = 10, height = 12, dpi = 150, bg = "white")
message("Saved: ", out_path)

# Write summary for logging
writeLines(
  sprintf("%d fires | %s acres | %s",
          nrow(fires_ytd),
          format(round(sum(fires_ytd$acres, na.rm = TRUE)), big.mark = ","),
          format(Sys.Date(), "%Y-%m-%d")),
  file.path(summary_dir, "ytd_summary.txt")
)

message("=== YTD CI Update Complete ===")
