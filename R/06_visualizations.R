# =============================================================================
# 06_visualizations.R
# All plots and maps for the TX Panhandle analysis
#
# Depends on: 01_setup.R through 05_distance_analysis.R
# Outputs saved to: output/figures/
# =============================================================================

dir.create("output/figures", recursive = TRUE, showWarnings = FALSE)

tmap_options(check.and.fix = TRUE)

# =============================================================================
# INTERACTIVE MAPS
# =============================================================================

# --- Map 1: Fire stations verification ---------------------------------------
tmap_mode("view")

tm_shape(panhandle_counties_sf) +
  tm_borders(col = "gray40", lwd = 2) +
  tm_fill(col = "gray95", alpha = 0.5) +
  tm_shape(all_stations) +
  tm_dots(
    col        = "firebrick",
    size       = 0.05,
    popup.vars = c("name", "source_geom")
  ) +
  tm_layout(title = "Fire Stations - TX Panhandle (OSM)")

# --- Map 2: Fires colored by distance to nearest station ---------------------
tm_shape(panhandle_counties_sf) +
  tm_borders(col = "gray40", lwd = 1) +
  tm_fill(col = "gray95", alpha = 0.3) +
  tm_shape(fires_with_dist %>% st_transform(4326)) +
  tm_polygons(
    col        = "dist_nearest_km",
    palette    = "YlOrRd",
    title      = "Dist to Nearest\nStation (km)",
    popup.vars = c("attr_IncidentName", "attr_POOCounty",
                   "attr_IncidentSize", "nearest_station_name",
                   "dist_nearest_km", "discovery_year")
  ) +
  tm_shape(all_stations) +
  tm_dots(
    col        = "steelblue",
    size       = 0.08,
    popup.vars = c("name")
  ) +
  tm_layout(title = "TX Panhandle Fires - Distance to Nearest Fire Station")

# =============================================================================
# STATIC PLOTS
# =============================================================================

# --- Plot 1: Station burden - frequency vs total acres -----------------------
station_burden <- fires_with_dist %>%
  st_drop_geometry() %>%
  group_by(nearest_station_name) %>%
  summarise(
    n_fires     = n(),
    total_acres = sum(attr_IncidentSize, na.rm = TRUE),
    mean_dist   = mean(dist_nearest_km)
  )

p1 <- ggplot(station_burden,
             aes(x = n_fires, y = total_acres, size = mean_dist,
                 color = mean_dist, label = nearest_station_name)) +
  geom_point(alpha = 0.8) +
  geom_text(hjust = -0.1, size = 3, check_overlap = TRUE) +
  scale_size_continuous(range = c(4, 15), name = "Mean dist (km)") +
  scale_color_gradient(low = "steelblue", high = "firebrick",
                       name = "Mean dist (km)") +
  scale_y_continuous(labels = comma) +
  labs(
    title    = "Fire Station Burden - Frequency vs Total Acres",
    subtitle = "Bubble size = mean distance to fires | TX Panhandle | 2020-2026",
    x        = "Number of Fires (nearest station)",
    y        = "Total Acres Burned",
    caption  = "Stations from OSM | Perimeters from NIFC WFIGS"
  ) +
  theme_minimal() +
  theme(legend.position = "right")

print(p1)
ggsave("output/figures/station_burden.png", p1, 
       width = 10, height = 7, dpi = 300)

# --- Plot 2: Distance distribution -------------------------------------------
p2 <- ggplot(fires_with_dist %>% st_drop_geometry(),
             aes(x = dist_nearest_km)) +
  geom_histogram(bins = 20, fill = "firebrick", alpha = 0.7, color = "white") +
  geom_vline(aes(xintercept = median(dist_nearest_km)),
             color = "orange", linewidth = 1.2, linetype = "dashed") +
  annotate("text",
           x     = median(fires_with_dist$dist_nearest_km) + 1,
           y     = 9,
           label = paste0("Median: ",
                          round(median(fires_with_dist$dist_nearest_km), 1),
                          " km"),
           hjust = 0, color = "darkorange") +
  labs(
    title    = "Distance from Wildfire Perimeter Edge to Nearest Fire Station",
    subtitle = "TX Panhandle | 2020-2026 | 51 Final Perimeters",
    x        = "Distance to Nearest Station (km)",
    y        = "Number of Fires",
    caption  = "Stations from OSM | Perimeters from NIFC WFIGS"
  ) +
  theme_minimal()

print(p2)
ggsave("output/figures/distance_distribution.png", p2,
       width = 10, height = 6, dpi = 300)

# --- Plot 3: Fire size vs distance -------------------------------------------
p3 <- ggplot(fires_with_dist %>% st_drop_geometry(),
             aes(x = attr_IncidentSize, y = dist_nearest_km)) +
  geom_point(aes(color = attr_FireCause), size = 3, alpha = 0.7) +
  geom_text(
    aes(label = ifelse(attr_IncidentSize > 300 | dist_nearest_km > 30,
                       attr_IncidentName, "")),
    hjust = -0.1, size = 3, check_overlap = TRUE
  ) +
  scale_x_log10(labels = comma) +
  scale_color_manual(
    values = c("Human"        = "firebrick",
               "Natural"      = "steelblue",
               "Undetermined" = "gray50")
  ) +
  labs(
    title    = "Fire Size vs Distance to Nearest Station",
    subtitle = "TX Panhandle | 2020-2026",
    x        = "Fire Size (acres, log scale)",
    y        = "Distance to Nearest Station (km)",
    color    = "Fire Cause",
    caption  = "Labeled: fires >300 acres or >30km from nearest station"
  ) +
  theme_minimal()

print(p3)
ggsave("output/figures/size_vs_distance.png", p3,
       width = 10, height = 7, dpi = 300)

# --- Plot 4: Station frequency bar chart -------------------------------------
p4 <- fires_with_dist %>%
  st_drop_geometry() %>%
  count(nearest_station_name, sort = TRUE) %>%
  ggplot(aes(x = reorder(nearest_station_name, n), y = n)) +
  geom_col(fill = "steelblue", alpha = 0.8) +
  geom_text(aes(label = n), hjust = -0.2, size = 4) +
  coord_flip() +
  labs(
    title    = "Which Fire Stations Are Most Frequently Nearest to a Fire?",
    subtitle = "TX Panhandle | 2020-2026",
    x        = NULL,
    y        = "Number of Fires",
    caption  = "Fritch FD covers 65% of all recorded fire perimeters"
  ) +
  theme_minimal() +
  expand_limits(y = 38)

print(p4)
ggsave("output/figures/station_frequency.png", p4,
       width = 10, height = 6, dpi = 300)

# --- Plot 5: County coverage map (static) ------------------------------------
p5a <- ggplot() +
  geom_sf(data = panhandle_with_stats,
          aes(fill = n_fires), color = "white") +
  geom_sf_text(data = panhandle_with_stats,
               aes(label = ifelse(n_fires > 0,
                                  paste0(NAME, "\n", n_fires, " fires"),
                                  NAME)),
               size = 2.5) +
  scale_fill_gradient(low = "lightyellow", high = "firebrick",
                      name = "# Fires", na.value = "gray90") +
  labs(title = "Wildfire Frequency by County",
       subtitle = "TX Panhandle | 2020-2026 | Final Perimeters") +
  theme_void() +
  theme(plot.title = element_text(face = "bold"))

p5b <- ggplot() +
  geom_sf(data = panhandle_with_stats,
          aes(fill = mean_dist_km), color = "white") +
  geom_sf_text(data = panhandle_with_stats,
               aes(label = ifelse(!is.na(mean_dist_km),
                                  paste0(NAME, "\n", mean_dist_km, " km"),
                                  NAME)),
               size = 2.5) +
  geom_sf(data = all_stations %>% st_transform(4326),
          color = "steelblue", size = 1.5, shape = 17) +
  scale_fill_gradient(low = "lightyellow", high = "firebrick",
                      name = "Mean Dist\n(km)", na.value = "gray90") +
  labs(title = "Mean Distance to Nearest Fire Station",
       subtitle = "Blue triangles = fire stations | Gray = no recorded fires") +
  theme_void() +
  theme(plot.title = element_text(face = "bold"))

p5 <- p5a + p5b +
  plot_annotation(
    title   = "TX Panhandle Wildfire Analysis",
    caption = "2020-2026 | Final perimeters only | Stations from OSM"
  )

print(p5)
ggsave("output/figures/county_maps.png", p5,
       width = 14, height = 7, dpi = 300)

cat("All figures saved to output/figures/\n")