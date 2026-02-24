# =============================================================================
# 16_west_coast_ytd_maps.R
# Current fire season maps — designed to be re-run for live updates
#
# Produces up to 3 maps:
#   1. ytd_overview       - Active vs contained, all current fires
#   2. ytd_coverage       - Distance to nearest station (color-coded)
#   3. ytd_active_detail  - Zoom panels for top active fires
#
# Run workflow:
#   source("R/13_west_coast_ytd.R")   # fresh API pull
#   source("R/16_west_coast_ytd_maps.R")  # build maps
#
# Off-season: exits gracefully with message
#
# Outputs:
#   ytd_overview_YYYYMMDD.png
#   ytd_coverage_YYYYMMDD.png
#   ytd_active_detail_YYYYMMDD.png (if active fires exist)
#
# Depends on: 07-09 (study area + stations), 13 (YTD data)
# =============================================================================

# --- Dependencies -----------------------------------------------------------
if (!exists("all_stations_wc_clean")) {
  message("Running dependency scripts first...")
  source("R/01_setup.R")
  source("R/07_west_coast_setup.R")
  source("R/08_west_coast_study_area.R")
  source("R/09_west_coast_stations.R")
}

# --- Fresh YTD data ---------------------------------------------------------
if (!exists("fires_ytd_dist")) {
  message("Running YTD fetch (script 13)...")
  source("R/13_west_coast_ytd.R")
}

# --- Off-season guard -------------------------------------------------------
if (!exists("fires_ytd_dist") || is.null(fires_ytd_dist) ||
    nrow(fires_ytd_dist) == 0) {
  
  message("
  ============================================================
  No YTD fire data available - skipping YTD maps
  Expected outside of fire season (Nov-May)
  Re-run during fire season for live maps
  ============================================================
  ")
  
} else {
  
  # State labels — reusable across all YTD maps
  state_labels <- tibble(
    NAME = c("Washington", "Oregon", "California"),
    lon  = c(-120.5, -120.8, -119.5),
    lat  = c(47.5,    43.8,   37.2)
  )
  
  # --- Prep map data — st_as_sf() on everything to prevent class errors -----
  states_4326   <- westcoast_states %>% st_as_sf() %>% st_transform(4326)
  counties_4326 <- westcoast_counties %>% st_as_sf() %>% st_transform(4326)
  stations_4326 <- all_stations_wc_clean %>% st_as_sf() %>% st_transform(4326)
  
  fires_ytd_4326 <- fires_ytd_dist %>%
    st_as_sf() %>%
    st_transform(4326) %>%
    mutate(
      is_active = is.na(attr_PercentContained) | attr_PercentContained < 100,
      size_label = case_when(
        attr_IncidentSize >= 100000 ~ "100k+ ac",
        attr_IncidentSize >= 10000  ~ "10k+ ac",
        attr_IncidentSize >= 1000   ~ "1k+ ac",
        TRUE                        ~ "<1k ac"
      ),
      dist_category = case_when(
        dist_nearest_km >= 100 ~ "Extreme (100km+)",
        dist_nearest_km >= 50  ~ "Critical (50-100km)",
        dist_nearest_km >= 25  ~ "Poor (25-50km)",
        dist_nearest_km >= 10  ~ "Moderate (10-25km)",
        TRUE                   ~ "Good (<10km)"
      ) %>% factor(levels = c("Good (<10km)", "Moderate (10-25km)",
                              "Poor (25-50km)", "Critical (50-100km)",
                              "Extreme (100km+)"))
    )
  
  cat("YTD fires for mapping:", nrow(fires_ytd_4326), "\n")
  cat("Active:", sum(fires_ytd_4326$is_active), "\n")
  cat("Contained:", sum(!fires_ytd_4326$is_active), "\n")
  
  # --- Fires worth labeling — top fires by size ---
  n_label <- min(12, nrow(fires_ytd_4326))
  
  label_fires_spatial <- fires_ytd_4326 %>%
    arrange(desc(attr_IncidentSize)) %>%
    slice_head(n = n_label)
  
  label_fires <- label_fires_spatial %>%
    st_centroid() %>%
    st_coordinates() %>%
    as_tibble() %>%
    bind_cols(
      label_fires_spatial %>%
        st_drop_geometry() %>%
        select(attr_IncidentName, attr_IncidentSize,
               attr_PercentContained, dist_nearest_km,
               is_active, nearest_station_name)
    ) %>%
    rename(lon = X, lat = Y) %>%
    mutate(
      label = paste0(
        attr_IncidentName, "\n",
        scales::comma(round(attr_IncidentSize)), " ac",
        if_else(is_active, " \u2022 ACTIVE", "")
      )
    )
  
  cat("YTD fires to label:", nrow(label_fires), "\n")
  
  # --- Nearest station coords for connector lines ---
  station_coords <- stations_4326 %>%
    st_coordinates() %>%
    as_tibble() %>%
    bind_cols(stations_4326 %>% st_drop_geometry() %>% select(name)) %>%
    rename(stn_lon = X, stn_lat = Y)
  
  label_stations <- label_fires %>%
    left_join(station_coords, by = c("nearest_station_name" = "name"))
  
  # =========================================================================
  # MAP 1: YTD Overview — all fires, colored by active/contained
  # =========================================================================
  
  message("Building YTD overview map...")
  
  ytd_overview_map <- ggplot() +
    
    # County base
    geom_sf(data = counties_4326,
            fill = "gray95", color = "gray80", linewidth = 0.12) +
    
    # State borders
    geom_sf(data = states_4326,
            fill = NA, color = "gray25", linewidth = 0.7) +
    
    # Stations
    geom_sf(data = stations_4326,
            color = alpha("gray40", 0.3), size = 0.3, shape = 17) +
    
    # Fire perimeters — contained first, active on top
    geom_sf(data = fires_ytd_4326 %>% filter(!is_active),
            fill = alpha("steelblue", 0.35), color = "gray50",
            linewidth = 0.15) +
    geom_sf(data = fires_ytd_4326 %>% filter(is_active),
            fill = alpha("firebrick", 0.5), color = "darkred",
            linewidth = 0.3) +
    
    # Fire labels
    ggrepel::geom_label_repel(
      data = label_fires,
      aes(x = lon, y = lat, label = label),
      size               = 2.3,
      fontface           = "bold",
      fill               = alpha("white", 0.85),
      color              = if_else(label_fires$is_active,
                                   "firebrick", "gray30"),
      label.size         = 0.2,
      label.padding      = unit(0.15, "lines"),
      box.padding        = unit(0.8, "lines"),
      point.padding      = unit(0.3, "lines"),
      min.segment.length = 0,
      segment.color      = "gray50",
      segment.size       = 0.3,
      max.overlaps       = 20,
      seed               = 42,
      force              = 5,
      force_pull         = 0.3
    ) +
    
    # State labels
    geom_text(
      data = state_labels,
      aes(x = lon, y = lat, label = NAME),
      size = 5, fontface = "bold",
      color = alpha("gray25", 0.6)
    ) +
    
    ggspatial::annotation_scale(
      location = "bl", width_hint = 0.15, text_cex = 0.7
    ) +
    ggspatial::annotation_north_arrow(
      location = "bl", pad_y = unit(0.5, "cm"),
      style = ggspatial::north_arrow_fancy_orienteering(text_size = 8)
    ) +
    
    labs(
      title    = paste0(format(Sys.Date(), "%Y"),
                        " West Coast Fire Season \u2014 Year to Date"),
      subtitle = paste0(
        "Red = active fires  |  Blue = contained  |  ",
        "\u25B2 = fire stations\n",
        sum(fires_ytd_4326$is_active), " active  |  ",
        sum(!fires_ytd_4326$is_active), " contained  |  ",
        scales::comma(sum(fires_ytd_4326$attr_IncidentSize, na.rm = TRUE)),
        " total acres  |  Updated ",
        format(Sys.time(), "%B %d, %Y %H:%M")
      ),
      caption = paste0(
        "Source: NIFC WFIGS YTD perimeters  |  ",
        "All perimeter types (initial through final)  |  ",
        "Straight-line distance, perimeter edge to station"
      )
    ) +
    theme_void(base_size = 12) +
    theme(
      plot.title      = element_text(size = 18, face = "bold",
                                     margin = margin(b = 3)),
      plot.subtitle   = element_text(size = 10, color = "gray30",
                                     lineheight = 1.3,
                                     margin = margin(b = 8)),
      plot.caption    = element_text(size = 8, color = "gray50",
                                     hjust = 0, margin = margin(t = 10)),
      plot.background = element_rect(fill = "white", color = NA),
      plot.margin     = margin(15, 15, 10, 15)
    ) +
    coord_sf(
      xlim = c(-124.8, -114.0), ylim = c(32.5, 49.0),
      expand = FALSE
    )
  
  # =========================================================================
  # MAP 2: YTD Coverage Gaps — colored by distance to nearest station
  # =========================================================================
  
  message("Building YTD coverage map...")
  
  dist_cat_colors <- c(
    "Good (<10km)"        = "steelblue",
    "Moderate (10-25km)"  = "goldenrod",
    "Poor (25-50km)"      = "darkorange",
    "Critical (50-100km)" = "orangered",
    "Extreme (100km+)"    = "darkred"
  )
  
  isolated_lines <- label_stations %>%
    filter(dist_nearest_km >= 25, !is.na(stn_lon))
  
  ytd_coverage_map <- ggplot() +
    
    # County base
    geom_sf(data = counties_4326,
            fill = "gray95", color = "gray80", linewidth = 0.12) +
    
    # State borders
    geom_sf(data = states_4326,
            fill = NA, color = "gray25", linewidth = 0.7) +
    
    # Stations
    geom_sf(data = stations_4326,
            color = alpha("gray40", 0.3), size = 0.3, shape = 17) +
    
    # Fire perimeters — colored by distance category
    geom_sf(data = fires_ytd_4326,
            aes(fill = dist_category),
            color = "gray40", linewidth = 0.15, alpha = 0.6) +
    scale_fill_manual(
      values = dist_cat_colors,
      name   = "Distance to\nNearest Station",
      drop   = FALSE
    ) +
    
    # Connector lines from isolated fires to nearest station
    {
      if (nrow(isolated_lines) > 0) {
        geom_segment(
          data = isolated_lines,
          aes(x = lon, y = lat, xend = stn_lon, yend = stn_lat),
          color = alpha("firebrick", 0.4),
          linewidth = 0.4, linetype = "dashed"
        )
      }
    } +
    
    # Fire labels — show distance
    ggrepel::geom_label_repel(
      data = label_fires %>%
        mutate(
          dist_label = paste0(
            attr_IncidentName, "\n",
            round(dist_nearest_km, 0), " km to ",
            nearest_station_name
          )
        ),
      aes(x = lon, y = lat, label = dist_label),
      size               = 2.1,
      fontface           = "bold",
      fill               = alpha("white", 0.85),
      color              = "gray20",
      label.size         = 0.2,
      label.padding      = unit(0.15, "lines"),
      box.padding        = unit(0.8, "lines"),
      min.segment.length = 0,
      segment.color      = "gray50",
      segment.size       = 0.3,
      max.overlaps       = 15,
      seed               = 42,
      force              = 5,
      force_pull         = 0.3
    ) +
    
    # State labels
    geom_text(
      data = state_labels,
      aes(x = lon, y = lat, label = NAME),
      size = 5, fontface = "bold",
      color = alpha("gray25", 0.6)
    ) +
    
    ggspatial::annotation_scale(
      location = "bl", width_hint = 0.15, text_cex = 0.7
    ) +
    ggspatial::annotation_north_arrow(
      location = "bl", pad_y = unit(0.5, "cm"),
      style = ggspatial::north_arrow_fancy_orienteering(text_size = 8)
    ) +
    
    labs(
      title    = paste0(format(Sys.Date(), "%Y"),
                        " West Coast Fire Season \u2014 Response Coverage"),
      subtitle = paste0(
        "Fire perimeters colored by distance to nearest station\n",
        "Dashed lines connect isolated fires (>25km) to their nearest station\n",
        "Median distance: ",
        round(median(fires_ytd_4326$dist_nearest_km), 1), " km  |  ",
        sum(fires_ytd_4326$dist_nearest_km >= 50),
        " fires >50km from any station"
      ),
      caption = paste0(
        "Source: NIFC WFIGS YTD perimeters  |  ",
        nrow(fires_ytd_4326), " perimeters as of ",
        format(Sys.time(), "%B %d, %Y %H:%M"),
        "  |  Straight-line distance, perimeter edge to station"
      )
    ) +
    theme_void(base_size = 12) +
    theme(
      plot.title      = element_text(size = 18, face = "bold",
                                     margin = margin(b = 3)),
      plot.subtitle   = element_text(size = 10, color = "gray30",
                                     lineheight = 1.3,
                                     margin = margin(b = 8)),
      plot.caption    = element_text(size = 8, color = "gray50",
                                     hjust = 0, margin = margin(t = 10)),
      plot.background = element_rect(fill = "white", color = NA),
      plot.margin     = margin(15, 15, 10, 15),
      legend.position   = c(0.08, 0.45),
      legend.background = element_rect(fill = alpha("white", 0.9),
                                       color = "gray80", linewidth = 0.3),
      legend.margin     = margin(6, 8, 6, 8),
      legend.key.size   = unit(0.5, "cm"),
      legend.title      = element_text(size = 9, face = "bold"),
      legend.text       = element_text(size = 8)
    ) +
    coord_sf(
      xlim = c(-124.8, -114.0), ylim = c(32.5, 49.0),
      expand = FALSE
    )
  
  # =========================================================================
  # MAP 3: Active fire zoom panels (if active fires exist)
  # =========================================================================
  
  n_active <- sum(fires_ytd_4326$is_active)
  
  if (n_active > 0) {
    
    message("Building active fire zoom panels (", n_active, " active)...")
    
    top_active <- fires_ytd_4326 %>%
      filter(is_active) %>%
      arrange(desc(attr_IncidentSize)) %>%
      slice_head(n = min(4, n_active))
    
    zoom_panels <- lapply(seq_len(nrow(top_active)), function(i) {
      
      fire_i <- top_active[i, ]
      
      fire_buff <- fire_i %>%
        st_transform(wc_crs) %>%
        st_buffer(50000)
      fire_bbox_4326 <- fire_buff %>%
        st_transform(4326) %>%
        st_bbox()
      
      nearby_stations <- stations_4326 %>%
        st_crop(fire_bbox_4326)
      
      nearest_stn <- stations_4326 %>%
        filter(name == fire_i$nearest_station_name)
      
      fire_centroid <- fire_i %>% st_centroid()
      fire_xy <- st_coordinates(fire_centroid)
      
      p <- ggplot() +
        geom_sf(data = counties_4326 %>% st_crop(fire_bbox_4326),
                fill = "gray95", color = "gray80", linewidth = 0.2) +
        geom_sf(data = states_4326 %>% st_crop(fire_bbox_4326),
                fill = NA, color = "gray25", linewidth = 0.5) +
        geom_sf(data = nearby_stations,
                color = "gray40", size = 2, shape = 17)
      
      if (nrow(nearest_stn) > 0) {
        stn_xy <- st_coordinates(nearest_stn)
        p <- p +
          geom_sf(data = nearest_stn,
                  color = "gold", size = 4, shape = 17) +
          geom_sf(data = nearest_stn,
                  color = "black", size = 4.5, shape = 2) +
          geom_segment(
            aes(x = fire_xy[1, 1], y = fire_xy[1, 2],
                xend = stn_xy[1, 1], yend = stn_xy[1, 2]),
            color = "firebrick", linewidth = 0.6, linetype = "dashed"
          )
      }
      
      p <- p +
        geom_sf(data = fire_i,
                fill = alpha("firebrick", 0.4), color = "darkred",
                linewidth = 0.5) +
        ggspatial::annotation_scale(
          location = "br", width_hint = 0.25, text_cex = 0.6,
          line_width = 0.4, height = unit(0.1, "cm")
        ) +
        labs(
          title = paste0(
            fire_i$attr_IncidentName, "  \u2022  ",
            scales::comma(round(fire_i$attr_IncidentSize)), " ac"
          ),
          subtitle = paste0(
            round(fire_i$dist_nearest_km, 1), " km to ",
            fire_i$nearest_station_name,
            if_else(!is.na(fire_i$attr_PercentContained),
                    paste0("  |  ", fire_i$attr_PercentContained,
                           "% contained"),
                    "  |  Containment unknown")
          )
        ) +
        theme_void(base_size = 10) +
        theme(
          plot.title      = element_text(size = 11, face = "bold",
                                         margin = margin(b = 2)),
          plot.subtitle   = element_text(size = 8, color = "gray40"),
          plot.background = element_rect(fill = "white",
                                         color = "gray70",
                                         linewidth = 0.5),
          plot.margin     = margin(8, 8, 5, 8)
        ) +
        coord_sf(
          xlim = c(fire_bbox_4326["xmin"], fire_bbox_4326["xmax"]),
          ylim = c(fire_bbox_4326["ymin"], fire_bbox_4326["ymax"]),
          expand = FALSE
        )
      
      return(p)
    })
    
    zoom_grid <- cowplot::plot_grid(
      plotlist = zoom_panels,
      ncol = 2
    )
    
    zoom_title <- cowplot::ggdraw() +
      cowplot::draw_label(
        paste0("Active Fire Detail \u2014 ",
               format(Sys.Date(), "%B %d, %Y")),
        fontface = "bold", size = 16, x = 0.02, hjust = 0
      ) +
      cowplot::draw_label(
        paste0("50km radius around each fire  |  ",
               "Gold triangle = nearest station  |  ",
               "Dashed line = distance to response"),
        size = 9, color = "gray40", x = 0.02, y = 0.25, hjust = 0
      )
    
    ytd_zoom_map <- cowplot::plot_grid(
      zoom_title,
      zoom_grid,
      ncol = 1,
      rel_heights = c(0.06, 0.94)
    )
    
  } else {
    message("No active fires \u2014 skipping zoom panels")
    ytd_zoom_map <- NULL
  }
  
  # =========================================================================
  # PRINT + SAVE
  # =========================================================================
  
  print(ytd_overview_map)
  print(ytd_coverage_map)
  
  ytd_overview_file <- paste0(wc_output_dir, "ytd_overview_",
                              format(Sys.Date(), "%Y%m%d"), ".png")
  ggsave(ytd_overview_file, plot = ytd_overview_map,
         width = 14, height = 18, dpi = 300, bg = "white")
  cat("Saved:", ytd_overview_file, "\n")
  
  ytd_coverage_file <- paste0(wc_output_dir, "ytd_coverage_",
                              format(Sys.Date(), "%Y%m%d"), ".png")
  ggsave(ytd_coverage_file, plot = ytd_coverage_map,
         width = 14, height = 18, dpi = 300, bg = "white")
  cat("Saved:", ytd_coverage_file, "\n")
  
  if (!is.null(ytd_zoom_map)) {
    print(ytd_zoom_map)
    ytd_zoom_file <- paste0(wc_output_dir, "ytd_active_detail_",
                            format(Sys.Date(), "%Y%m%d"), ".png")
    ggsave(ytd_zoom_file, plot = ytd_zoom_map,
           width = 14, height = 14, dpi = 300, bg = "white")
    cat("Saved:", ytd_zoom_file, "\n")
  }
  
  # Copy to output/figures/ for GitHub
  for (f in c("ytd_overview", "ytd_coverage")) {
    src <- paste0(wc_output_dir, f, "_",
                  format(Sys.Date(), "%Y%m%d"), ".png")
    if (file.exists(src)) {
      file.copy(src, paste0("output/figures/", f, ".png"),
                overwrite = TRUE)
      cat("Copied to output/figures/", f, ".png\n")
    }
  }
  
  if (!is.null(ytd_zoom_map)) {
    src <- paste0(wc_output_dir, "ytd_active_detail_",
                  format(Sys.Date(), "%Y%m%d"), ".png")
    if (file.exists(src)) {
      file.copy(src, "output/figures/ytd_active_detail.png",
                overwrite = TRUE)
      cat("Copied to output/figures/ytd_active_detail.png\n")
    }
  }
  
  cat("\n--- YTD Maps Produced ---\n")
  cat("1. ytd_overview       - Active vs contained, all fires\n")
  cat("2. ytd_coverage       - Distance to nearest station\n")
  if (!is.null(ytd_zoom_map)) {
    cat("3. ytd_active_detail  - Zoom panels for top active fires\n")
  }
  cat("All saved to:", wc_output_dir, "\n")
  
} # end YTD else block