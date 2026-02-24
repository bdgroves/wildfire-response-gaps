# =============================================================================
# Helper function: build state coverage map
# Reusable for any state in the West Coast dataset
# =============================================================================

build_state_map <- function(state_name, state_abbr, 
                            nudge_x = 1.5, nudge_y = 0.8,
                            xlim = NULL, ylim = NULL) {
  
  message("Building map for ", state_name, "...")
  
  # --- Data prep -------------------------------------------------------------
  state_counties_sf <- westcoast_counties %>%
    filter(state_abbr == !!state_abbr) %>%
    st_as_sf()
  
  state_fire_stats <- fires_summary_df %>%
    filter(state == state_name) %>%
    group_by(fips) %>%
    summarise(
      n_fires      = n(),
      total_acres  = sum(acres,    na.rm = TRUE),
      mean_dist_km = round(mean(dist_km), 1),
      max_dist_km  = round(max(dist_km),  1),
      .groups      = "drop"
    )
  
  state_map_data <- state_counties_sf %>%
    left_join(state_fire_stats, by = c("GEOID" = "fips")) %>%
    st_as_sf() %>%
    mutate(
      n_fires     = replace_na(n_fires,     0),
      total_acres = replace_na(total_acres, 0),
      has_fires   = n_fires > 0
    ) %>%
    st_transform(4326)
  
  state_fires_sf <- fires_wc_with_dist %>%
    filter(attr_POOState == paste0("US-", state_abbr)) %>%
    st_as_sf() %>%
    st_transform(4326) %>%
    mutate(
      is_isolated      = dist_nearest_km >= 50,
      is_very_isolated = dist_nearest_km >= 100
    )
  
  state_stations_sf <- all_stations_wc_clean %>%
    st_as_sf() %>%
    st_filter(state_counties_sf %>% st_union()) %>%
    st_transform(4326)
  
  # Most burdened station in this state
  top_station <- fires_summary_df %>%
    filter(state == state_name) %>%
    count(nearest_station, sort = TRUE) %>%
    slice(1)
  
  top_station_sf <- state_stations_sf %>%
    filter(name == top_station$nearest_station) %>%
    st_as_sf()
  
  other_stations_sf <- state_stations_sf %>%
    filter(name != top_station$nearest_station) %>%
    st_as_sf()
  
  cat(state_name, "- counties:", nrow(state_map_data),
      "| fires:", nrow(state_fires_sf),
      "| stations:", nrow(state_stations_sf), "\n")
  cat("Top station:", top_station$nearest_station,
      "(", top_station$n, "fires)\n")
  
  # Key fires to label
  key_fires_labels <- fires_wc_with_dist %>%
    filter(attr_POOState == paste0("US-", state_abbr)) %>%
    st_as_sf() %>%
    st_transform(4326) %>%
    st_centroid() %>%
    st_coordinates() %>%
    as_tibble() %>%
    bind_cols(
      fires_wc_with_dist %>%
        filter(attr_POOState == paste0("US-", state_abbr)) %>%
        st_drop_geometry() %>%
        select(attr_IncidentName, attr_IncidentSize, dist_nearest_km)
    ) %>%
    filter(attr_IncidentSize >= 100000) %>%
    rename(lon = X, lat = Y)
  
  cat("Key fires to label:", nrow(key_fires_labels), "\n")
  
  # Top station annotation
  top_station_label <- top_station_sf %>%
    st_coordinates() %>%
    as_tibble() %>%
    mutate(label = paste0(
      top_station$nearest_station, "\n",
      top_station$n, " fires as nearest station"
    ))
  
  # State summary stats for subtitle
  state_stats <- fires_summary_df %>%
    filter(state == state_name) %>%
    summarise(
      median_dist  = round(median(dist_km), 1),
      pct_critical = round(mean(is_isolated) * 100, 1),
      total_fires  = n(),
      total_acres  = comma(round(sum(acres, na.rm = TRUE)))
    )
  
  # Set default coord limits from data if not provided
  if (is.null(xlim) | is.null(ylim)) {
    bbox <- st_bbox(state_map_data)
    xlim <- c(bbox["xmin"] - 0.5, bbox["xmax"] + 0.5)
    ylim <- c(bbox["ymin"] - 0.5, bbox["ymax"] + 0.5)
  }
  
  # --- Build map -------------------------------------------------------------
  state_main_map <- ggplot() +
    
    geom_sf(data  = state_map_data %>% filter(!has_fires) %>% st_as_sf(),
            fill  = "gray92", color = "white", linewidth = 0.2) +
    geom_sf(data  = state_map_data %>% filter(has_fires) %>% st_as_sf(),
            aes(fill = mean_dist_km),
            color = "white", linewidth = 0.2) +
    scale_fill_gradientn(
      colors   = distance_colors,
      name     = "Mean Distance to\nNearest Station (km)",
      na.value = "gray92",
      breaks   = c(0, 25, 50, 75, 100, 125),
      labels   = c("0", "25", "50", "75", "100", "125+")
    ) +
    
    # Fire perimeters colored by isolation level
    geom_sf(data  = state_fires_sf %>%
              filter(!is_isolated) %>% st_as_sf(),
            fill  = "steelblue", color = NA, alpha = 0.4) +
    geom_sf(data  = state_fires_sf %>%
              filter(is_isolated, !is_very_isolated) %>% st_as_sf(),
            fill  = "orange", color = NA, alpha = 0.5) +
    geom_sf(data  = state_fires_sf %>%
              filter(is_very_isolated) %>% st_as_sf(),
            fill  = "firebrick", color = "darkred",
            linewidth = 0.1, alpha = 0.6) +
    
    # All stations - small gray triangles
    geom_sf(data  = other_stations_sf,
            color = "gray30", size = 0.8, shape = 17, alpha = 0.6) +
    
    # Top station - gold highlighted
    geom_sf(data  = top_station_sf,
            color = "black", size = 5.5, shape = 2) +
    geom_sf(data  = top_station_sf,
            color = "gold",  size = 5.0, shape = 17) +
    
    # County borders
    geom_sf(data  = state_map_data %>% st_as_sf(),
            fill  = NA, color = "gray50", linewidth = 0.3) +
    
    # Large fire labels
    ggrepel::geom_label_repel(
      data          = key_fires_labels,
      aes(x = lon, y = lat,
          label = paste0(attr_IncidentName, "\n",
                         comma(round(attr_IncidentSize)), " ac")),
      size          = 2.8, fontface = "bold",
      fill          = alpha("white", 0.8), color = "firebrick",
      label.size    = 0.2, box.padding = 0.5, max.overlaps = 15,
      segment.color = "firebrick", segment.alpha = 0.6
    ) +
    
    # Top station annotation
    ggrepel::geom_label_repel(
      data          = top_station_label,
      aes(x = X, y = Y, label = label),
      size          = 3.2, fontface = "bold",
      fill          = alpha("gold", 0.9), color = "black",
      label.size    = 0.4,
      nudge_x       = nudge_x,
      nudge_y       = nudge_y,
      segment.color = "gold3", segment.size = 0.8
    ) +
    
    ggspatial::annotation_scale(
      location = "bl", width_hint = 0.25, text_cex = 0.8
    ) +
    ggspatial::annotation_north_arrow(
      location = "bl", pad_y = unit(0.5, "cm"),
      style    = ggspatial::north_arrow_fancy_orienteering(text_size = 8)
    ) +
    
    labs(
      title    = paste(state_name, "Wildfire Response Coverage"),
      subtitle = paste0(
        "Red perimeters = fires >100km from nearest station  |  ",
        "Orange = 50-100km  |  Blue = <50km\n",
        "▲ Gray triangles = fire stations  |  ",
        "▲ Gold triangle = most burdened station\n",
        "Median distance: ", state_stats$median_dist, "km  |  ",
        state_stats$pct_critical, "% of fires >50km from station  |  ",
        state_stats$total_fires, " fires  |  ",
        state_stats$total_acres, " acres"
      ),
      caption  = paste0(
        "Analysis: NIFC WFIGS fire perimeters + OpenStreetMap fire stations  |  ",
        "Straight-line distances, perimeter edge to station  |  ",
        format(Sys.Date(), "%B %d, %Y")
      )
    ) +
    theme_void(base_size = 12) +
    theme(
      plot.title        = element_text(size = 18, face = "bold",
                                       margin = margin(b = 5)),
      plot.subtitle     = element_text(size = 10, color = "gray30",
                                       lineheight = 1.4,
                                       margin = margin(b = 10)),
      plot.caption      = element_text(size = 8,  color = "gray50",
                                       margin = margin(t = 10)),
      plot.background   = element_rect(fill = "white", color = NA),
      plot.margin       = margin(15, 15, 10, 15),
      legend.position   = c(0.08, 0.3),
      legend.background = element_rect(fill  = alpha("white", 0.8),
                                       color = "gray80"),
      legend.key.size   = unit(0.6, "cm"),
      legend.title      = element_text(size = 9,  face = "bold"),
      legend.text       = element_text(size = 8)
    ) +
    coord_sf(xlim = xlim, ylim = ylim)
  
  # Inset USA map
  usa_states_sf <- st_as_sf(
    maps::map("state", plot = FALSE, fill = TRUE)
  ) %>%
    st_transform(4326)
  
  inset <- ggplot() +
    geom_sf(data  = usa_states_sf,
            fill  = "gray85", color = "white", linewidth = 0.3) +
    geom_sf(data  = usa_states_sf %>%
              filter(ID == tolower(state_name)) %>% st_as_sf(),
            fill  = "firebrick", color = "white", linewidth = 0.5) +
    theme_void() +
    theme(plot.background = element_rect(fill  = "white",
                                         color = "gray60",
                                         linewidth = 0.8)) +
    coord_sf(xlim = c(-125, -65), ylim = c(24, 50))
  
  # Combine
  final_map <- cowplot::ggdraw() +
    cowplot::draw_plot(state_main_map) +
    cowplot::draw_plot(inset,
                       x = 0.62, y = 0.02,
                       width = 0.22, height = 0.18)
  
  # Save
  out_file <- paste0(wc_output_dir,
                     tolower(state_name), "_coverage_",
                     format(Sys.Date(), "%Y%m%d"), ".png")
  
  ggsave(out_file, plot = final_map,
         width = 14, height = 10, dpi = 300, bg = "white")
  
  cat("Saved:", out_file, "\n")
  
  return(final_map)
}

# =============================================================================
# Build CA and WA maps
# =============================================================================

# California - tall state, adjust limits
ca_map <- build_state_map(
  state_name  = "California",
  state_abbr  = "CA",
  nudge_x     = 1.0,
  nudge_y     = 0.5
)

print(ca_map)

# Washington - wide state, adjust limits  
wa_map <- build_state_map(
  state_name  = "Washington",
  state_abbr  = "WA",
  nudge_x     = 0.5,
  nudge_y     = 0.3
)

print(wa_map)

# Copy CA and WA maps to output/figures/ so they show in README
file.copy(
  from = paste0(wc_output_dir, "california_coverage_",
                format(Sys.Date(), "%Y%m%d"), ".png"),
  to   = "output/figures/california_coverage.png",
  overwrite = TRUE
)

file.copy(
  from = paste0(wc_output_dir, "washington_coverage_",
                format(Sys.Date(), "%Y%m%d"), ".png"),
  to   = "output/figures/washington_coverage.png",
  overwrite = TRUE
)

cat("Images copied to output/figures/\n")