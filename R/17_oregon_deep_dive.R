# =============================================================================
# 17_oregon_deep_dive.R
# Oregon wildfire response gap story
# Purpose-built visuals for LinkedIn narrative
#
# The story: Oregon has 15x worse fire station coverage than its neighbors
#            One station with 12 people covers 148 fires across 500k+ acres
#
# Outputs:
#   oregon_coverage_gap.png       - hero map
#   oregon_comparison_bar.png     - state comparison
#   oregon_frenchglen_zoom.png    - Frenchglen detail
#   oregon_distance_histogram.png - distribution comparison
#
# Depends on: 07-11 west coast scripts (or saved baseline RDS)
# =============================================================================

# --- Load baseline if objects aren't in memory ------------------------------
if (!exists("fires_summary_df")) {
  
  message("Loading from saved baseline...")
  source("R/01_setup.R")
  source("R/07_west_coast_setup.R")
  
  options(tigris_use_cache = FALSE)
  
  baseline_files <- list.files(wc_output_dir,
                               pattern = "westcoast_baseline.*\\.rds$",
                               full.names = TRUE)
  
  if (length(baseline_files) > 0) {
    latest_baseline <- sort(baseline_files, decreasing = TRUE)[1]
    message("Loading baseline: ", latest_baseline)
    baseline <- readRDS(latest_baseline)
    list2env(baseline, envir = .GlobalEnv)
    message("Baseline loaded successfully")
  } else {
    message("No baseline RDS found. Running full pipeline...")
    source("R/08_west_coast_study_area.R")
    source("R/09_west_coast_stations.R")
    source("R/10_west_coast_perimeters.R")
    source("R/11_west_coast_distance.R")
  }
}

stopifnot(
  exists("fires_summary_df"),
  exists("fires_wc_with_dist"),
  exists("all_stations_wc_clean"),
  exists("westcoast_counties"),
  exists("westcoast_states")
)

cat("Data loaded. fires_summary_df:", nrow(fires_summary_df), "rows\n")

# =============================================================================
# Detect column names — fires_wc_with_dist vs fires_summary_df use different
# names for the nearest station column
# =============================================================================

# fires_wc_with_dist uses "nearest_station_name"
# fires_summary_df uses "nearest_station"
# We'll confirm and store for safety
wc_dist_cols <- names(fires_wc_with_dist)
stn_col <- grep("nearest_station", wc_dist_cols, value = TRUE)[1]
cat("Nearest station column in fires_wc_with_dist:", stn_col, "\n")

# =============================================================================
# DATA PREP — Oregon focused
# =============================================================================

# Oregon boundaries
or_counties <- westcoast_counties %>%
  st_as_sf() %>%
  filter(STATEFP == "41") %>%
  st_transform(4326)

or_state <- westcoast_states %>%
  st_as_sf() %>%
  filter(STUSPS == "OR") %>%
  st_transform(4326)

# Oregon fires — use detected column name
or_fires <- fires_wc_with_dist %>%
  st_as_sf() %>%
  st_transform(4326) %>%
  filter(attr_POOState == "US-OR") %>%
  rename(nearest_station = !!sym(stn_col)) %>%
  mutate(
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

cat("Oregon fires:", nrow(or_fires), "\n")

# Oregon stations
or_stations <- all_stations_wc_clean %>%
  st_as_sf() %>%
  st_transform(4326) %>%
  st_filter(or_state %>% st_buffer(0.1))

cat("Oregon stations:", nrow(or_stations), "\n")

# Frenchglen station
frenchglen <- or_stations %>%
  filter(grepl("Frenchglen", name, ignore.case = TRUE))

cat("Frenchglen found:", nrow(frenchglen), "station(s)\n")
if (nrow(frenchglen) > 0) print(frenchglen %>% st_drop_geometry())

# Fires nearest to Frenchglen — now uses renamed column
frenchglen_fires <- or_fires %>%
  filter(grepl("Frenchglen", nearest_station, ignore.case = TRUE))

cat("Frenchglen fires:", nrow(frenchglen_fires), "\n")

# Oregon county stats (fires_summary_df already has "nearest_station")
or_county_stats <- fires_summary_df %>%
  filter(state == "Oregon") %>%
  group_by(county, fips) %>%
  summarise(
    n_fires       = n(),
    total_acres   = sum(acres, na.rm = TRUE),
    median_dist   = round(median(dist_km), 1),
    mean_dist     = round(mean(dist_km), 1),
    max_dist      = round(max(dist_km), 1),
    pct_over_50   = round(mean(dist_km > 50) * 100, 1),
    .groups       = "drop"
  ) %>%
  arrange(desc(median_dist))

cat("\nWorst counties:\n")
print(head(or_county_stats, 10))

# County map data
or_map_data <- or_counties %>%
  left_join(or_county_stats, by = c("GEOID" = "fips")) %>%
  st_as_sf() %>%
  mutate(
    n_fires     = replace_na(n_fires, 0),
    total_acres = replace_na(total_acres, 0),
    has_fires   = n_fires > 0
  )

# =============================================================================
# VISUAL 1: Oregon Hero Map — coverage gaps
# =============================================================================

message("Building Oregon hero map...")

# Key fires to label — largest + most isolated
or_key_fires <- or_fires %>%
  st_drop_geometry() %>%
  filter(attr_IncidentSize >= 100000 | dist_nearest_km >= 100) %>%
  arrange(desc(attr_IncidentSize)) %>%
  slice_head(n = 8)

or_key_spatial <- or_fires %>%
  filter(attr_IncidentName %in% or_key_fires$attr_IncidentName)

or_key_labels <- or_key_spatial %>%
  st_centroid() %>%
  st_coordinates() %>%
  as_tibble() %>%
  bind_cols(
    or_key_spatial %>%
      st_drop_geometry() %>%
      select(attr_IncidentName, attr_IncidentSize,
             dist_nearest_km, nearest_station)
  ) %>%
  rename(lon = X, lat = Y) %>%
  mutate(
    label = paste0(attr_IncidentName, "\n",
                   scales::comma(round(attr_IncidentSize)), " ac\n",
                   round(dist_nearest_km), " km to nearest station")
  )

# Frenchglen connector lines to its fires (sample for readability)
if (nrow(frenchglen) > 0 && nrow(frenchglen_fires) > 0) {
  frenchglen_lines <- frenchglen_fires %>%
    arrange(desc(attr_IncidentSize)) %>%
    slice_head(n = 20) %>%
    st_centroid() %>%
    st_coordinates() %>%
    as_tibble() %>%
    mutate(
      stn_lon = st_coordinates(frenchglen)[1, 1],
      stn_lat = st_coordinates(frenchglen)[1, 2]
    ) %>%
    rename(fire_lon = X, fire_lat = Y)
} else {
  frenchglen_lines <- tibble(
    fire_lon = numeric(), fire_lat = numeric(),
    stn_lon = numeric(), stn_lat = numeric()
  )
}

or_hero_map <- ggplot() +
  
  # County choropleth — mean distance
  geom_sf(data = or_map_data %>% filter(!has_fires),
          fill = "gray92", color = "white", linewidth = 0.2) +
  geom_sf(data = or_map_data %>% filter(has_fires),
          aes(fill = mean_dist),
          color = "white", linewidth = 0.2) +
  scale_fill_gradientn(
    colors   = c("#e8f4f8", "#b8d4e3", "#dbb98f",
                 "#d4896c", "#c05046", "#8b1a1a"),
    name     = "Mean Distance to\nNearest Station (km)",
    limits   = c(0, 150),
    breaks   = c(0, 25, 50, 75, 100, 125),
    labels   = c("0", "25", "50", "75", "100", "125+"),
    oob      = scales::squish,
    na.value = "gray92"
  ) +
  
  # Fire perimeters by distance category
  geom_sf(data = or_fires %>% filter(dist_nearest_km < 50),
          fill = alpha("steelblue", 0.3), color = NA) +
  geom_sf(data = or_fires %>%
            filter(dist_nearest_km >= 50, dist_nearest_km < 100),
          fill = alpha("darkorange", 0.45),
          color = alpha("darkorange", 0.6), linewidth = 0.15) +
  geom_sf(data = or_fires %>% filter(dist_nearest_km >= 100),
          fill = alpha("firebrick", 0.5), color = "darkred",
          linewidth = 0.2) +
  
  # State border
  geom_sf(data = or_state,
          fill = NA, color = "gray20", linewidth = 0.8) +
  
  # County borders
  geom_sf(data = or_counties,
          fill = NA, color = "gray60", linewidth = 0.15) +
  
  # Connector lines: Frenchglen to its fires
  geom_segment(
    data = frenchglen_lines,
    aes(x = stn_lon, y = stn_lat,
        xend = fire_lon, yend = fire_lat),
    color = alpha("gold3", 0.3),
    linewidth = 0.3, linetype = "solid"
  ) +
  
  # All stations
  geom_sf(data = or_stations,
          color = alpha("gray30", 0.5), size = 1.2, shape = 17) +
  
  # Frenchglen highlighted
  {
    if (nrow(frenchglen) > 0) {
      list(
        geom_sf(data = frenchglen,
                color = "black", size = 6, shape = 2),
        geom_sf(data = frenchglen,
                color = "gold", size = 5.5, shape = 17)
      )
    }
  } +
  
  # Frenchglen label
  {
    if (nrow(frenchglen) > 0) {
      ggrepel::geom_label_repel(
        data = frenchglen %>%
          st_coordinates() %>%
          as_tibble() %>%
          bind_cols(frenchglen %>% st_drop_geometry()),
        aes(x = X, y = Y,
            label = paste0("Frenchglen Fire Guard Station\n",
                           "Population: ~12\n",
                           "Nearest to ", nrow(frenchglen_fires), " fires\n",
                           scales::comma(sum(frenchglen_fires$attr_IncidentSize,
                                             na.rm = TRUE)),
                           " acres in coverage zone")),
        size               = 3,
        fontface           = "bold",
        fill               = alpha("gold", 0.9),
        color              = "black",
        label.size         = 0.3,
        box.padding        = unit(2, "lines"),
        min.segment.length = 0,
        segment.color      = "gold3",
        segment.size       = 0.6,
        seed               = 42,
        force              = 5
      )
    }
  } +
  
  # Key fire labels
  ggrepel::geom_label_repel(
    data = or_key_labels,
    aes(x = lon, y = lat, label = label),
    size               = 2.2,
    fontface           = "bold",
    fill               = alpha("white", 0.85),
    color              = "firebrick",
    label.size         = 0.2,
    box.padding        = unit(0.8, "lines"),
    min.segment.length = 0,
    segment.color      = "firebrick",
    segment.size       = 0.3,
    max.overlaps       = 15,
    seed               = 42,
    force              = 5
  ) +
  
  # County name labels for worst counties
  geom_sf_text(
    data = or_map_data %>%
      filter(!is.na(median_dist)) %>%
      filter(median_dist >= 40 | total_acres >= 200000),
    aes(label = NAME),
    size = 3, fontface = "italic",
    color = alpha("gray20", 0.8)
  ) +
  
  ggspatial::annotation_scale(
    location = "bl", width_hint = 0.2, text_cex = 0.8
  ) +
  ggspatial::annotation_north_arrow(
    location = "bl", pad_y = unit(0.5, "cm"),
    style = ggspatial::north_arrow_fancy_orienteering(text_size = 8)
  ) +
  
  labs(
    title    = "Oregon\u2019s Wildfire Response Gap",
    subtitle = paste0(
      "30% of Oregon\u2019s wildfires are >50km from the nearest fire station\n",
      "vs 1.5% in California and 1.9% in Washington\n",
      "Gold lines = fires covered by Frenchglen (pop. ~12)  |  ",
      "Red = fires >100km from any station"
    ),
    caption  = paste0(
      "Data: NIFC WFIGS perimeters + OpenStreetMap stations  |  ",
      nrow(or_fires), " Oregon fire perimeters 2020\u20132025  |  ",
      "Straight-line distance, perimeter edge to station  |  ",
      format(Sys.Date(), "%B %d, %Y")
    )
  ) +
  theme_void(base_size = 12) +
  theme(
    plot.title        = element_text(size = 22, face = "bold",
                                     margin = margin(b = 3)),
    plot.subtitle     = element_text(size = 11, color = "gray30",
                                     lineheight = 1.3,
                                     margin = margin(b = 8)),
    plot.caption      = element_text(size = 8, color = "gray50",
                                     hjust = 0, margin = margin(t = 10)),
    plot.background   = element_rect(fill = "white", color = NA),
    plot.margin       = margin(15, 15, 10, 15),
    legend.position   = c(0.15, 0.3),
    legend.background = element_rect(fill = alpha("white", 0.9),
                                     color = "gray80", linewidth = 0.3),
    legend.margin     = margin(6, 8, 6, 8),
    legend.key.size   = unit(0.55, "cm"),
    legend.title      = element_text(size = 9, face = "bold"),
    legend.text       = element_text(size = 8)
  ) +
  coord_sf(
    xlim = c(-124.6, -116.5),
    ylim = c(41.9, 46.3),
    expand = FALSE
  )

# =============================================================================
# VISUAL 2: State comparison bar chart
# =============================================================================

message("Building state comparison chart...")

comparison_df <- fires_summary_df %>%
  filter(state %in% c("Oregon", "California", "Washington")) %>%
  group_by(state) %>%
  summarise(
    n_fires       = n(),
    median_dist   = round(median(dist_km), 1),
    pct_over_50   = round(mean(dist_km > 50) * 100, 1),
    total_acres   = sum(acres, na.rm = TRUE),
    .groups       = "drop"
  ) %>%
  mutate(
    state = factor(state, levels = c("Washington", "California", "Oregon")),
    bar_color = case_when(
      state == "Oregon" ~ "firebrick",
      TRUE              ~ "steelblue"
    ),
    label = paste0(pct_over_50, "%")
  )

or_comparison_bar <- ggplot(comparison_df,
                            aes(x = state, y = pct_over_50,
                                fill = bar_color)) +
  geom_col(width = 0.6, show.legend = FALSE) +
  geom_text(aes(label = label),
            vjust = -0.5, size = 6, fontface = "bold",
            color = "gray20") +
  scale_fill_identity() +
  scale_y_continuous(
    limits = c(0, 38),
    breaks = seq(0, 35, 5),
    labels = paste0(seq(0, 35, 5), "%")
  ) +
  labs(
    title    = "Percentage of Wildfires >50km From Nearest Station",
    subtitle = paste0(
      "Oregon: 30.1% of fires have critical or extreme response gaps\n",
      "California and Washington: less than 2%"
    ),
    x = NULL, y = NULL,
    caption = paste0(
      "3,635 final fire perimeters 2020\u20132025  |  ",
      "CA: ", filter(comparison_df, state == "California")$n_fires,
      " fires  |  OR: ", filter(comparison_df, state == "Oregon")$n_fires,
      " fires  |  WA: ", filter(comparison_df, state == "Washington")$n_fires,
      " fires"
    )
  ) +
  theme_minimal(base_size = 14) +
  theme(
    plot.title      = element_text(size = 18, face = "bold",
                                   margin = margin(b = 5)),
    plot.subtitle   = element_text(size = 12, color = "gray30",
                                   lineheight = 1.3),
    plot.caption    = element_text(size = 9, color = "gray50",
                                   margin = margin(t = 10)),
    plot.background = element_rect(fill = "white", color = NA),
    plot.margin     = margin(20, 20, 15, 20),
    panel.grid.major.x = element_blank(),
    panel.grid.minor   = element_blank(),
    axis.text.x     = element_text(size = 14, face = "bold"),
    axis.text.y     = element_text(size = 11)
  )

# =============================================================================
# VISUAL 3: Distance distribution — Oregon vs others
# =============================================================================

message("Building distance histogram...")

hist_df <- fires_summary_df %>%
  filter(state %in% c("Oregon", "California", "Washington")) %>%
  mutate(
    is_oregon = if_else(state == "Oregon", "Oregon", "CA + WA"),
    is_oregon = factor(is_oregon, levels = c("CA + WA", "Oregon"))
  )

or_distance_hist <- ggplot(hist_df,
                           aes(x = dist_km, fill = is_oregon)) +
  geom_histogram(
    binwidth = 5, alpha = 0.7, color = "white", linewidth = 0.1,
    position = "identity"
  ) +
  geom_vline(xintercept = 50, linetype = "dashed",
             color = "firebrick", linewidth = 0.8) +
  annotate("text", x = 52, y = Inf, vjust = 1.5,
           label = "50km threshold",
           color = "firebrick", fontface = "bold", size = 3.5,
           hjust = 0) +
  scale_fill_manual(
    values = c("CA + WA" = "steelblue", "Oregon" = "firebrick"),
    name   = NULL
  ) +
  scale_x_continuous(
    breaks = seq(0, 200, 25),
    labels = paste0(seq(0, 200, 25), " km")
  ) +
  labs(
    title    = "Distance to Nearest Fire Station \u2014 Oregon vs Neighbors",
    subtitle = paste0(
      "Oregon\u2019s long tail: fires routinely 100\u2013200km from any station\n",
      "California and Washington cluster under 25km"
    ),
    x = "Distance to nearest station",
    y = "Number of fires",
    caption = "NIFC WFIGS perimeters 2020\u20132025 | Straight-line distance"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    plot.title      = element_text(size = 16, face = "bold"),
    plot.subtitle   = element_text(size = 11, color = "gray30",
                                   lineheight = 1.3),
    plot.caption    = element_text(size = 8, color = "gray50"),
    plot.background = element_rect(fill = "white", color = NA),
    plot.margin     = margin(15, 15, 10, 15),
    legend.position = c(0.85, 0.85),
    legend.text     = element_text(size = 11)
  )

# =============================================================================
# VISUAL 4: Frenchglen zoom with coverage radius
# =============================================================================

message("Building Frenchglen detail map...")

if (nrow(frenchglen) > 0 && nrow(frenchglen_fires) > 0) {
  
  # Frenchglen buffer rings
  frenchglen_proj <- frenchglen %>% st_transform(wc_crs)
  ring_50  <- st_buffer(frenchglen_proj, 50000)  %>% st_transform(4326)
  ring_100 <- st_buffer(frenchglen_proj, 100000) %>% st_transform(4326)
  ring_150 <- st_buffer(frenchglen_proj, 150000) %>% st_transform(4326)
  
  # Zoom extent around Frenchglen
  fg_bbox <- st_bbox(ring_150)
  fg_bbox_expanded <- c(
    xmin = as.numeric(fg_bbox["xmin"]) - 0.3,
    ymin = as.numeric(fg_bbox["ymin"]) - 0.3,
    xmax = as.numeric(fg_bbox["xmax"]) + 0.3,
    ymax = as.numeric(fg_bbox["ymax"]) + 0.3
  )
  
  # Fires in zoom area
  frenchglen_area_fires <- or_fires %>%
    st_crop(fg_bbox_expanded)
  
  # Stations in zoom area
  frenchglen_area_stations <- or_stations %>%
    st_crop(fg_bbox_expanded)
  
  # Top fires to label
  fg_top_fires <- frenchglen_fires %>%
    arrange(desc(attr_IncidentSize)) %>%
    slice_head(n = 6)
  
  fg_fire_labels <- fg_top_fires %>%
    st_centroid() %>%
    st_coordinates() %>%
    as_tibble() %>%
    bind_cols(
      fg_top_fires %>%
        st_drop_geometry() %>%
        select(attr_IncidentName, attr_IncidentSize, dist_nearest_km)
    ) %>%
    rename(lon = X, lat = Y)
  
  or_frenchglen_zoom <- ggplot() +
    
    # County base
    geom_sf(data = or_counties %>% st_crop(fg_bbox_expanded),
            fill = "gray95", color = "gray80", linewidth = 0.2) +
    
    # Distance rings
    geom_sf(data = ring_150, fill = NA,
            color = alpha("firebrick", 0.3),
            linewidth = 0.5, linetype = "dashed") +
    geom_sf(data = ring_100, fill = NA,
            color = alpha("darkorange", 0.4),
            linewidth = 0.5, linetype = "dashed") +
    geom_sf(data = ring_50, fill = NA,
            color = alpha("steelblue", 0.5),
            linewidth = 0.5, linetype = "dashed") +
    
    # All fires in area (not Frenchglen's)
    geom_sf(data = frenchglen_area_fires %>%
              filter(!attr_IncidentName %in%
                       frenchglen_fires$attr_IncidentName),
            fill = alpha("gray60", 0.3), color = "gray50",
            linewidth = 0.1) +
    
    # Frenchglen's fires
    geom_sf(data = frenchglen_fires,
            fill = alpha("firebrick", 0.4), color = "darkred",
            linewidth = 0.2) +
    
    # Connector lines
    geom_segment(
      data = frenchglen_lines,
      aes(x = stn_lon, y = stn_lat,
          xend = fire_lon, yend = fire_lat),
      color = alpha("gold3", 0.4),
      linewidth = 0.4
    ) +
    
    # All stations in area
    geom_sf(data = frenchglen_area_stations,
            color = "gray40", size = 2, shape = 17) +
    
    # Frenchglen highlighted
    geom_sf(data = frenchglen,
            color = "black", size = 7, shape = 2) +
    geom_sf(data = frenchglen,
            color = "gold", size = 6.5, shape = 17) +
    
    # Ring labels
    annotate("text",
             x = st_coordinates(frenchglen)[1,1] + 0.05,
             y = st_bbox(ring_50)["ymax"] + 0.08,
             label = "50 km", color = "steelblue",
             size = 3, fontface = "bold") +
    annotate("text",
             x = st_coordinates(frenchglen)[1,1] + 0.05,
             y = st_bbox(ring_100)["ymax"] + 0.08,
             label = "100 km", color = "darkorange",
             size = 3, fontface = "bold") +
    annotate("text",
             x = st_coordinates(frenchglen)[1,1] + 0.05,
             y = st_bbox(ring_150)["ymax"] + 0.08,
             label = "150 km", color = "firebrick",
             size = 3, fontface = "bold") +
    
    # Fire labels
    ggrepel::geom_label_repel(
      data = fg_fire_labels,
      aes(x = lon, y = lat,
          label = paste0(attr_IncidentName, "\n",
                         scales::comma(round(attr_IncidentSize)), " ac\n",
                         round(dist_nearest_km), " km")),
      size               = 2.5,
      fontface           = "bold",
      fill               = alpha("white", 0.85),
      color              = "firebrick",
      label.size         = 0.2,
      box.padding        = unit(0.8, "lines"),
      min.segment.length = 0,
      segment.color      = "firebrick",
      segment.size       = 0.3,
      max.overlaps       = 15,
      seed               = 42,
      force              = 4
    ) +
    
    ggspatial::annotation_scale(
      location = "br", width_hint = 0.2, text_cex = 0.7
    ) +
    
    labs(
      title    = "Frenchglen Fire Guard Station \u2014 Coverage Zone",
      subtitle = paste0(
        "Population: ~12  |  ", nrow(frenchglen_fires),
        " fires as nearest station  |  ",
        scales::comma(sum(frenchglen_fires$attr_IncidentSize, na.rm = TRUE)),
        " acres in coverage zone\n",
        "Mean response distance: ",
        round(mean(frenchglen_fires$dist_nearest_km), 1),
        " km  |  Estimated response time: ",
        round(mean(frenchglen_fires$dist_nearest_km) / 60 * 56, 0),
        " minutes\n",
        "Backed by Frenchglen RFPA (Rangeland Fire Protection Association)"
      ),
      caption  = paste0(
        "Dashed rings at 50, 100, 150 km from station  |  ",
        "Red perimeters = fires where Frenchglen is nearest station  |  ",
        "Gold lines = station-to-fire connections"
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
      xlim = c(fg_bbox_expanded["xmin"], fg_bbox_expanded["xmax"]),
      ylim = c(fg_bbox_expanded["ymin"], fg_bbox_expanded["ymax"]),
      expand = FALSE
    )
  
} else {
  message("Frenchglen station or fires not found - skipping zoom map")
  or_frenchglen_zoom <- NULL
}

# =============================================================================
# SAVE ALL
# =============================================================================

message("Saving Oregon visuals...")

print(or_hero_map)
ggsave(paste0(wc_output_dir, "oregon_coverage_gap_",
              format(Sys.Date(), "%Y%m%d"), ".png"),
       plot = or_hero_map,
       width = 14, height = 10, dpi = 300, bg = "white")

print(or_comparison_bar)
ggsave(paste0(wc_output_dir, "oregon_comparison_bar_",
              format(Sys.Date(), "%Y%m%d"), ".png"),
       plot = or_comparison_bar,
       width = 10, height = 7, dpi = 300, bg = "white")

print(or_distance_hist)
ggsave(paste0(wc_output_dir, "oregon_distance_histogram_",
              format(Sys.Date(), "%Y%m%d"), ".png"),
       plot = or_distance_hist,
       width = 12, height = 7, dpi = 300, bg = "white")

if (!is.null(or_frenchglen_zoom)) {
  print(or_frenchglen_zoom)
  ggsave(paste0(wc_output_dir, "oregon_frenchglen_zoom_",
                format(Sys.Date(), "%Y%m%d"), ".png"),
         plot = or_frenchglen_zoom,
         width = 14, height = 12, dpi = 300, bg = "white")
}

# Copy to output/figures/
for (f in c("oregon_coverage_gap", "oregon_comparison_bar",
            "oregon_distance_histogram", "oregon_frenchglen_zoom")) {
  src <- paste0(wc_output_dir, f, "_",
                format(Sys.Date(), "%Y%m%d"), ".png")
  if (file.exists(src)) {
    file.copy(src, paste0("output/figures/", f, ".png"),
              overwrite = TRUE)
  }
}

cat("\n--- Oregon Deep Dive Visuals ---\n")
cat("1. oregon_coverage_gap      - Hero map with all fires\n")
cat("2. oregon_comparison_bar    - State comparison (the money chart)\n")
cat("3. oregon_distance_histogram - Distribution overlay\n")
if (!is.null(or_frenchglen_zoom)) {
  cat("4. oregon_frenchglen_zoom   - Frenchglen detail with rings\n")
}
cat("All saved to:", wc_output_dir, "\n")
cat("Copies in output/figures/\n")