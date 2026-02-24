# =============================================================================
# 15_west_coast_combined_map.R
# Single map showing all 3 states together
# Shows the full picture of coverage gaps across the West Coast
#
# Outputs:
#   west_coast_combined_YYYYMMDD.png
#
# Depends on: 07-11 west coast scripts
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
# DATA PREP
# =============================================================================

# County stats joined to spatial data
wc_fire_stats <- fires_summary_df %>%
  group_by(fips, state) %>%
  summarise(
    n_fires      = n(),
    total_acres  = sum(acres,    na.rm = TRUE),
    mean_dist_km = round(mean(dist_km), 1),
    max_dist_km  = round(max(dist_km),  1),
    .groups      = "drop"
  )

wc_map_data <- westcoast_counties %>%
  st_as_sf() %>%
  left_join(wc_fire_stats, by = c("GEOID" = "fips")) %>%
  st_as_sf() %>%
  mutate(
    n_fires     = replace_na(n_fires,     0),
    total_acres = replace_na(total_acres, 0),
    has_fires   = n_fires > 0
  ) %>%
  st_transform(4326)

cat("Counties:", nrow(wc_map_data), "\n")
cat("Counties with fires:", sum(wc_map_data$has_fires), "\n")

# All fires with isolation flags
wc_fires_sf <- fires_wc_with_dist %>%
  st_as_sf() %>%
  st_transform(4326) %>%
  mutate(
    is_isolated      = dist_nearest_km >= 50,
    is_very_isolated = dist_nearest_km >= 100
  )

# All stations
wc_stations_sf <- all_stations_wc_clean %>%
  st_as_sf() %>%
  st_transform(4326)

# Top burdened station per state - highlighted in gold
top_stations <- fires_summary_df %>%
  group_by(state, nearest_station) %>%
  summarise(n_fires = n(), .groups = "drop") %>%
  group_by(state) %>%
  slice_max(n_fires, n = 1) %>%
  ungroup()

top_stations_sf <- wc_stations_sf %>%
  filter(name %in% top_stations$nearest_station) %>%
  st_as_sf() %>%
  left_join(top_stations, by = c("name" = "nearest_station"))

other_stations_sf <- wc_stations_sf %>%
  filter(!name %in% top_stations$nearest_station) %>%
  st_as_sf()

cat("Top stations per state:\n")
print(as.data.frame(top_stations))

# --- Key fires to label — top 3 per state, 100k+ acres only -----------------
# Filter attribute data first
key_fires_by_state <- fires_wc_with_dist %>%
  st_drop_geometry() %>%
  group_by(attr_POOState) %>%
  slice_max(attr_IncidentSize, n = 3) %>%
  ungroup() %>%
  filter(attr_IncidentSize >= 100000)

# Get centroids from the SAME filtered spatial rows
key_fires_spatial <- fires_wc_with_dist %>%
  st_as_sf() %>%
  st_transform(4326) %>%
  filter(attr_IncidentName %in% key_fires_by_state$attr_IncidentName)

key_fires_labels <- key_fires_spatial %>%
  st_centroid() %>%
  st_coordinates() %>%
  as_tibble() %>%
  bind_cols(
    key_fires_spatial %>%
      st_drop_geometry() %>%
      select(attr_IncidentName, attr_IncidentSize,
             attr_POOState, dist_nearest_km)
  ) %>%
  rename(lon = X, lat = Y)

cat("Key fires to label:", nrow(key_fires_labels), "\n")

# State labels — hand-placed to stay out of label-heavy zones
state_labels <- tibble(
  NAME = c("Washington", "Oregon", "California"),
  lon  = c(-120.5, -120.8, -119.5),
  lat  = c(47.5,    43.8,   37.2)
)

# Summary stats per state for subtitle
state_summary <- fires_summary_df %>%
  group_by(state) %>%
  summarise(
    n_fires      = n(),
    median_dist  = round(median(dist_km), 1),
    pct_critical = round(mean(is_isolated) * 100, 1),
    total_acres  = comma(round(sum(acres, na.rm = TRUE))),
    .groups      = "drop"
  )

cat("\nState summaries:\n")
print(as.data.frame(state_summary))

# Top station label coordinates
top_station_labels <- top_stations_sf %>%
  st_coordinates() %>%
  as_tibble() %>%
  bind_cols(top_stations_sf %>% st_drop_geometry()) %>%
  mutate(
    label_text = paste0(name, "\n", n_fires, " fires as nearest station")
  )

# =============================================================================
# BUILD MAP
# =============================================================================

wc_combined_map <- ggplot() +
  
  # County base - gray no fires, colored by mean distance
  geom_sf(data      = wc_map_data %>% filter(!has_fires) %>% st_as_sf(),
          fill      = "gray92", color = "white", linewidth = 0.15) +
  geom_sf(data      = wc_map_data %>% filter(has_fires) %>% st_as_sf(),
          aes(fill  = mean_dist_km),
          color     = "white", linewidth = 0.15) +
  scale_fill_gradientn(
    colors   = distance_colors,
    name     = "Mean Distance to\nNearest Station (km)",
    na.value = "gray92",
    limits   = c(0, 150),
    breaks   = c(0, 25, 50, 75, 100, 125),
    labels   = c("0", "25", "50", "75", "100", "125+"),
    oob      = scales::squish
  ) +
  
  # Fire perimeters - blue/orange/red by isolation level
  geom_sf(data  = wc_fires_sf %>%
            filter(!is_isolated) %>% st_as_sf(),
          fill  = "steelblue", color = NA, alpha = 0.35) +
  geom_sf(data  = wc_fires_sf %>%
            filter(is_isolated, !is_very_isolated) %>% st_as_sf(),
          fill  = "orange", color = NA, alpha = 0.45) +
  geom_sf(data  = wc_fires_sf %>%
            filter(is_very_isolated) %>% st_as_sf(),
          fill  = "firebrick", color = "darkred",
          linewidth = 0.1, alpha = 0.6) +
  
  # State borders
  geom_sf(data      = westcoast_states %>% st_as_sf(),
          fill      = NA, color = "gray20", linewidth = 0.8) +
  
  # County borders
  geom_sf(data      = wc_map_data %>% st_as_sf(),
          fill      = NA, color = "gray60", linewidth = 0.15) +
  
  # All non-top stations
  geom_sf(data  = other_stations_sf,
          color = "gray30", size = 0.4, shape = 17, alpha = 0.5) +
  
  # Top station per state - gold highlighted
  geom_sf(data  = top_stations_sf,
          color = "black", size = 6, shape = 2) +
  geom_sf(data  = top_stations_sf,
          color = "gold",  size = 5.5, shape = 17) +
  
  # Top station labels — increased force + seed for reproducible placement
  ggrepel::geom_label_repel(
    data = top_station_labels,
    aes(x = X, y = Y, label = label_text),
    size               = 2.8,
    fontface           = "bold",
    fill               = alpha("gold", 0.9),
    color              = "black",
    label.size         = 0.3,
    label.padding      = unit(0.2, "lines"),
    box.padding        = unit(1.2, "lines"),
    point.padding      = unit(0.5, "lines"),
    min.segment.length = 0,
    segment.color      = "gold3",
    segment.size       = 0.6,
    max.overlaps       = 20,
    seed               = 42,
    force              = 5,
    force_pull         = 0.3
  ) +
  
  # Large fire labels — seed + force for clean separation
  ggrepel::geom_label_repel(
    data = key_fires_labels,
    aes(x = lon, y = lat,
        label = paste0(attr_IncidentName, "\n",
                       comma(round(attr_IncidentSize)), " ac")),
    size               = 2.5,
    fontface           = "bold",
    fill               = alpha("white", 0.8),
    color              = "firebrick",
    label.size         = 0.2,
    label.padding      = unit(0.15, "lines"),
    box.padding        = unit(0.8, "lines"),
    point.padding      = unit(0.3, "lines"),
    min.segment.length = 0,
    segment.color      = "firebrick",
    segment.alpha      = 0.6,
    segment.size       = 0.3,
    max.overlaps       = 20,
    seed               = 42,
    force              = 6,
    force_pull         = 0.2
  ) +
  
  # State name labels — transparent text, not boxed
  geom_text(
    data      = state_labels,
    aes(x = lon, y = lat, label = NAME),
    size      = 5.5,
    fontface  = "bold",
    color     = alpha("gray20", 0.6),
    family    = "sans"
  ) +
  
  # Scale bar and north arrow
  ggspatial::annotation_scale(
    location = "bl", width_hint = 0.15, text_cex = 0.8
  ) +
  ggspatial::annotation_north_arrow(
    location = "bl", pad_y = unit(0.5, "cm"),
    style    = ggspatial::north_arrow_fancy_orienteering(text_size = 8)
  ) +
  
  labs(
    title    = "West Coast Wildfire Response Coverage",
    subtitle = paste0(
      "Red perimeters = fires >100km from nearest station  |  ",
      "Orange = 50\u2013100km  |  Blue = <50km\n",
      "\u25B2 Gray triangles = fire stations  |  ",
      "\u25B2 Gold triangles = most burdened station per state\n",
      "CA: ", filter(state_summary, state=="California")$median_dist, "km median  |  ",
      "OR: ", filter(state_summary, state=="Oregon")$median_dist,     "km median  |  ",
      "WA: ", filter(state_summary, state=="Washington")$median_dist, "km median"
    ),
    caption  = paste0(
      "Analysis: NIFC WFIGS fire perimeters + OpenStreetMap fire stations  |  ",
      scales::comma(nrow(fires_summary_df)),
      " final perimeters 2020\u20132025  |  ",
      "Straight-line distances, perimeter edge to station  |  ",
      format(Sys.Date(), "%B %d, %Y")
    )
  ) +
  theme_void(base_size = 12) +
  theme(
    plot.title        = element_text(size = 20, face = "bold",
                                     margin = margin(b = 3)),
    plot.subtitle     = element_text(size = 10, color = "gray30",
                                     lineheight = 1.3,
                                     margin = margin(b = 8)),
    plot.caption      = element_text(size = 8,  color = "gray50",
                                     hjust = 0,
                                     margin = margin(t = 10)),
    plot.background   = element_rect(fill = "white", color = NA),
    plot.margin       = margin(15, 15, 10, 15),
    legend.position   = c(0.08, 0.45),
    legend.background = element_rect(fill  = alpha("white", 0.9),
                                     color = "gray80",
                                     linewidth = 0.3),
    legend.margin     = margin(6, 8, 6, 8),
    legend.key.size   = unit(0.55, "cm"),
    legend.title      = element_text(size = 9,  face = "bold"),
    legend.text       = element_text(size = 8)
  ) +
  coord_sf(
    xlim   = c(-124.8, -114.0),
    ylim   = c(32.5,    49.0),
    expand = FALSE
  )

# ---------------------------------------------------------------------------
# Add inset USA map
# ---------------------------------------------------------------------------
usa_states_sf <- st_as_sf(
  maps::map("state", plot = FALSE, fill = TRUE)
) %>%
  st_transform(4326)

wc_states_highlight <- usa_states_sf %>%
  filter(ID %in% c("california", "oregon", "washington")) %>%
  st_as_sf()

inset_map <- ggplot() +
  geom_sf(data  = usa_states_sf,
          fill  = "gray85", color = "white", linewidth = 0.3) +
  geom_sf(data  = wc_states_highlight,
          fill  = "firebrick", color = "white", linewidth = 0.4) +
  theme_void() +
  theme(
    plot.background = element_rect(fill      = "white",
                                   color     = "gray60",
                                   linewidth = 0.8)
  ) +
  coord_sf(xlim = c(-125, -65), ylim = c(24, 50))

# ---------------------------------------------------------------------------
# Combine
# ---------------------------------------------------------------------------
wc_final_map <- cowplot::ggdraw() +
  cowplot::draw_plot(wc_combined_map) +
  cowplot::draw_plot(
    inset_map,
    x = 0.75, y = 0.01,
    width = 0.20, height = 0.15
  )

print(wc_final_map)

# ---------------------------------------------------------------------------
# Save
# ---------------------------------------------------------------------------
out_file <- paste0(wc_output_dir, "west_coast_combined_",
                   format(Sys.Date(), "%Y%m%d"), ".png")

ggsave(
  out_file,
  plot   = wc_final_map,
  width  = 14,
  height = 18,
  dpi    = 300,
  bg     = "white"
)

cat("West Coast combined map saved to:", out_file, "\n")

# Copy to output/figures/ for GitHub
file.copy(
  from      = out_file,
  to        = "output/figures/west_coast_combined.png",
  overwrite = TRUE
)

cat("Copied to output/figures/west_coast_combined.png\n")