# =============================================================================
# update_ytd_ci.R
# GitHub Actions runner for YTD NatGeo map
# Handles CI environment: no local paths, no interactive prompts
# =============================================================================

message("=== YTD Update Starting: ", Sys.time(), " ===")

# --- Set CI-friendly paths --------------------------------------------------
# GitHub Actions runs from repo root
# Override the local Windows path with repo-relative path
ci_output_dir <- "output/figures/"
if (!dir.exists(ci_output_dir)) dir.create(ci_output_dir, recursive = TRUE)

# Temp directory for intermediate files
ci_data_dir <- tempdir()

# --- Source setup scripts ---------------------------------------------------
source("R/01_setup.R")
source("R/07_west_coast_setup.R")

# Override output dir for CI
wc_output_dir <- ci_data_dir
if (!dir.exists(wc_output_dir)) dir.create(wc_output_dir, recursive = TRUE)

# --- Check for baseline RDS ------------------------------------------------
# In CI we need to rebuild from scratch — no local baseline
# But we can cache the baseline as a GitHub artifact
baseline_file <- "output/westcoast_baseline.rds"

if (file.exists(baseline_file)) {
  message("Loading cached baseline...")
  baseline <- readRDS(baseline_file)
  list2env(baseline, envir = .GlobalEnv)
} else {
  message("No baseline found. Building from scratch...")
  options(tigris_use_cache = FALSE)
  source("R/08_west_coast_study_area.R")
  source("R/09_west_coast_stations.R")
  source("R/10_west_coast_perimeters.R")
  source("R/11_west_coast_distance.R")
  
  # Save baseline for next CI run
  saveRDS(
    list(
      fires_summary_df      = fires_summary_df,
      fires_wc_with_dist    = fires_wc_with_dist,
      all_stations_wc_clean = all_stations_wc_clean,
      all_stations_wc_proj  = all_stations_wc_proj,
      westcoast_counties    = westcoast_counties,
      westcoast_states      = westcoast_states
    ),
    file = baseline_file
  )
  message("Baseline saved to: ", baseline_file)
}

# --- Fetch function from script 10 -----------------------------------------
if (!exists("fetch_nifc_wc_page")) {
  source("R/10_west_coast_perimeters.R")
}

# --- Fresh YTD pull ---------------------------------------------------------
if (exists("fires_ytd_dist")) rm(fires_ytd_dist)
message("Fetching fresh YTD data from NIFC...")
source("R/13_west_coast_ytd.R")

# --- Check if we got data --------------------------------------------------
if (!exists("fires_ytd_dist") || is.null(fires_ytd_dist) ||
    nrow(fires_ytd_dist) == 0) {
  
  message("No YTD fires returned. Off-season or API issue.")
  
  # Write summary for commit message
  writeLines(
    paste0("No fires - ", format(Sys.Date(), "%B %d, %Y")),
    "output/ytd_summary.txt"
  )
  
  message("=== YTD Update Complete (no data): ", Sys.time(), " ===")
  
} else {
  
  message("YTD fires found: ", nrow(fires_ytd_dist))
  
  # --- Build NatGeo map ---------------------------------------------------
  # We need to override wc_output_dir back for the map save
  wc_output_dir <- ci_data_dir
  
  # Source the NatGeo builder — but skip the data fetch since we just did it
  # We'll inline the key parts instead
  
  # =========================================================================
  # NATGEO COLORS + THEME
  # =========================================================================
  
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
        legend.background = element_rect(fill = alpha(parchment, 0.95),
                                         color = ink_gray, linewidth = 0.3),
        legend.title      = element_text(size = 9, face = "bold",
                                         family = "serif", color = ink_brown),
        legend.text       = element_text(size = 8, family = "serif",
                                         color = ink_gray),
        legend.key.size   = unit(0.45, "cm"),
        legend.margin     = margin(4, 6, 4, 6)
      )
  }
  
  format_acres <- function(x) {
    case_when(
      x >= 1000 ~ scales::comma(round(x)),
      x >= 1    ~ as.character(round(x, 1)),
      x > 0     ~ as.character(round(x, 2)),
      TRUE      ~ "0"
    )
  }
  
  # --- Data prep (same as script 19) --------------------------------------
  states_4326   <- westcoast_states %>% st_as_sf() %>% st_transform(4326)
  counties_4326 <- westcoast_counties %>% st_as_sf() %>% st_transform(4326)
  stations_4326 <- all_stations_wc_clean %>% st_as_sf() %>% st_transform(4326)
  
  fires_ytd_4326 <- fires_ytd_dist %>%
    st_as_sf() %>%
    st_transform(4326) %>%
    mutate(
      acres = coalesce(na_if(attr_IncidentSize, 0), poly_GISAcres, 0),
      is_active = is.na(attr_PercentContained) | attr_PercentContained < 100,
      status = if_else(is_active, "Active", "Contained"),
      state = case_when(
        attr_POOState == "US-CA" ~ "California",
        attr_POOState == "US-OR" ~ "Oregon",
        attr_POOState == "US-WA" ~ "Washington",
        TRUE ~ "Other"
      )
    )
  
  n_total     <- nrow(fires_ytd_4326)
  n_active    <- sum(fires_ytd_4326$is_active)
  n_contained <- n_total - n_active
  total_acres <- sum(fires_ytd_4326$acres, na.rm = TRUE)
  median_dist <- round(median(fires_ytd_4326$dist_nearest_km), 1)
  
  # Write summary for commit message
  writeLines(
    paste0(n_total, " fires, ", n_active, " active, ",
           scales::comma(round(total_acres)), " ac"),
    "output/ytd_summary.txt"
  )
  
  message("Building NatGeo map...")
  
  # Override output dir and source the full script 19
  # But skip the fetch sections since data is already loaded
  wc_output_dir <- ci_data_dir
  
  # We already have fires_ytd_dist, so script 19 will skip the fetch
  # and go straight to map building
  # But we need to trick it into not re-fetching
  # Easiest: just source the map-building portion directly
  
  # For CI, save directly to output/figures/
  # Source script 19 but it will try to fetch again...
  # Better approach: build the map inline using the same code
  
  # === SIMPLIFIED CI MAP BUILD ===
  # Uses same logic as script 19 but skips fetch + saves to CI path
  
  state_labels <- tibble(
    NAME = c("Washington", "Oregon", "California"),
    lon  = c(-120.5, -120.8, -119.5),
    lat  = c(47.5, 43.8, 37.2)
  )
  
  n_label <- min(10, n_total)
  label_fires_spatial <- fires_ytd_4326 %>%
    arrange(desc(acres)) %>%
    slice_head(n = n_label)
  
  label_fires <- label_fires_spatial %>%
    st_centroid() %>%
    st_coordinates() %>%
    as_tibble() %>%
    bind_cols(
      label_fires_spatial %>%
        st_drop_geometry() %>%
        select(attr_IncidentName, acres, dist_nearest_km,
               is_active, nearest_station_name)
    ) %>%
    rename(lon = X, lat = Y) %>%
    mutate(
      label = paste0(
        toupper(attr_IncidentName), "\n",
        format_acres(acres), " ac",
        if_else(is_active, "  \u2022  ACTIVE", "")
      )
    )
  
  station_coords <- stations_4326 %>%
    st_coordinates() %>%
    as_tibble() %>%
    bind_cols(stations_4326 %>% st_drop_geometry() %>% select(name)) %>%
    rename(stn_lon = X, stn_lat = Y)
  
  isolated_lines <- label_fires %>%
    filter(dist_nearest_km >= 25) %>%
    left_join(station_coords, by = c("nearest_station_name" = "name")) %>%
    filter(!is.na(stn_lon))
  
  # Build main map
  main_map <- ggplot() +
    geom_sf(data = counties_4326,
            fill = parchment_dark, color = alpha(ink_brown, 0.2),
            linewidth = 0.1) +
    geom_sf(data = states_4326,
            fill = NA, color = ink_black, linewidth = 0.8) +
    geom_sf(data = stations_4326,
            color = alpha(ink_brown, 0.3), size = 0.3, shape = 17) +
    geom_sf(data = fires_ytd_4326 %>% filter(!is_active),
            fill = alpha("#5B7E5E", 0.35),
            color = alpha("#3D5C3F", 0.5), linewidth = 0.1) +
    geom_sf(data = fires_ytd_4326 %>% filter(is_active),
            fill = alpha("#8B1A1A", 0.5),
            color = "#5C1A0A", linewidth = 0.25) +
    {
      if (nrow(isolated_lines) > 0) {
        geom_segment(data = isolated_lines,
                     aes(x = lon, y = lat, xend = stn_lon, yend = stn_lat),
                     color = alpha(natgeo_yellow_dk, 0.4),
                     linewidth = 0.3, linetype = "dashed")
      }
    } +
    ggrepel::geom_label_repel(
      data = label_fires,
      aes(x = lon, y = lat, label = label),
      size = 2.2, fontface = "bold", family = "serif",
      fill = alpha(parchment, 0.9),
      color = if_else(label_fires$is_active, "#8B1A1A", ink_brown),
      label.size = 0.2, box.padding = unit(0.7, "lines"),
      min.segment.length = 0, segment.color = ink_brown,
      segment.size = 0.25, max.overlaps = 20,
      seed = 42, force = 5
    ) +
    geom_text(data = state_labels,
              aes(x = lon, y = lat, label = NAME),
              size = 5, fontface = "bold", family = "serif",
              color = alpha(ink_brown, 0.5)) +
    ggspatial::annotation_scale(
      location = "bl", width_hint = 0.15, text_cex = 0.65,
      text_family = "serif", line_width = 0.4,
      height = unit(0.12, "cm"),
      pad_x = unit(0.3, "cm"), pad_y = unit(0.3, "cm")
    ) +
    theme_natgeo() +
    coord_sf(xlim = c(-124.8, -114.0), ylim = c(32.5, 49.0),
             expand = FALSE)
  
  # Title bar
  title_bar <- ggplot() +
    annotate("rect", xmin = 0, xmax = 1, ymin = 0, ymax = 1,
             fill = natgeo_yellow) +
    annotate("text", x = 0.03, y = 0.55,
             label = paste0(format(Sys.Date(), "%Y"),
                            " WEST COAST WILDFIRE SEASON"),
             size = 7, fontface = "bold", family = "serif",
             color = ink_black, hjust = 0) +
    annotate("text", x = 0.97, y = 0.55, label = "YEAR TO DATE",
             size = 4, fontface = "bold", family = "serif",
             color = alpha(ink_black, 0.5), hjust = 1) +
    scale_x_continuous(limits = c(0, 1), expand = c(0, 0)) +
    scale_y_continuous(limits = c(0, 1), expand = c(0, 0)) +
    theme_void() + theme(plot.margin = margin(0, 0, 0, 0))
  
  # Subtitle
  subtitle_bar <- ggplot() +
    annotate("rect", xmin = 0, xmax = 1, ymin = 0, ymax = 1,
             fill = parchment) +
    annotate("text", x = 0.03, y = 0.5,
             label = paste0(
               n_total, " fire perimeters as of ",
               format(Sys.Date(), "%B %d, %Y"), ". ",
               n_active, " active",
               if_else(total_acres > 0,
                       paste0(", ", scales::comma(round(total_acres, 1)),
                              " total acres"), ""),
               ". Median distance: ", median_dist, " km."),
             size = 3.2, family = "serif", color = ink_brown,
             hjust = 0, vjust = 0.5) +
    scale_x_continuous(limits = c(0, 1), expand = c(0, 0)) +
    scale_y_continuous(limits = c(0, 1), expand = c(0, 0)) +
    theme_void() + theme(plot.margin = margin(0, 0, 0, 0))
  
  # Legend strip
  legend_strip <- ggplot() +
    annotate("rect", xmin = 0, xmax = 1, ymin = 0, ymax = 1,
             fill = parchment) +
    annotate("rect", xmin = 0.03, xmax = 0.06, ymin = 0.25, ymax = 0.75,
             fill = alpha("#8B1A1A", 0.7)) +
    annotate("text", x = 0.07, y = 0.5, label = "Active",
             size = 2.5, hjust = 0, family = "serif", color = ink_brown) +
    annotate("rect", xmin = 0.18, xmax = 0.21, ymin = 0.25, ymax = 0.75,
             fill = alpha("#5B7E5E", 0.5)) +
    annotate("text", x = 0.22, y = 0.5, label = "Contained",
             size = 2.5, hjust = 0, family = "serif", color = ink_brown) +
    annotate("point", x = 0.38, y = 0.5, shape = 17,
             size = 2, color = ink_brown) +
    annotate("text", x = 0.40, y = 0.5, label = "Station",
             size = 2.5, hjust = 0, family = "serif", color = ink_brown) +
    scale_x_continuous(limits = c(0, 1), expand = c(0, 0)) +
    scale_y_continuous(limits = c(0, 1), expand = c(0, 0)) +
    theme_void() + theme(plot.margin = margin(0, 0, 0, 0))
  
  # Overview panel
  stat_overview <- ggplot() +
    annotate("text", x = 0.5, y = 0.93,
             label = paste0(format(Sys.Date(), "%Y"), " AT A GLANCE"),
             size = 3.5, fontface = "bold", family = "serif",
             color = ink_black) +
    annotate("text", x = 0.5, y = 0.75,
             label = scales::comma(n_total),
             size = 8, fontface = "bold", family = "serif",
             color = "#8B1A1A") +
    annotate("text", x = 0.5, y = 0.65, label = "FIRE PERIMETERS",
             size = 2.8, family = "serif", color = ink_gray) +
    annotate("segment", x = 0.1, xend = 0.9, y = 0.55, yend = 0.55,
             color = alpha(ink_brown, 0.3), linewidth = 0.3) +
    annotate("text", x = 0.25, y = 0.45,
             label = paste0(n_active, "\nACTIVE"),
             size = 3, fontface = "bold", family = "serif",
             color = "#8B1A1A", lineheight = 0.9) +
    annotate("text", x = 0.75, y = 0.45,
             label = paste0(n_contained, "\nCONTAINED"),
             size = 3, fontface = "bold", family = "serif",
             color = "#5B7E5E", lineheight = 0.9) +
    annotate("segment", x = 0.1, xend = 0.9, y = 0.32, yend = 0.32,
             color = alpha(ink_brown, 0.3), linewidth = 0.3) +
    annotate("text", x = 0.5, y = 0.22,
             label = if_else(total_acres > 0,
                             paste0(scales::comma(round(total_acres, 1)),
                                    " TOTAL ACRES"),
                             "ACRES NOT YET REPORTED"),
             size = 2.8, fontface = "bold", family = "serif",
             color = ink_brown) +
    annotate("text", x = 0.5, y = 0.10,
             label = paste0("Updated ",
                            format(Sys.time(), "%B %d, %Y %H:%M UTC")),
             size = 2, family = "serif", fontface = "italic",
             color = ink_gray) +
    scale_x_continuous(limits = c(0, 1)) +
    scale_y_continuous(limits = c(0, 1)) +
    theme_void() +
    theme(plot.background = element_rect(fill = parchment,
                                         color = ink_brown, linewidth = 0.4),
          plot.margin = margin(6, 6, 6, 6))
  
  # Inset map
  usa_sf <- st_as_sf(maps::map("state", plot = FALSE, fill = TRUE)) %>%
    st_transform(4326)
  wc_highlight <- usa_sf %>%
    filter(ID %in% c("california", "oregon", "washington"))
  
  inset_map <- ggplot() +
    geom_sf(data = usa_sf, fill = parchment_dark, color = "white",
            linewidth = 0.2) +
    geom_sf(data = wc_highlight, fill = alpha(ink_brown, 0.3),
            color = "white", linewidth = 0.3) +
    theme_void() +
    theme(plot.background = element_rect(fill = parchment,
                                         color = ink_brown, linewidth = 0.6)) +
    coord_sf(xlim = c(-125, -104), ylim = c(31, 50))
  
  # Caption
  caption_bar <- ggplot() +
    annotate("rect", xmin = 0, xmax = 1, ymin = 0, ymax = 1,
             fill = parchment) +
    annotate("text", x = 0.03, y = 0.5,
             label = paste0(
               "NIFC WFIGS YTD + OpenStreetMap  |  ",
               "Auto-updated via GitHub Actions  |  ",
               format(Sys.time(), "%B %d, %Y %H:%M UTC")),
             size = 2.3, family = "serif", color = ink_gray, hjust = 0) +
    annotate("rect", xmin = 0, xmax = 1, ymin = 0, ymax = 0.15,
             fill = natgeo_yellow) +
    scale_x_continuous(limits = c(0, 1), expand = c(0, 0)) +
    scale_y_continuous(limits = c(0, 1), expand = c(0, 0)) +
    theme_void() + theme(plot.margin = margin(0, 0, 0, 0))
  
  # Assemble
  right_sidebar <- cowplot::plot_grid(
    stat_overview, inset_map,
    ncol = 1, rel_heights = c(0.75, 0.25)
  )
  
  map_row <- cowplot::plot_grid(
    main_map, right_sidebar,
    ncol = 2, rel_widths = c(0.75, 0.25)
  )
  
  full_layout <- cowplot::plot_grid(
    title_bar, subtitle_bar, legend_strip, map_row, caption_bar,
    ncol = 1, rel_heights = c(0.05, 0.04, 0.025, 0.855, 0.03)
  )
  
  # Save directly to output/figures/
  ggsave(
    "output/figures/ytd_natgeo.png",
    plot   = full_layout,
    width  = 18, height = 14, dpi = 300, bg = parchment
  )
  
  message("YTD NatGeo map saved to output/figures/ytd_natgeo.png")
  message("=== YTD Update Complete: ", Sys.time(), " ===")
  message(n_total, " fires | ", n_active, " active | ",
          scales::comma(round(total_acres, 1)), " acres")
}