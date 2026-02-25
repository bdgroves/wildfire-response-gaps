# R/update_ytd_ci.R
# GitHub Actions daily YTD update
# Produces full NatGeo-style layout matching script 19
# CI-safe: fetches everything live, no baseline RDS needed

message("=== YTD CI Update Starting ===")
message("Time: ", Sys.time())

suppressPackageStartupMessages({
  library(sf)
  library(tidyverse)
  library(httr)
  library(jsonlite)
  library(scales)
  library(cowplot)
  library(ggrepel)
  library(ggspatial)
  library(maps)
})

# ----------------------------------------------------------
# 1. Paths
# ----------------------------------------------------------
output_dir  <- "output/figures"
summary_dir <- "output"
dir.create(output_dir,  showWarnings = FALSE, recursive = TRUE)
dir.create(summary_dir, showWarnings = FALSE, recursive = TRUE)

wc_crs <- 5070

# ----------------------------------------------------------
# 2. NatGeo design system — matches script 19 exactly
# ----------------------------------------------------------
natgeo_yellow    <- "#FFCE00"
natgeo_yellow_dk <- "#E8B800"
parchment        <- "#F5F0E1"
parchment_dark   <- "#EDE5D0"
ink_black        <- "#1A1A1A"
ink_brown        <- "#3D2B1F"
ink_gray         <- "#5C5C5C"

theme_natgeo <- function() {
  theme_void(base_size = 11) %+replace%
    theme(
      text              = element_text(family = "serif", color = ink_black),
      plot.background   = element_rect(fill = parchment, color = NA),
      plot.margin       = margin(8, 8, 8, 8),
      legend.background = element_rect(
        fill      = alpha(parchment, 0.95),
        color     = ink_gray,
        linewidth = 0.3
      ),
      legend.title  = element_text(size = 9, face = "bold",
                                   family = "serif", color = ink_brown),
      legend.text   = element_text(size = 8, family = "serif",
                                   color = ink_gray),
      legend.key.size = unit(0.45, "cm"),
      legend.margin   = margin(4, 6, 4, 6)
    )
}

format_acres <- function(x) {
  dplyr::case_when(
    x >= 1000 ~ scales::comma(round(x)),
    x >= 1    ~ as.character(round(x, 1)),
    x > 0     ~ as.character(round(x, 2)),
    TRUE      ~ "0"
  )
}

# ----------------------------------------------------------
# 3. Fetch YTD fire perimeters from NIFC
# ----------------------------------------------------------
message("Fetching NIFC YTD perimeters...")

nifc_url <- paste0(
  "https://services3.arcgis.com/T4QMspbfLg3qTGWY/ArcGIS/rest/services/",
  "WFIGS_Interagency_Perimeters_YearToDate/FeatureServer/0/query"
)

resp <- httr::GET(
  nifc_url,
  query = list(
    where             = "attr_POOState IN ('US-CA','US-OR','US-WA')",
    outFields         = paste(c(
      "attr_IncidentName", "attr_POOState", "attr_POOCounty",
      "attr_FireDiscoveryDateTime", "attr_IncidentSize",
      "attr_PercentContained", "poly_GISAcres", "poly_DateCurrent"
    ), collapse = ","),
    f                 = "geojson",
    resultRecordCount = 2000
  ),
  httr::timeout(60)
)

raw_text <- httr::content(resp, as = "text", encoding = "UTF-8")

if (httr::status_code(resp) != 200 || grepl('"error"', raw_text)) {
  stop(sprintf(
    "NIFC API error (status %d): %s",
    httr::status_code(resp),
    substr(raw_text, 1, 200)
  ))
}

fires_raw <- sf::st_read(raw_text, quiet = TRUE)
message(sprintf("Raw API records: %d", nrow(fires_raw)))

# Handle zero fires gracefully
if (nrow(fires_raw) == 0) {
  message("No YTD fires for CA/OR/WA — writing empty summary")
  writeLines(
    sprintf("0 fires | 0 acres | %s", format(Sys.Date(), "%Y-%m-%d")),
    file.path(summary_dir, "ytd_summary.txt")
  )
  message("=== YTD CI Update Complete (no fires) ===")
  quit(status = 0)
}

# ----------------------------------------------------------
# 4. Fetch OSM fire stations
# ----------------------------------------------------------
message("Fetching OSM fire stations...")

fetch_osm_stations <- function(state_bbox, timeout = 60) {
  query <- osmdata::opq(bbox = state_bbox, timeout = timeout) |>
    osmdata::add_osm_feature(key = "amenity", value = "fire_station")
  
  result <- tryCatch(
    osmdata::osmdata_sf(query),
    error = function(e) {
      message("  OSM fetch error: ", e$message)
      NULL
    }
  )
  result
}

# Bounding boxes for each state
bboxes <- list(
  CA = c(-124.5, 32.5, -114.1, 42.0),
  OR = c(-124.6, 41.9, -116.5, 46.3),
  WA = c(-124.7, 45.5, -116.9, 49.0)
)

stations_list <- list()
for (state_code in names(bboxes)) {
  message(sprintf("  Fetching %s stations...", state_code))
  result <- fetch_osm_stations(bboxes[[state_code]])
  if (!is.null(result) && !is.null(result$osm_points) &&
      nrow(result$osm_points) > 0) {
    stations_list[[state_code]] <- result$osm_points |>
      dplyr::select(osm_id, name, geometry) |>
      dplyr::mutate(state_code = state_code)
  }
  Sys.sleep(2)  # be polite to OSM
}

stations_raw <- dplyr::bind_rows(stations_list)
message(sprintf("Total OSM stations: %d", nrow(stations_raw)))

# Clean stations
stations_clean <- stations_raw |>
  dplyr::filter(!is.na(name), !sf::st_is_empty(geometry)) |>
  dplyr::distinct(geometry, .keep_all = TRUE)

message(sprintf("Clean stations: %d", nrow(stations_clean)))

# ----------------------------------------------------------
# 5. Project and compute distances
# ----------------------------------------------------------
message("Computing distances...")

fires_proj    <- fires_raw    |> sf::st_make_valid() |>
  sf::st_transform(wc_crs)
stations_proj <- stations_clean |> sf::st_transform(wc_crs)

# Distance from each fire perimeter edge to nearest station
dist_matrix <- sf::st_distance(fires_proj, stations_proj)

nearest_idx      <- apply(dist_matrix, 1, which.min)
nearest_dist_m   <- apply(dist_matrix, 1, min)
nearest_name     <- stations_clean$name[nearest_idx]

fires_with_dist <- fires_proj |>
  dplyr::mutate(
    nearest_station_name = nearest_name,
    dist_nearest_m       = as.numeric(nearest_dist_m),
    dist_nearest_km      = dist_nearest_m / 1000,
    acres = dplyr::coalesce(
      dplyr::na_if(attr_IncidentSize, 0),
      poly_GISAcres,
      0
    ),
    is_active = is.na(attr_PercentContained) |
      attr_PercentContained < 100,
    status = dplyr::if_else(is_active, "Active", "Contained"),
    state = dplyr::case_when(
      attr_POOState == "US-CA" ~ "California",
      attr_POOState == "US-OR" ~ "Oregon",
      attr_POOState == "US-WA" ~ "Washington",
      TRUE ~ "Other"
    )
  )

message(sprintf("Fires with distances: %d", nrow(fires_with_dist)))

# ----------------------------------------------------------
# 6. Summary statistics
# ----------------------------------------------------------
n_total     <- nrow(fires_with_dist)
n_active    <- sum(fires_with_dist$is_active)
n_contained <- n_total - n_active
total_acres <- sum(fires_with_dist$acres, na.rm = TRUE)
median_dist <- round(median(fires_with_dist$dist_nearest_km), 1)
n_over_50   <- sum(fires_with_dist$dist_nearest_km >= 50)
pct_over_50 <- round(n_over_50 / n_total * 100, 1)

season_stage <- dplyr::case_when(
  n_total >= 50 ~ "peak",
  n_total >= 10 ~ "building",
  TRUE          ~ "early"
)

message(sprintf("Total: %d fires | %d active | %s acres | median %.1f km",
                n_total, n_active,
                scales::comma(round(total_acres)), median_dist))
message(sprintf("Season stage: %s", season_stage))

# Per-state stats
state_ytd_stats <- fires_with_dist |>
  sf::st_drop_geometry() |>
  dplyr::group_by(state) |>
  dplyr::summarise(
    n_fires     = dplyr::n(),
    n_active    = sum(is_active),
    total_acres = sum(acres, na.rm = TRUE),
    median_dist = round(median(dist_nearest_km), 1),
    pct_over_50 = round(mean(dist_nearest_km > 50) * 100, 1),
    .groups = "drop"
  ) |>
  dplyr::arrange(dplyr::desc(n_fires))

# Station burden
if (n_total >= 10) {
  station_burden_ytd <- fires_with_dist |>
    sf::st_drop_geometry() |>
    dplyr::group_by(nearest_station_name) |>
    dplyr::summarise(
      n_fires     = dplyr::n(),
      n_active    = sum(is_active),
      total_acres = sum(acres, na.rm = TRUE),
      mean_dist   = round(mean(dist_nearest_km), 1),
      max_dist    = round(max(dist_nearest_km), 1),
      states      = paste(sort(unique(state)), collapse = "/"),
      .groups     = "drop"
    ) |>
    dplyr::arrange(dplyr::desc(n_fires)) |>
    dplyr::slice_head(n = 5)
}

# ----------------------------------------------------------
# 7. Prepare map layers — WGS84 for plotting
# ----------------------------------------------------------
fires_4326    <- fires_with_dist |> sf::st_transform(4326)
stations_4326 <- stations_clean  |> sf::st_transform(4326)

states_bg <- sf::st_as_sf(
  maps::map("state",
            regions = c("california", "oregon", "washington"),
            fill = TRUE, plot = FALSE
  )
) |> sf::st_transform(4326)

counties_bg <- sf::st_as_sf(
  maps::map("county",
            regions = c("california", "oregon", "washington"),
            fill = TRUE, plot = FALSE
  )
) |> sf::st_transform(4326)

# Fire labels — top fires by acres
n_label <- min(10, n_total)

label_fires_sf <- fires_4326 |>
  dplyr::arrange(dplyr::desc(acres)) |>
  dplyr::slice_head(n = n_label)

label_coords <- label_fires_sf |>
  sf::st_centroid() |>
  sf::st_coordinates() |>
  tibble::as_tibble()

label_fires <- label_coords |>
  dplyr::bind_cols(
    label_fires_sf |>
      sf::st_drop_geometry() |>
      dplyr::select(attr_IncidentName, acres, attr_PercentContained,
                    dist_nearest_km, is_active, nearest_station_name)
  ) |>
  dplyr::rename(lon = X, lat = Y) |>
  dplyr::mutate(
    label = paste0(
      toupper(coalesce(attr_IncidentName, "UNNAMED")), "\n",
      format_acres(acres), " ac",
      dplyr::if_else(is_active, "  \u2022  ACTIVE", "")
    )
  )

# Connector lines for isolated fires
station_coords <- stations_4326 |>
  sf::st_coordinates() |>
  tibble::as_tibble() |>
  dplyr::bind_cols(
    stations_4326 |>
      sf::st_drop_geometry() |>
      dplyr::select(name)
  ) |>
  dplyr::rename(stn_lon = X, stn_lat = Y)

isolated_lines <- label_fires |>
  dplyr::filter(dist_nearest_km >= 25) |>
  dplyr::left_join(station_coords, by = c("nearest_station_name" = "name")) |>
  dplyr::filter(!is.na(stn_lon))

state_labels <- tibble::tibble(
  NAME = c("Washington", "Oregon", "California"),
  lon  = c(-120.5, -120.8, -119.5),
  lat  = c(47.5, 43.8, 37.2)
)

# ----------------------------------------------------------
# 8. Main map — matches script 19 exactly
# ----------------------------------------------------------
message("Building main map...")

main_map <- ggplot() +
  geom_sf(data = counties_bg,
          fill = parchment_dark, color = alpha(ink_brown, 0.2),
          linewidth = 0.1) +
  geom_sf(data = states_bg,
          fill = NA, color = ink_black, linewidth = 0.8) +
  geom_sf(data = stations_4326,
          color = alpha(ink_brown, 0.3), size = 0.3, shape = 17) +
  geom_sf(data = fires_4326 |> dplyr::filter(!is_active),
          fill  = alpha("#5B7E5E", 0.35),
          color = alpha("#3D5C3F", 0.5), linewidth = 0.1) +
  geom_sf(data = fires_4326 |> dplyr::filter(is_active),
          fill  = alpha("#8B1A1A", 0.5),
          color = "#5C1A0A", linewidth = 0.25) +
  {
    if (nrow(isolated_lines) > 0) {
      geom_segment(
        data = isolated_lines,
        aes(x = lon, y = lat, xend = stn_lon, yend = stn_lat),
        color     = alpha(natgeo_yellow_dk, 0.4),
        linewidth = 0.3, linetype = "dashed"
      )
    }
  } +
  ggrepel::geom_label_repel(
    data               = label_fires,
    aes(x = lon, y = lat, label = label),
    size               = 2.2,
    fontface           = "bold",
    family             = "serif",
    fill               = alpha(parchment, 0.9),
    color              = dplyr::if_else(label_fires$is_active,
                                        "#8B1A1A", ink_brown),
    label.size         = 0.2,
    label.padding      = unit(0.15, "lines"),
    box.padding        = unit(0.7,  "lines"),
    min.segment.length = 0,
    segment.color      = ink_brown,
    segment.size       = 0.25,
    max.overlaps       = 20,
    seed               = 42,
    force              = 5,
    force_pull         = 0.3
  ) +
  geom_text(
    data     = state_labels,
    aes(x = lon, y = lat, label = NAME),
    size     = 5, fontface = "bold",
    family   = "serif", color = alpha(ink_brown, 0.5)
  ) +
  ggspatial::annotation_scale(
    location    = "bl", width_hint  = 0.15,
    text_cex    = 0.65, text_family = "serif",
    line_width  = 0.4,  height      = unit(0.12, "cm"),
    pad_x       = unit(0.3, "cm"), pad_y = unit(0.3, "cm")
  ) +
  theme_natgeo() +
  coord_sf(xlim = c(-124.8, -114.0), ylim = c(32.5, 49.0), expand = FALSE)

# ----------------------------------------------------------
# 9. Inset map
# ----------------------------------------------------------
usa_sf <- sf::st_as_sf(maps::map("state", plot = FALSE, fill = TRUE)) |>
  sf::st_transform(4326)

wc_highlight <- usa_sf |>
  dplyr::filter(ID %in% c("california", "oregon", "washington"))

inset_map <- ggplot() +
  geom_sf(data = usa_sf,
          fill = parchment_dark, color = "white", linewidth = 0.2) +
  geom_sf(data = wc_highlight,
          fill = alpha(ink_brown, 0.3), color = "white", linewidth = 0.3) +
  theme_void() +
  theme(plot.background = element_rect(
    fill = parchment, color = ink_brown, linewidth = 0.6
  )) +
  coord_sf(xlim = c(-125, -104), ylim = c(31, 50))

# ----------------------------------------------------------
# 10. Stat panels — identical to script 19
# ----------------------------------------------------------
acres_display <- dplyr::if_else(
  total_acres > 0,
  paste0(scales::comma(round(total_acres, 1)), " TOTAL ACRES"),
  "ACRES NOT YET REPORTED"
)

make_panel <- function(..., bg = parchment, border = ink_brown) {
  ggplot() +
    { list(...) } +
    scale_x_continuous(limits = c(0, 1)) +
    scale_y_continuous(limits = c(0, 1)) +
    theme_void() +
    theme(
      plot.background = element_rect(fill = bg, color = border, linewidth = 0.4),
      plot.margin     = margin(6, 6, 6, 6)
    )
}

stat_overview <- ggplot() +
  annotate("text", x = 0.5, y = 0.93,
           label    = paste0(format(Sys.Date(), "%Y"), " SEASON AT A GLANCE"),
           size = 3.5, fontface = "bold", family = "serif", color = ink_black) +
  annotate("text", x = 0.5, y = 0.78,
           label = scales::comma(n_total),
           size = 8, fontface = "bold", family = "serif", color = "#8B1A1A") +
  annotate("text", x = 0.5, y = 0.68,
           label = "FIRE PERIMETERS",
           size = 2.8, family = "serif", color = ink_gray) +
  annotate("segment", x = 0.1, xend = 0.9, y = 0.58, yend = 0.58,
           color = alpha(ink_brown, 0.3), linewidth = 0.3) +
  annotate("text", x = 0.25, y = 0.48,
           label    = paste0(n_active, "\nACTIVE"),
           size = 3, fontface = "bold", family = "serif",
           color = "#8B1A1A", lineheight = 0.9) +
  annotate("text", x = 0.75, y = 0.48,
           label    = paste0(n_contained, "\nCONTAINED"),
           size = 3, fontface = "bold", family = "serif",
           color = "#5B7E5E", lineheight = 0.9) +
  annotate("segment", x = 0.1, xend = 0.9, y = 0.35, yend = 0.35,
           color = alpha(ink_brown, 0.3), linewidth = 0.3) +
  annotate("text", x = 0.5, y = 0.25,
           label    = acres_display,
           size = 2.8, fontface = "bold", family = "serif", color = ink_brown) +
  annotate("text", x = 0.5, y = 0.12,
           label    = paste0("Updated ", format(Sys.time(), "%B %d, %Y %H:%M")),
           size = 2, family = "serif", fontface = "italic", color = ink_gray) +
  scale_x_continuous(limits = c(0, 1)) +
  scale_y_continuous(limits = c(0, 1)) +
  theme_void() +
  theme(
    plot.background = element_rect(fill = parchment, color = ink_brown,
                                   linewidth = 0.4),
    plot.margin = margin(6, 6, 6, 6)
  )

stat_coverage <- ggplot() +
  annotate("text", x = 0.5, y = 0.93,
           label = "RESPONSE COVERAGE",
           size = 3.2, fontface = "bold", family = "serif", color = ink_black) +
  annotate("text", x = 0.5, y = 0.78,
           label = paste0(median_dist, " km"),
           size = 7, fontface = "bold", family = "serif", color = ink_brown) +
  annotate("text", x = 0.5, y = 0.68,
           label = "MEDIAN DISTANCE TO STATION",
           size = 2.3, family = "serif", color = ink_gray) +
  annotate("segment", x = 0.1, xend = 0.9, y = 0.58, yend = 0.58,
           color = alpha(ink_brown, 0.3), linewidth = 0.3) +
  annotate("text", x = 0.5, y = 0.48,
           label    = paste0(n_over_50, " FIRES BEYOND 50KM"),
           size = 2.8, fontface = "bold", family = "serif", color = "#8B1A1A") +
  annotate("text", x = 0.5, y = 0.38,
           label    = paste0(pct_over_50, "% of all ",
                             format(Sys.Date(), "%Y"), " fires"),
           size = 2.3, family = "serif", color = ink_gray) +
  annotate("segment", x = 0.1, xend = 0.9, y = 0.28, yend = 0.28,
           color = alpha(ink_brown, 0.3), linewidth = 0.3) +
  annotate("text", x = 0.5, y = 0.15,
           label    = "Straight-line, perimeter edge to station",
           size = 2, family = "serif", fontface = "italic", color = ink_gray) +
  scale_x_continuous(limits = c(0, 1)) +
  scale_y_continuous(limits = c(0, 1)) +
  theme_void() +
  theme(
    plot.background = element_rect(fill = parchment, color = ink_brown,
                                   linewidth = 0.4),
    plot.margin = margin(6, 6, 6, 6)
  )

state_label_text <- state_ytd_stats |>
  dplyr::mutate(
    line = paste0(
      toupper(state), "\n",
      n_fires, " fires  |  ", n_active, " active  |  ",
      format_acres(total_acres), " ac"
    )
  ) |>
  dplyr::pull(line) |>
  paste(collapse = "\n\n")

stat_states <- ggplot() +
  annotate("text", x = 0.5, y = 0.93,
           label = "BY STATE", size = 3.2, fontface = "bold",
           family = "serif", color = ink_black) +
  annotate("text", x = 0.08, y = 0.50, hjust = 0,
           label    = state_label_text,
           size = 2.5, family = "serif", color = ink_brown, lineheight = 1.2) +
  annotate("text", x = 0.5, y = 0.08,
           label    = paste0("CA/OR/WA | ", format(Sys.Date(), "%Y"),
                             " season to date"),
           size = 2, family = "serif", fontface = "italic", color = ink_gray) +
  scale_x_continuous(limits = c(0, 1)) +
  scale_y_continuous(limits = c(0, 1)) +
  theme_void() +
  theme(
    plot.background = element_rect(fill = parchment, color = ink_brown,
                                   linewidth = 0.4),
    plot.margin = margin(6, 6, 6, 6)
  )

stat_stations <- NULL
if (n_total >= 10) {
  station_label_text <- station_burden_ytd |>
    dplyr::mutate(
      active_tag = dplyr::if_else(n_active > 0,
                                  paste0(n_active, " active"),
                                  "all contained"),
      line = paste0(
        toupper(nearest_station_name), "\n",
        n_fires, " fires  |  ", active_tag, "\n",
        format_acres(total_acres), " ac  |  ", mean_dist, " km avg"
      )
    ) |>
    dplyr::pull(line) |>
    paste(collapse = "\n\n")
  
  stat_stations <- ggplot() +
    annotate("text", x = 0.5, y = 0.95,
             label = "MOST BURDENED STATIONS", size = 3.2,
             fontface = "bold", family = "serif", color = ink_black) +
    annotate("text", x = 0.08, y = 0.48, hjust = 0,
             label    = station_label_text,
             size = 2.2, family = "serif", color = ink_brown,
             lineheight = 1.15) +
    annotate("text", x = 0.5, y = 0.03,
             label    = "Ranked by number of fires as nearest station",
             size = 1.8, family = "serif", fontface = "italic",
             color = ink_gray) +
    scale_x_continuous(limits = c(0, 1)) +
    scale_y_continuous(limits = c(0, 1)) +
    theme_void() +
    theme(
      plot.background = element_rect(fill = parchment, color = ink_brown,
                                     linewidth = 0.4),
      plot.margin = margin(6, 6, 6, 6)
    )
}

# ----------------------------------------------------------
# 11. Title, subtitle, legend, caption bars
# ----------------------------------------------------------
title_bar <- ggplot() +
  annotate("rect", xmin = 0, xmax = 1, ymin = 0, ymax = 1,
           fill = natgeo_yellow) +
  annotate("text", x = 0.03, y = 0.55,
           label    = paste0(format(Sys.Date(), "%Y"),
                             " WEST COAST WILDFIRE SEASON"),
           size = 7, fontface = "bold", family = "serif",
           color = ink_black, hjust = 0) +
  annotate("text", x = 0.97, y = 0.55,
           label = "YEAR TO DATE", size = 4, fontface = "bold",
           family = "serif", color = alpha(ink_black, 0.5), hjust = 1) +
  scale_x_continuous(limits = c(0, 1), expand = c(0, 0)) +
  scale_y_continuous(limits = c(0, 1), expand = c(0, 0)) +
  theme_void() +
  theme(plot.margin = margin(0, 0, 0, 0))

subtitle_bar <- ggplot() +
  annotate("rect", xmin = 0, xmax = 1, ymin = 0, ymax = 1,
           fill = parchment) +
  annotate("text", x = 0.03, y = 0.5,
           label = paste0(
             scales::comma(n_total),
             " fire perimeters across California, Oregon, and Washington as of ",
             format(Sys.Date(), "%B %d, %Y"), ". ",
             n_active, " fires remain active",
             dplyr::if_else(
               total_acres > 0,
               paste0(" covering ", scales::comma(round(total_acres, 1)),
                      " total acres"),
               ""
             ),
             ". Median distance to nearest station: ", median_dist, " km."
           ),
           size = 3.2, family = "serif", color = ink_brown,
           hjust = 0, vjust = 0.5) +
  scale_x_continuous(limits = c(0, 1), expand = c(0, 0)) +
  scale_y_continuous(limits = c(0, 1), expand = c(0, 0)) +
  theme_void() +
  theme(plot.margin = margin(0, 0, 0, 0))

legend_strip <- ggplot() +
  annotate("rect", xmin = 0, xmax = 1, ymin = 0, ymax = 1,
           fill = parchment) +
  annotate("rect", xmin = 0.03, xmax = 0.06, ymin = 0.25, ymax = 0.75,
           fill = alpha("#8B1A1A", 0.7)) +
  annotate("text", x = 0.07, y = 0.5, label = "Active fire",
           size = 2.5, hjust = 0, family = "serif", color = ink_brown) +
  annotate("rect", xmin = 0.22, xmax = 0.25, ymin = 0.25, ymax = 0.75,
           fill = alpha("#5B7E5E", 0.5)) +
  annotate("text", x = 0.26, y = 0.5, label = "Contained",
           size = 2.5, hjust = 0, family = "serif", color = ink_brown) +
  annotate("point", x = 0.42, y = 0.5, shape = 17,
           size = 2, color = ink_brown) +
  annotate("text", x = 0.44, y = 0.5, label = "Fire station",
           size = 2.5, hjust = 0, family = "serif", color = ink_brown) +
  annotate("segment", x = 0.58, xend = 0.62, y = 0.5, yend = 0.5,
           color = natgeo_yellow_dk, linewidth = 0.5, linetype = "dashed") +
  annotate("text", x = 0.63, y = 0.5,
           label = "Distance to station (>25 km)",
           size = 2.5, hjust = 0, family = "serif", color = ink_brown) +
  scale_x_continuous(limits = c(0, 1), expand = c(0, 0)) +
  scale_y_continuous(limits = c(0, 1), expand = c(0, 0)) +
  theme_void() +
  theme(plot.margin = margin(0, 0, 0, 0))

caption_bar <- ggplot() +
  annotate("rect", xmin = 0, xmax = 1, ymin = 0, ymax = 1,
           fill = parchment) +
  annotate("text", x = 0.03, y = 0.5,
           label = paste0(
             "DATA: NIFC WFIGS YTD Interagency Perimeters + ",
             "OpenStreetMap fire stations  |  ",
             "Straight-line distances, perimeter edge to station  |  ",
             "Acreage: best of IncidentSize / GISAcres  |  ",
             "Analysis by B. Groves  |  ",
             format(Sys.time(), "%B %d, %Y %H:%M")
           ),
           size = 2.3, family = "serif", color = ink_gray, hjust = 0) +
  annotate("rect", xmin = 0, xmax = 1, ymin = 0, ymax = 0.15,
           fill = natgeo_yellow) +
  scale_x_continuous(limits = c(0, 1), expand = c(0, 0)) +
  scale_y_continuous(limits = c(0, 1), expand = c(0, 0)) +
  theme_void() +
  theme(plot.margin = margin(0, 0, 0, 0))

# ----------------------------------------------------------
# 12. Adaptive sidebar layout — matches script 19 exactly
# ----------------------------------------------------------
message(sprintf("Assembling layout (%s season stage)...", season_stage))

if (season_stage == "early") {
  right_sidebar <- cowplot::plot_grid(
    stat_overview, stat_coverage, stat_states, inset_map,
    ncol = 1, rel_heights = c(0.28, 0.28, 0.27, 0.17)
  )
} else if (season_stage == "building") {
  right_sidebar <- cowplot::plot_grid(
    stat_overview, stat_coverage, stat_stations, inset_map,
    ncol = 1, rel_heights = c(0.25, 0.25, 0.33, 0.17)
  )
} else {
  right_sidebar <- cowplot::plot_grid(
    stat_overview, stat_stations, inset_map,
    ncol = 1, rel_heights = c(0.28, 0.40, 0.32)
  )
}

map_row <- cowplot::plot_grid(
  main_map, right_sidebar,
  ncol = 2, rel_widths = c(0.72, 0.28)
)

full_layout <- cowplot::plot_grid(
  title_bar, subtitle_bar, legend_strip, map_row, caption_bar,
  ncol = 1, rel_heights = c(0.05, 0.04, 0.025, 0.855, 0.03)
)

# ----------------------------------------------------------
# 13. Save
# ----------------------------------------------------------
out_path <- file.path(output_dir, "ytd_natgeo.png")

ggsave(
  out_path,
  plot   = full_layout,
  width  = 18,
  height = 14,
  dpi    = 150,
  bg     = parchment
)

message(sprintf("Saved: %s (%.0f KB)", out_path,
                file.size(out_path) / 1024))

# ----------------------------------------------------------
# 14. Summary file
# ----------------------------------------------------------
writeLines(
  sprintf("%d fires | %s acres | %s | stage: %s",
          n_total,
          scales::comma(round(total_acres)),
          format(Sys.Date(), "%Y-%m-%d"),
          season_stage),
  file.path(summary_dir, "ytd_summary.txt")
)

message("=== YTD CI Update Complete ===")