# =============================================================================
# 19_ytd_natgeo.R
# Current fire season — National Geographic style layout
# Designed to be re-run throughout fire season for fresh maps
#
# Adaptive panels:
#   Early season (<10 fires):  Overview + Coverage + States + Inset
#   Building (10-49 fires):    Overview + Coverage + Top Stations + Inset
#   Peak (50+ fires):          Overview + Top Stations + Worst Counties + Inset
#
# Acreage: uses coalesce(IncidentSize, GISAcres) for best available
#
# Outputs:
#   ytd_natgeo_YYYYMMDD.png
#
# Depends on: 01, 07, 10 (for fetch function), 13 (YTD data)
# =============================================================================

# --- Setup + baseline -------------------------------------------------------
if (!exists("fires_summary_df")) {
  message("Loading baseline...")
  source("R/01_setup.R")
  source("R/07_west_coast_setup.R")
  baseline <- readRDS(
    sort(list.files(wc_output_dir, pattern = "westcoast_baseline.*\\.rds$",
                    full.names = TRUE), decreasing = TRUE)[1]
  )
  list2env(baseline, envir = .GlobalEnv)
}

# --- Fresh YTD data ---------------------------------------------------------
if (!exists("fetch_nifc_wc_page")) {
  message("Loading fetch function from script 10...")
  source("R/10_west_coast_perimeters.R")
}

if (exists("fires_ytd_dist")) rm(fires_ytd_dist)
message("Fetching fresh YTD data...")
source("R/13_west_coast_ytd.R")

# --- Off-season guard -------------------------------------------------------
if (!exists("fires_ytd_dist") || is.null(fires_ytd_dist) ||
    nrow(fires_ytd_dist) == 0) {
  
  message("
  ============================================================
  No YTD fire data available - skipping NatGeo YTD map
  Expected outside of fire season (Nov-May)
  Re-run during fire season for live maps
  ============================================================
  ")
  
} else {
  
  # =============================================================================
  # NATGEO COLORS + THEME
  # =============================================================================
  
  natgeo_yellow    <- "#FFCE00"
  natgeo_yellow_dk <- "#E8B800"
  parchment        <- "#F5F0E1"
  parchment_dark   <- "#EDE5D0"
  ink_black        <- "#1A1A1A"
  ink_brown        <- "#3D2B1F"
  ink_gray         <- "#5C5C5C"
  
  earth_colors <- c("#E8E0C8", "#D4C69A", "#C4A265",
                    "#B07D42", "#8B4513", "#5C1A0A")
  
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
  
  # Smart acre formatting function
  format_acres <- function(x) {
    case_when(
      x >= 1000 ~ scales::comma(round(x)),
      x >= 1    ~ as.character(round(x, 1)),
      x > 0     ~ as.character(round(x, 2)),
      TRUE      ~ "0"
    )
  }
  
  # =============================================================================
  # DATA PREP
  # =============================================================================
  
  states_4326   <- westcoast_states %>% st_as_sf() %>% st_transform(4326)
  counties_4326 <- westcoast_counties %>% st_as_sf() %>% st_transform(4326)
  stations_4326 <- all_stations_wc_clean %>% st_as_sf() %>% st_transform(4326)
  
  fires_ytd_4326 <- fires_ytd_dist %>%
    st_as_sf() %>%
    st_transform(4326) %>%
    mutate(
      acres = coalesce(
        na_if(attr_IncidentSize, 0),
        poly_GISAcres,
        0
      ),
      is_active = is.na(attr_PercentContained) | attr_PercentContained < 100,
      status    = if_else(is_active, "Active", "Contained"),
      state = case_when(
        attr_POOState == "US-CA" ~ "California",
        attr_POOState == "US-OR" ~ "Oregon",
        attr_POOState == "US-WA" ~ "Washington",
        TRUE ~ "Other"
      ),
      dist_category = case_when(
        dist_nearest_km >= 100 ~ "Extreme (100+ km)",
        dist_nearest_km >= 50  ~ "Critical (50-100 km)",
        dist_nearest_km >= 25  ~ "Poor (25-50 km)",
        dist_nearest_km >= 10  ~ "Moderate (10-25 km)",
        TRUE                   ~ "Good (<10 km)"
      ) %>% factor(levels = c("Good (<10 km)", "Moderate (10-25 km)",
                              "Poor (25-50 km)", "Critical (50-100 km)",
                              "Extreme (100+ km)"))
    )
  
  # --- Summary stats ----------------------------------------------------------
  n_total     <- nrow(fires_ytd_4326)
  n_active    <- sum(fires_ytd_4326$is_active)
  n_contained <- n_total - n_active
  total_acres <- sum(fires_ytd_4326$acres, na.rm = TRUE)
  median_dist <- round(median(fires_ytd_4326$dist_nearest_km), 1)
  n_over_50   <- sum(fires_ytd_4326$dist_nearest_km >= 50)
  pct_over_50 <- round(n_over_50 / n_total * 100, 1)
  
  # --- Determine season stage for adaptive panels -----------------------------
  season_stage <- case_when(
    n_total >= 50 ~ "peak",
    n_total >= 10 ~ "building",
    TRUE          ~ "early"
  )
  
  cat("YTD Summary:\n")
  cat("Total fires:", n_total, "\n")
  cat("Active:", n_active, "| Contained:", n_contained, "\n")
  cat("Total acres:", scales::comma(round(total_acres, 1)), "\n")
  cat("Median distance:", median_dist, "km\n")
  cat("Fires >50km:", n_over_50, "(", pct_over_50, "%)\n")
  cat("Season stage:", season_stage, "\n\n")
  
  # --- Per-state stats (always computed) --------------------------------------
  state_ytd_stats <- fires_ytd_4326 %>%
    st_drop_geometry() %>%
    group_by(state) %>%
    summarise(
      n_fires     = n(),
      n_active    = sum(is_active),
      total_acres = sum(acres, na.rm = TRUE),
      median_dist = round(median(dist_nearest_km), 1),
      pct_over_50 = round(mean(dist_nearest_km > 50) * 100, 1),
      .groups     = "drop"
    ) %>%
    arrange(desc(n_fires))
  
  print(as.data.frame(state_ytd_stats))
  
  # --- Station burden (computed when 10+ fires) -------------------------------
  if (n_total >= 10) {
    station_burden_ytd <- fires_ytd_4326 %>%
      st_drop_geometry() %>%
      group_by(nearest_station_name) %>%
      summarise(
        n_fires     = n(),
        n_active    = sum(is_active),
        total_acres = sum(acres, na.rm = TRUE),
        mean_dist   = round(mean(dist_nearest_km), 1),
        max_dist    = round(max(dist_nearest_km), 1),
        states      = paste(sort(unique(state)), collapse = "/"),
        .groups     = "drop"
      ) %>%
      arrange(desc(n_fires)) %>%
      slice_head(n = 5)
    
    cat("\nTop burdened stations:\n")
    print(as.data.frame(station_burden_ytd))
  }
  
  # --- County stats (computed when 50+ fires) ---------------------------------
  if (n_total >= 50) {
    # Get county for each fire via spatial join
    fires_with_county <- fires_ytd_4326 %>%
      st_join(
        counties_4326 %>% select(GEOID, NAME, STATEFP),
        join = st_intersects,
        left = TRUE,
        largest = TRUE
      )
    
    county_burden_ytd <- fires_with_county %>%
      st_drop_geometry() %>%
      filter(!is.na(NAME)) %>%
      group_by(NAME, state) %>%
      summarise(
        n_fires     = n(),
        total_acres = sum(acres, na.rm = TRUE),
        median_dist = round(median(dist_nearest_km), 1),
        pct_over_50 = round(mean(dist_nearest_km > 50) * 100, 1),
        .groups     = "drop"
      ) %>%
      arrange(desc(median_dist)) %>%
      slice_head(n = 5)
    
    cat("\nWorst coverage counties:\n")
    print(as.data.frame(county_burden_ytd))
  }
  
  # --- Map label data ---------------------------------------------------------
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
        select(attr_IncidentName, acres,
               attr_PercentContained, dist_nearest_km,
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
  
  # Connector lines for isolated fires
  station_coords <- stations_4326 %>%
    st_coordinates() %>%
    as_tibble() %>%
    bind_cols(stations_4326 %>% st_drop_geometry() %>% select(name)) %>%
    rename(stn_lon = X, stn_lat = Y)
  
  isolated_lines <- label_fires %>%
    filter(dist_nearest_km >= 25) %>%
    left_join(station_coords, by = c("nearest_station_name" = "name")) %>%
    filter(!is.na(stn_lon))
  
  # =============================================================================
  # MAIN MAP
  # =============================================================================
  
  message("Building NatGeo YTD map...")
  
  main_map <- ggplot() +
    
    # County base
    geom_sf(data = counties_4326,
            fill = parchment_dark, color = alpha(ink_brown, 0.2),
            linewidth = 0.1) +
    
    # State borders
    geom_sf(data = states_4326,
            fill = NA, color = ink_black, linewidth = 0.8) +
    
    # Stations
    geom_sf(data = stations_4326,
            color = alpha(ink_brown, 0.3), size = 0.3, shape = 17) +
    
    # Contained fires
    geom_sf(data = fires_ytd_4326 %>% filter(!is_active),
            fill = alpha("#5B7E5E", 0.35),
            color = alpha("#3D5C3F", 0.5), linewidth = 0.1) +
    
    # Active fires
    geom_sf(data = fires_ytd_4326 %>% filter(is_active),
            fill = alpha("#8B1A1A", 0.5),
            color = "#5C1A0A", linewidth = 0.25) +
    
    # Connector lines
    {
      if (nrow(isolated_lines) > 0) {
        geom_segment(
          data = isolated_lines,
          aes(x = lon, y = lat, xend = stn_lon, yend = stn_lat),
          color = alpha(natgeo_yellow_dk, 0.4),
          linewidth = 0.3, linetype = "dashed"
        )
      }
    } +
    
    # Fire labels
    ggrepel::geom_label_repel(
      data = label_fires,
      aes(x = lon, y = lat, label = label),
      size               = 2.2,
      fontface           = "bold",
      family             = "serif",
      fill               = alpha(parchment, 0.9),
      color              = if_else(label_fires$is_active,
                                   "#8B1A1A", ink_brown),
      label.size         = 0.2,
      label.padding      = unit(0.15, "lines"),
      box.padding        = unit(0.7, "lines"),
      min.segment.length = 0,
      segment.color      = ink_brown,
      segment.size       = 0.25,
      max.overlaps       = 20,
      seed               = 42,
      force              = 5,
      force_pull         = 0.3
    ) +
    
    # State labels
    geom_text(
      data     = state_labels,
      aes(x = lon, y = lat, label = NAME),
      size     = 5,
      fontface = "bold",
      family   = "serif",
      color    = alpha(ink_brown, 0.5)
    ) +
    
    # Scale bar
    ggspatial::annotation_scale(
      location    = "bl",
      width_hint  = 0.15,
      text_cex    = 0.65,
      text_family = "serif",
      line_width  = 0.4,
      height      = unit(0.12, "cm"),
      pad_x       = unit(0.3, "cm"),
      pad_y       = unit(0.3, "cm")
    ) +
    
    theme_natgeo() +
    coord_sf(
      xlim   = c(-124.8, -114.0),
      ylim   = c(32.5, 49.0),
      expand = FALSE
    )
  
  # =============================================================================
  # INSET MAP
  # =============================================================================
  
  usa_sf <- st_as_sf(maps::map("state", plot = FALSE, fill = TRUE)) %>%
    st_transform(4326)
  
  wc_highlight <- usa_sf %>%
    filter(ID %in% c("california", "oregon", "washington"))
  
  inset_map <- ggplot() +
    geom_sf(data = usa_sf,
            fill = parchment_dark, color = "white", linewidth = 0.2) +
    geom_sf(data = wc_highlight,
            fill = alpha(ink_brown, 0.3), color = "white", linewidth = 0.3) +
    theme_void() +
    theme(
      plot.background = element_rect(fill = parchment,
                                     color = ink_brown, linewidth = 0.6)
    ) +
    coord_sf(xlim = c(-125, -104), ylim = c(31, 50))
  
  # =============================================================================
  # STAT PANELS — always built
  # =============================================================================
  
  # --- Panel: Season Overview (always shown) ----------------------------------
  acres_display <- if_else(
    total_acres > 0,
    paste0(scales::comma(round(total_acres, 1)), " TOTAL ACRES"),
    "ACRES NOT YET REPORTED"
  )
  
  stat_overview <- ggplot() +
    annotate("text", x = 0.5, y = 0.93,
             label = paste0(format(Sys.Date(), "%Y"), " SEASON AT A GLANCE"),
             size = 3.5, fontface = "bold", family = "serif",
             color = ink_black) +
    annotate("text", x = 0.5, y = 0.78,
             label = scales::comma(n_total),
             size = 8, fontface = "bold", family = "serif",
             color = "#8B1A1A") +
    annotate("text", x = 0.5, y = 0.68,
             label = "FIRE PERIMETERS",
             size = 2.8, family = "serif", color = ink_gray) +
    annotate("segment", x = 0.1, xend = 0.9, y = 0.58, yend = 0.58,
             color = alpha(ink_brown, 0.3), linewidth = 0.3) +
    annotate("text", x = 0.25, y = 0.48,
             label = paste0(n_active, "\nACTIVE"),
             size = 3, fontface = "bold", family = "serif",
             color = "#8B1A1A", lineheight = 0.9) +
    annotate("text", x = 0.75, y = 0.48,
             label = paste0(n_contained, "\nCONTAINED"),
             size = 3, fontface = "bold", family = "serif",
             color = "#5B7E5E", lineheight = 0.9) +
    annotate("segment", x = 0.1, xend = 0.9, y = 0.35, yend = 0.35,
             color = alpha(ink_brown, 0.3), linewidth = 0.3) +
    annotate("text", x = 0.5, y = 0.25,
             label = acres_display,
             size = 2.8, fontface = "bold", family = "serif",
             color = ink_brown) +
    annotate("text", x = 0.5, y = 0.12,
             label = paste0("Updated ", format(Sys.time(), "%B %d, %Y %H:%M")),
             size = 2, family = "serif", fontface = "italic",
             color = ink_gray) +
    scale_x_continuous(limits = c(0, 1)) +
    scale_y_continuous(limits = c(0, 1)) +
    theme_void() +
    theme(
      plot.background = element_rect(fill = parchment,
                                     color = ink_brown, linewidth = 0.4),
      plot.margin = margin(6, 6, 6, 6)
    )
  
  # --- Panel: Coverage (shown early + building) -------------------------------
  stat_coverage <- ggplot() +
    annotate("text", x = 0.5, y = 0.93,
             label = "RESPONSE COVERAGE",
             size = 3.2, fontface = "bold", family = "serif",
             color = ink_black) +
    annotate("text", x = 0.5, y = 0.78,
             label = paste0(median_dist, " km"),
             size = 7, fontface = "bold", family = "serif",
             color = ink_brown) +
    annotate("text", x = 0.5, y = 0.68,
             label = "MEDIAN DISTANCE TO STATION",
             size = 2.3, family = "serif", color = ink_gray) +
    annotate("segment", x = 0.1, xend = 0.9, y = 0.58, yend = 0.58,
             color = alpha(ink_brown, 0.3), linewidth = 0.3) +
    annotate("text", x = 0.5, y = 0.48,
             label = paste0(n_over_50, " FIRES BEYOND 50KM"),
             size = 2.8, fontface = "bold", family = "serif",
             color = "#8B1A1A") +
    annotate("text", x = 0.5, y = 0.38,
             label = paste0(pct_over_50, "% of all ",
                            format(Sys.Date(), "%Y"), " fires"),
             size = 2.3, family = "serif", color = ink_gray) +
    annotate("segment", x = 0.1, xend = 0.9, y = 0.28, yend = 0.28,
             color = alpha(ink_brown, 0.3), linewidth = 0.3) +
    annotate("text", x = 0.5, y = 0.15,
             label = "Straight-line, perimeter edge to station",
             size = 2, family = "serif", fontface = "italic",
             color = ink_gray) +
    scale_x_continuous(limits = c(0, 1)) +
    scale_y_continuous(limits = c(0, 1)) +
    theme_void() +
    theme(
      plot.background = element_rect(fill = parchment,
                                     color = ink_brown, linewidth = 0.4),
      plot.margin = margin(6, 6, 6, 6)
    )
  
  # --- Panel: State Breakdown (shown early only) ------------------------------
  state_label_text <- state_ytd_stats %>%
    mutate(
      line = paste0(
        toupper(state), "\n",
        n_fires, " fires  |  ",
        n_active, " active  |  ",
        format_acres(total_acres), " ac"
      )
    ) %>%
    pull(line) %>%
    paste(collapse = "\n\n")
  
  stat_states <- ggplot() +
    annotate("text", x = 0.5, y = 0.93,
             label = "BY STATE",
             size = 3.2, fontface = "bold", family = "serif",
             color = ink_black) +
    annotate("text", x = 0.08, y = 0.50, hjust = 0,
             label = state_label_text,
             size = 2.5, family = "serif", color = ink_brown,
             lineheight = 1.2) +
    annotate("text", x = 0.5, y = 0.08,
             label = paste0("CA/OR/WA | ", format(Sys.Date(), "%Y"),
                            " season to date"),
             size = 2, family = "serif", fontface = "italic",
             color = ink_gray) +
    scale_x_continuous(limits = c(0, 1)) +
    scale_y_continuous(limits = c(0, 1)) +
    theme_void() +
    theme(
      plot.background = element_rect(fill = parchment,
                                     color = ink_brown, linewidth = 0.4),
      plot.margin = margin(6, 6, 6, 6)
    )
  
  # --- Panel: Top Stations (shown building + peak) ---------------------------
  if (n_total >= 10) {
    
    station_label_text <- station_burden_ytd %>%
      mutate(
        active_tag = if_else(n_active > 0,
                             paste0(n_active, " active"),
                             "all contained"),
        line = paste0(
          toupper(nearest_station_name), "\n",
          n_fires, " fires  |  ", active_tag, "\n",
          format_acres(total_acres), " ac  |  ",
          mean_dist, " km avg"
        )
      ) %>%
      pull(line) %>%
      paste(collapse = "\n\n")
    
    stat_stations <- ggplot() +
      annotate("text", x = 0.5, y = 0.95,
               label = "MOST BURDENED STATIONS",
               size = 3.2, fontface = "bold", family = "serif",
               color = ink_black) +
      annotate("text", x = 0.08, y = 0.48, hjust = 0,
               label = station_label_text,
               size = 2.2, family = "serif", color = ink_brown,
               lineheight = 1.15) +
      annotate("text", x = 0.5, y = 0.03,
               label = "Ranked by number of fires as nearest station",
               size = 1.8, family = "serif", fontface = "italic",
               color = ink_gray) +
      scale_x_continuous(limits = c(0, 1)) +
      scale_y_continuous(limits = c(0, 1)) +
      theme_void() +
      theme(
        plot.background = element_rect(fill = parchment,
                                       color = ink_brown, linewidth = 0.4),
        plot.margin = margin(6, 6, 6, 6)
      )
  } else {
    stat_stations <- NULL
  }
  
  # --- Panel: Worst Counties (shown peak only) --------------------------------
  if (n_total >= 50) {
    
    county_label_text <- county_burden_ytd %>%
      mutate(
        line = paste0(
          toupper(NAME), " (", state, ")\n",
          n_fires, " fires  |  ",
          format_acres(total_acres), " ac  |  ",
          median_dist, " km median",
          if_else(pct_over_50 > 0,
                  paste0("  |  ", pct_over_50, "% >50km"),
                  "")
        )
      ) %>%
      pull(line) %>%
      paste(collapse = "\n\n")
    
    stat_counties <- ggplot() +
      annotate("text", x = 0.5, y = 0.95,
               label = "WORST COVERAGE COUNTIES",
               size = 3.2, fontface = "bold", family = "serif",
               color = ink_black) +
      annotate("text", x = 0.08, y = 0.48, hjust = 0,
               label = county_label_text,
               size = 2.2, family = "serif", color = ink_brown,
               lineheight = 1.15) +
      annotate("text", x = 0.5, y = 0.03,
               label = "Ranked by median distance to nearest station",
               size = 1.8, family = "serif", fontface = "italic",
               color = ink_gray) +
      scale_x_continuous(limits = c(0, 1)) +
      scale_y_continuous(limits = c(0, 1)) +
      theme_void() +
      theme(
        plot.background = element_rect(fill = parchment,
                                       color = ink_brown, linewidth = 0.4),
        plot.margin = margin(6, 6, 6, 6)
      )
  } else {
    stat_counties <- NULL
  }
  
  # =============================================================================
  # TITLE BAR
  # =============================================================================
  
  title_bar <- ggplot() +
    annotate("rect", xmin = 0, xmax = 1, ymin = 0, ymax = 1,
             fill = natgeo_yellow) +
    annotate("text", x = 0.03, y = 0.55,
             label = paste0(format(Sys.Date(), "%Y"),
                            " WEST COAST WILDFIRE SEASON"),
             size = 7, fontface = "bold", family = "serif",
             color = ink_black, hjust = 0) +
    annotate("text", x = 0.97, y = 0.55,
             label = "YEAR TO DATE",
             size = 4, fontface = "bold", family = "serif",
             color = alpha(ink_black, 0.5), hjust = 1) +
    scale_x_continuous(limits = c(0, 1), expand = c(0, 0)) +
    scale_y_continuous(limits = c(0, 1), expand = c(0, 0)) +
    theme_void() +
    theme(plot.margin = margin(0, 0, 0, 0))
  
  # =============================================================================
  # SUBTITLE BAR
  # =============================================================================
  
  subtitle_bar <- ggplot() +
    annotate("rect", xmin = 0, xmax = 1, ymin = 0, ymax = 1,
             fill = parchment) +
    annotate("text", x = 0.03, y = 0.5,
             label = paste0(
               scales::comma(n_total), " fire perimeters across California, ",
               "Oregon, and Washington as of ",
               format(Sys.Date(), "%B %d, %Y"), ". ",
               n_active, " fires remain active",
               if_else(total_acres > 0,
                       paste0(" covering ",
                              scales::comma(round(total_acres, 1)),
                              " total acres"),
                       ""),
               ". Median distance to nearest station: ", median_dist, " km."
             ),
             size = 3.2, family = "serif", color = ink_brown,
             hjust = 0, vjust = 0.5) +
    scale_x_continuous(limits = c(0, 1), expand = c(0, 0)) +
    scale_y_continuous(limits = c(0, 1), expand = c(0, 0)) +
    theme_void() +
    theme(plot.margin = margin(0, 0, 0, 0))
  
  # =============================================================================
  # LEGEND STRIP
  # =============================================================================
  
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
  
  # =============================================================================
  # CAPTION BAR
  # =============================================================================
  
  caption_bar <- ggplot() +
    annotate("rect", xmin = 0, xmax = 1, ymin = 0, ymax = 1,
             fill = parchment) +
    annotate("text", x = 0.03, y = 0.5,
             label = paste0(
               "DATA: NIFC WFIGS YTD perimeters + OpenStreetMap fire stations  |  ",
               "All perimeter types (initial through final)  |  ",
               "Straight-line distances  |  ",
               "Acreage: best of IncidentSize / GISAcres  |  ",
               "Analysis by B. Groves  |  ",
               format(Sys.time(), "%B %d, %Y %H:%M")
             ),
             size = 2.3, family = "serif", color = ink_gray,
             hjust = 0) +
    annotate("rect", xmin = 0, xmax = 1, ymin = 0, ymax = 0.15,
             fill = natgeo_yellow) +
    scale_x_continuous(limits = c(0, 1), expand = c(0, 0)) +
    scale_y_continuous(limits = c(0, 1), expand = c(0, 0)) +
    theme_void() +
    theme(plot.margin = margin(0, 0, 0, 0))
  
  # =============================================================================
  # ADAPTIVE SIDEBAR LAYOUT
  # =============================================================================
  
  message("Assembling NatGeo YTD layout (", season_stage, " season)...")
  
  if (season_stage == "early") {
    # Early: Overview + Coverage + States + Inset
    right_sidebar <- cowplot::plot_grid(
      stat_overview,
      stat_coverage,
      stat_states,
      inset_map,
      ncol = 1,
      rel_heights = c(0.28, 0.28, 0.27, 0.17)
    )
    cat("Sidebar: Overview + Coverage + States + Inset\n")
    
  } else if (season_stage == "building") {
    # Building: Overview + Coverage + Top Stations + Inset
    right_sidebar <- cowplot::plot_grid(
      stat_overview,
      stat_coverage,
      stat_stations,
      inset_map,
      ncol = 1,
      rel_heights = c(0.25, 0.25, 0.33, 0.17)
    )
    cat("Sidebar: Overview + Coverage + Top Stations + Inset\n")
    
  } else {
    # Peak: Overview + Top Stations + Worst Counties + Inset
    right_sidebar <- cowplot::plot_grid(
      stat_overview,
      stat_stations,
      stat_counties,
      inset_map,
      ncol = 1,
      rel_heights = c(0.22, 0.30, 0.30, 0.18)
    )
    cat("Sidebar: Overview + Top Stations + Worst Counties + Inset\n")
  }
  
  # Map + sidebar
  map_row <- cowplot::plot_grid(
    main_map,
    right_sidebar,
    ncol = 2,
    rel_widths = c(0.72, 0.28)
  )
  
  # Full stack
  full_layout <- cowplot::plot_grid(
    title_bar,
    subtitle_bar,
    legend_strip,
    map_row,
    caption_bar,
    ncol = 1,
    rel_heights = c(0.05, 0.04, 0.025, 0.855, 0.03)
  )
  
  print(full_layout)
  
  # =============================================================================
  # SAVE
  # =============================================================================
  
  out_file <- paste0(wc_output_dir, "ytd_natgeo_",
                     format(Sys.Date(), "%Y%m%d"), ".png")
  
  ggsave(
    out_file,
    plot   = full_layout,
    width  = 18,
    height = 14,
    dpi    = 300,
    bg     = parchment
  )
  
  cat("NatGeo YTD map saved to:", out_file, "\n")
  
  file.copy(out_file, "output/figures/ytd_natgeo.png", overwrite = TRUE)
  cat("Copied to output/figures/ytd_natgeo.png\n")
  
  cat("\n--- NatGeo YTD Complete ---\n")
  cat("Season stage:", season_stage, "\n")
  cat("Total fires:", n_total, "\n")
  cat("Active:", n_active, "| Contained:", n_contained, "\n")
  cat("Total acres:", scales::comma(round(total_acres, 1)), "\n")
  cat("Panels:", case_when(
    season_stage == "early"    ~ "Overview + Coverage + States",
    season_stage == "building" ~ "Overview + Coverage + Top Stations",
    season_stage == "peak"     ~ "Overview + Top Stations + Worst Counties"
  ), "\n")
  cat("Re-run this script anytime for fresh data\n")
  
} # end else block