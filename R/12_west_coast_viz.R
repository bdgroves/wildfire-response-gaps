# =============================================================================
# 12_west_coast_viz.R
# All static plots and maps for the West Coast analysis
#
# Hero images for LinkedIn:
#   - oregon_coverage_crisis_YYYYMMDD.png  (Oregon map with Frenchglen)
#   - coverage_comparison_YYYYMMDD.png     (TX Panhandle vs West Coast)
#
# Notes:
# - st_as_sf() applied defensively after all filter() and left_join()
#   on spatial objects - prevents sf class being silently dropped
# - ggspatial, ggrepel, cowplot, maps required
#
# Depends on: 07-11 west coast scripts
# Outputs saved to: wc_output_dir
# =============================================================================

if (!exists("fires_summary_df")) {
  message("Running dependency scripts first...")
  source("R/01_setup.R")
  source("R/07_west_coast_setup.R")
  source("R/08_west_coast_study_area.R")
  source("R/09_west_coast_stations.R")
  source("R/10_west_coast_perimeters.R")
  source("R/11_west_coast_distance.R")
}

# =============================================================================
# PLOT 1: Distance distribution by state
# =============================================================================

p_wc1 <- ggplot(fires_wc_with_dist %>% st_drop_geometry(),
                aes(x = dist_nearest_km, fill = attr_POOState)) +
  geom_histogram(bins = 30, alpha = 0.7, color = "white") +
  geom_vline(
    data = fires_wc_with_dist %>%
      st_drop_geometry() %>%
      group_by(attr_POOState) %>%
      summarise(med = median(dist_nearest_km, na.rm = TRUE)),
    aes(xintercept = med, color = attr_POOState),
    linewidth = 1.2, linetype = "dashed"
  ) +
  facet_wrap(~attr_POOState, ncol = 1,
             labeller = labeller(attr_POOState = c(
               "US-CA" = "California",
               "US-OR" = "Oregon",
               "US-WA" = "Washington"
             ))) +
  scale_fill_manual(values  = c("US-CA" = "firebrick",
                                "US-OR" = "steelblue",
                                "US-WA" = "forestgreen"),
                    guide   = "none") +
  scale_color_manual(values = c("US-CA" = "firebrick",
                                "US-OR" = "steelblue",
                                "US-WA" = "forestgreen"),
                     guide  = "none") +
  labs(
    title    = "Distance from Wildfire Perimeter to Nearest Fire Station",
    subtitle = "West Coast | Final Perimeters Only | Dashed line = state median",
    x        = "Distance to Nearest Station (km)",
    y        = "Number of Fires",
    caption  = "Stations from OSM | Perimeters from NIFC WFIGS"
  ) +
  theme_wildfire

ggsave(paste0(wc_output_dir, "wc_distance_distribution.png"),
       p_wc1, width = 10, height = 10, dpi = 300)
cat("Plot 1 saved - distance distribution\n")

# =============================================================================
# PLOT 2: Station burden bubble chart
# =============================================================================

p_wc2 <- station_burden_wc %>%
  head(20) %>%
  ggplot(aes(x = n_fires, y = total_acres,
             size = mean_dist_km, color = nearest_station_state)) +
  geom_point(alpha = 0.8) +
  geom_text(aes(label = nearest_station_name),
            vjust = -1.2, size = 2.5,
            check_overlap = TRUE, show.legend = FALSE) +
  scale_y_continuous(labels = comma) +
  scale_size_continuous(name = "Mean Dist\nto Fires (km)",
                        range = c(3, 12)) +
  scale_color_manual(values = c("California"  = "firebrick",
                                "Oregon"      = "steelblue",
                                "Washington"  = "forestgreen"),
                     name   = "State") +
  labs(
    title    = "Fire Station Burden - West Coast",
    subtitle = "Bubble size = mean distance to fires | Top 20 stations by fire count",
    x        = "Number of Fires (nearest station)",
    y        = "Total Acres Burned",
    caption  = "Stations from OSM | Perimeters from NIFC WFIGS"
  ) +
  theme_wildfire

ggsave(paste0(wc_output_dir, "wc_station_burden_bubble.png"),
       p_wc2, width = 12, height = 8, dpi = 300)
cat("Plot 2 saved - station burden bubble\n")

# =============================================================================
# PLOT 3: Regional comparison - LinkedIn hero chart
# =============================================================================

comparison_data <- tibble(
  Region       = c("TX Panhandle", "California",
                   "Washington",   "Oregon",
                   "Malheur Co.\nOregon"),
  Median_Dist  = c(10.3, 10.8, 8.6, 26.7, 139.1),
  Pct_Critical = c(0,    1.5,  1.9, 30.1, 100),
  Category     = c("Good", "Good", "Good", "Crisis", "Emergency")
)

p_compare1 <- ggplot(comparison_data,
                     aes(x = reorder(Region, Median_Dist),
                         y = Median_Dist, fill = Category)) +
  geom_col(alpha = 0.85) +
  geom_text(aes(label = paste0(Median_Dist, " km")),
            hjust = -0.1, size = 4, fontface = "bold") +
  coord_flip() +
  scale_fill_manual(values = c("Good"      = "steelblue",
                               "Crisis"    = "orange",
                               "Emergency" = "firebrick"),
                    guide  = "none") +
  labs(title    = "Median Distance to Nearest Fire Station",
       subtitle = "By region | Lower = better coverage",
       x        = NULL,
       y        = "Median Distance (km)") +
  theme_minimal(base_size = 13) +
  expand_limits(y = 180)

p_compare2 <- ggplot(comparison_data,
                     aes(x = reorder(Region, Pct_Critical),
                         y = Pct_Critical, fill = Category)) +
  geom_col(alpha = 0.85) +
  geom_text(aes(label = paste0(Pct_Critical, "%")),
            hjust = -0.1, size = 4, fontface = "bold") +
  coord_flip() +
  scale_fill_manual(values = c("Good"      = "steelblue",
                               "Crisis"    = "orange",
                               "Emergency" = "firebrick"),
                    guide  = "none") +
  labs(title    = "% of Fires in Critical/Extreme Coverage Gap",
       subtitle = ">50km from nearest station",
       x        = NULL,
       y        = "Percent of Fires") +
  theme_minimal(base_size = 13) +
  expand_limits(y = 120)

p_compare1 + p_compare2 +
  plot_annotation(
    title    = "Wildfire Response Coverage - Where Are The Gaps?",
    subtitle = "TX Panhandle + West Coast | Open data analysis in R",
    caption  = paste(
      "Stations: OpenStreetMap | Fires: NIFC WFIGS |",
      "Distances: straight-line perimeter edge to station |",
      "Response times: estimated, straight-line x 1.3 road factor"
    )
  )

ggsave(
  paste0(wc_output_dir, "coverage_comparison_",
         format(Sys.Date(), "%Y%m%d"), ".png"),
  width = 14, height = 8, dpi = 300
)
cat("Plot 3 saved - regional comparison\n")

# =============================================================================
# PLOT 4: Oregon hero map
# =============================================================================

# ---------------------------------------------------------------------------
# Data prep
# st_as_sf() applied after every filter() and left_join() on spatial objects
# ---------------------------------------------------------------------------

# Oregon counties - st_as_sf() after filter() to preserve sf class
oregon_counties_sf <- westcoast_counties %>%
  filter(state_abbr == "OR") %>%
  st_as_sf()

cat("Oregon counties:", nrow(oregon_counties_sf), "\n")

# Fire stats per county - non-spatial summary
oregon_fire_stats <- fires_summary_df %>%
  filter(state == "Oregon") %>%
  group_by(fips) %>%
  summarise(
    n_fires      = n(),
    total_acres  = sum(acres,    na.rm = TRUE),
    mean_dist_km = round(mean(dist_km), 1),
    max_dist_km  = round(max(dist_km),  1),
    .groups      = "drop"
  )

# Join stats to counties - st_as_sf() after left_join() to preserve sf class
oregon_map_data <- oregon_counties_sf %>%
  left_join(oregon_fire_stats, by = c("GEOID" = "fips")) %>%
  st_as_sf() %>%
  mutate(
    n_fires     = replace_na(n_fires,     0),
    total_acres = replace_na(total_acres, 0),
    has_fires   = n_fires > 0
  ) %>%
  st_transform(4326)

cat("Oregon map data:", nrow(oregon_map_data), "counties |",
    sum(oregon_map_data$has_fires), "with fires\n")

# Oregon fire perimeters with isolation flags
oregon_fires_sf <- fires_wc_with_dist %>%
  filter(attr_POOState == "US-OR") %>%
  st_as_sf() %>%
  st_transform(4326) %>%
  mutate(
    is_isolated      = dist_nearest_km >= 50,
    is_very_isolated = dist_nearest_km >= 100
  )

cat("Oregon fires:", nrow(oregon_fires_sf), "\n")

# Oregon stations - st_as_sf() after st_filter() to preserve sf class
oregon_stations_sf <- all_stations_wc_clean %>%
  st_as_sf() %>%
  st_filter(oregon_counties_sf %>% st_union()) %>%
  st_transform(4326)

# Frenchglen specifically
frenchglen_sf <- oregon_stations_sf %>%
  filter(name == "Frenchglen Fire Guard Station") %>%
  st_as_sf()

cat("Oregon stations:", nrow(oregon_stations_sf), "\n")
cat("Frenchglen found:", nrow(frenchglen_sf), "\n")

# Key fires to label on the map
# Show fires > 50k acres OR > 10k acres AND very isolated
key_fires_labels <- fires_wc_with_dist %>%
  filter(attr_POOState == "US-OR") %>%
  st_as_sf() %>%
  st_transform(4326) %>%
  st_centroid() %>%
  st_coordinates() %>%
  as_tibble() %>%
  bind_cols(
    fires_wc_with_dist %>%
      filter(attr_POOState == "US-OR") %>%
      st_drop_geometry() %>%
      select(attr_IncidentName, attr_IncidentSize, dist_nearest_km)
  ) %>%
  filter(
    attr_IncidentSize >= 50000 |
      (attr_IncidentSize >= 10000 & dist_nearest_km >= 100)
  ) %>%
  rename(lon = X, lat = Y)

cat("Key fires to label:", nrow(key_fires_labels), "\n")

# ---------------------------------------------------------------------------
# Build main Oregon map
# ---------------------------------------------------------------------------
oregon_main_map <- ggplot() +
  
  # County base - gray for no fires, colored by mean distance for fires
  geom_sf(data      = oregon_map_data %>% filter(!has_fires) %>% st_as_sf(),
          fill      = "gray92", color = "white", linewidth = 0.2) +
  geom_sf(data      = oregon_map_data %>% filter(has_fires) %>% st_as_sf(),
          aes(fill  = mean_dist_km),
          color     = "white", linewidth = 0.2) +
  scale_fill_gradientn(
    colors   = distance_colors,
    name     = "Mean Distance to\nNearest Station (km)",
    na.value = "gray92",
    breaks   = c(0, 25, 50, 75, 100, 125),
    labels   = c("0", "25", "50", "75", "100", "125+")
  ) +
  
  # Fire perimeters - blue = good, orange = poor, red = critical
  geom_sf(data  = oregon_fires_sf %>% filter(!is_isolated)               %>% st_as_sf(),
          fill  = "steelblue", color = NA, alpha = 0.4) +
  geom_sf(data  = oregon_fires_sf %>% filter(is_isolated, !is_very_isolated) %>% st_as_sf(),
          fill  = "orange",    color = NA, alpha = 0.5) +
  geom_sf(data  = oregon_fires_sf %>% filter(is_very_isolated)           %>% st_as_sf(),
          fill  = "firebrick", color = "darkred",
          linewidth = 0.1, alpha = 0.6) +
  
  # All stations except Frenchglen - small gray triangles
  geom_sf(data  = oregon_stations_sf %>%
            filter(name != "Frenchglen Fire Guard Station") %>%
            st_as_sf(),
          color = "gray30", size = 1.0, shape = 17, alpha = 0.6) +
  
  # Frenchglen - gold filled triangle with black outline
  geom_sf(data  = frenchglen_sf,
          color = "black", size = 5.5, shape = 2) +
  geom_sf(data  = frenchglen_sf,
          color = "gold",  size = 5.0, shape = 17) +
  
  # County borders on top
  geom_sf(data  = oregon_map_data %>% st_as_sf(),
          fill  = NA, color = "gray50", linewidth = 0.3) +
  
  # Large fire labels
  ggrepel::geom_label_repel(
    data          = key_fires_labels,
    aes(x = lon, y = lat,
        label = paste0(attr_IncidentName, "\n",
                       comma(round(attr_IncidentSize)), " ac")),
    size          = 2.8,
    fontface      = "bold",
    fill          = alpha("white", 0.8),
    color         = "firebrick",
    label.size    = 0.2,
    box.padding   = 0.5,
    max.overlaps  = 15,
    segment.color = "firebrick",
    segment.alpha = 0.6
  ) +
  
  # Frenchglen annotation box
  ggrepel::geom_label_repel(
    data = frenchglen_sf %>%
      st_coordinates() %>%
      as_tibble() %>%
      mutate(label = paste0(
        "Frenchglen Fire\nGuard Station\n",
        "(Pop. 12)\n",
        "148 fires | 516,867 ac\n",
        "Mean response: 114 min"
      )),
    aes(x = X, y = Y, label = label),
    size          = 3.2,
    fontface      = "bold",
    fill          = alpha("gold", 0.9),
    color         = "black",
    label.size    = 0.4,
    nudge_x       = 1.5,
    nudge_y       = 0.8,
    segment.color = "gold3",
    segment.size  = 0.8
  ) +
  
  # Scale bar and north arrow
  ggspatial::annotation_scale(
    location   = "bl",
    width_hint = 0.25,
    text_cex   = 0.8
  ) +
  ggspatial::annotation_north_arrow(
    location = "bl",
    pad_y    = unit(0.5, "cm"),
    style    = ggspatial::north_arrow_fancy_orienteering(text_size = 8)
  ) +
  
  labs(
    title    = "Oregon Wildfire Response Coverage Crisis",
    subtitle = paste0(
      "Red perimeters = fires >100km from nearest station  |  ",
      "Orange = 50-100km  |  Blue = <50km\n",
      "▲ Gray triangles = fire stations  |  ",
      "▲ Gold triangle = Frenchglen Fire Guard Station\n",
      "County fill = mean distance to nearest station"
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
    legend.position   = c(0.15, 0.75),
    legend.background = element_rect(fill  = alpha("white", 0.8),
                                     color = "gray80"),
    legend.key.size   = unit(0.6, "cm"),
    legend.title      = element_text(size = 9,  face = "bold"),
    legend.text       = element_text(size = 8)
  ) +
  coord_sf(xlim = c(-124.6, -116.5), ylim = c(41.9, 46.3))

# ---------------------------------------------------------------------------
# Inset USA context map
# ---------------------------------------------------------------------------
usa_states_sf <- st_as_sf(
  maps::map("state", plot = FALSE, fill = TRUE)
) %>%
  st_transform(4326)

inset_map <- ggplot() +
  geom_sf(data      = usa_states_sf,
          fill      = "gray85", color = "white", linewidth = 0.3) +
  geom_sf(data      = usa_states_sf %>% filter(ID == "oregon") %>% st_as_sf(),
          fill      = "firebrick", color = "white", linewidth = 0.5) +
  theme_void() +
  theme(
    plot.background = element_rect(fill      = "white",
                                   color     = "gray60",
                                   linewidth = 0.8)
  ) +
  coord_sf(xlim = c(-125, -65), ylim = c(24, 50))

# ---------------------------------------------------------------------------
# Combine main map and inset with cowplot
# ---------------------------------------------------------------------------
oregon_final_map <- cowplot::ggdraw() +
  cowplot::draw_plot(oregon_main_map) +
  cowplot::draw_plot(
    inset_map,
    x      = 0.62,
    y      = 0.02,
    width  = 0.22,
    height = 0.18
  )

print(oregon_final_map)

ggsave(
  paste0(wc_output_dir, "oregon_coverage_crisis_",
         format(Sys.Date(), "%Y%m%d"), ".png"),
  plot   = oregon_final_map,
  width  = 14,
  height = 10,
  dpi    = 300,
  bg     = "white"
)

cat("Plot 4 saved - Oregon hero map\n")

# =============================================================================
# SUMMARY
# =============================================================================

cat("\n--- All visualizations complete ---\n")
cat("Saved to:", wc_output_dir, "\n\n")
cat("Files:\n")
cat("  wc_distance_distribution.png\n")
cat("  wc_station_burden_bubble.png\n")
cat("  coverage_comparison_",    format(Sys.Date(), "%Y%m%d"), ".png\n", sep = "")
cat("  oregon_coverage_crisis_", format(Sys.Date(), "%Y%m%d"), ".png\n", sep = "")
cat("\nLinkedIn hero images:\n")
cat("  1. oregon_coverage_crisis_",  format(Sys.Date(), "%Y%m%d"), ".png\n", sep = "")
cat("  2. coverage_comparison_",     format(Sys.Date(), "%Y%m%d"), ".png\n", sep = "")