source("R/01_setup.R")
source("R/07_west_coast_setup.R")

baseline <- readRDS("C:/data/Shapefiles/WestCoast/westcoast_baseline_20260224.rds")
list2env(baseline, envir = .GlobalEnv)

cat("Ready:", nrow(fires_summary_df), "fires loaded\n")

# =============================================================================
# 18_oregon_natgeo.R
# Oregon wildfire response gap — National Geographic style layout
#
# Design notes:
#   - Yellow border bar (NatGeo signature)
#   - Warm parchment background
#   - Serif titles (Georgia or similar)
#   - Muted earth-tone color palette
#   - Inset map, scale bar, clean legend
#   - Callout boxes for key stats
#   - Dense but readable — information-rich like a magazine spread
#
# Outputs:
#   oregon_natgeo_YYYYMMDD.png
#
# Depends on: baseline RDS or scripts 07-11
# =============================================================================

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

# --- Detect nearest station column name -------------------------------------
stn_col <- grep("nearest_station", names(fires_wc_with_dist), value = TRUE)[1]

# =============================================================================
# DATA PREP
# =============================================================================

or_counties <- westcoast_counties %>%
  st_as_sf() %>%
  filter(STATEFP == "41") %>%
  st_transform(4326)

or_state <- westcoast_states %>%
  st_as_sf() %>%
  filter(STUSPS == "OR") %>%
  st_transform(4326)

or_fires <- fires_wc_with_dist %>%
  st_as_sf() %>%
  st_transform(4326) %>%
  filter(attr_POOState == "US-OR") %>%
  rename(nearest_station = !!sym(stn_col))

or_stations <- all_stations_wc_clean %>%
  st_as_sf() %>%
  st_transform(4326) %>%
  st_filter(or_state %>% st_buffer(0.1))

frenchglen <- or_stations %>%
  filter(grepl("Frenchglen", name, ignore.case = TRUE))

frenchglen_fires <- or_fires %>%
  filter(grepl("Frenchglen", nearest_station, ignore.case = TRUE))

or_county_stats <- fires_summary_df %>%
  filter(state == "Oregon") %>%
  group_by(county, fips) %>%
  summarise(
    n_fires     = n(),
    total_acres = sum(acres, na.rm = TRUE),
    mean_dist   = round(mean(dist_km), 1),
    median_dist = round(median(dist_km), 1),
    pct_over_50 = round(mean(dist_km > 50) * 100, 1),
    .groups     = "drop"
  )

or_map_data <- or_counties %>%
  left_join(or_county_stats, by = c("GEOID" = "fips")) %>%
  st_as_sf() %>%
  mutate(
    n_fires     = replace_na(n_fires, 0),
    total_acres = replace_na(total_acres, 0),
    has_fires   = n_fires > 0
  )

# Frenchglen connector lines
frenchglen_lines <- frenchglen_fires %>%
  arrange(desc(attr_IncidentSize)) %>%
  slice_head(n = 25) %>%
  st_centroid() %>%
  st_coordinates() %>%
  as_tibble() %>%
  mutate(
    stn_lon = st_coordinates(frenchglen)[1, 1],
    stn_lat = st_coordinates(frenchglen)[1, 2]
  ) %>%
  rename(fire_lon = X, fire_lat = Y)

# Key fires to label
or_key_spatial <- or_fires %>%
  filter(attr_IncidentSize >= 100000 | dist_nearest_km >= 100) %>%
  arrange(desc(attr_IncidentSize)) %>%
  slice_head(n = 6)

or_key_labels <- or_key_spatial %>%
  st_centroid() %>%
  st_coordinates() %>%
  as_tibble() %>%
  bind_cols(
    or_key_spatial %>%
      st_drop_geometry() %>%
      select(attr_IncidentName, attr_IncidentSize, dist_nearest_km)
  ) %>%
  rename(lon = X, lat = Y)

cat("Oregon data ready\n")
cat("Fires:", nrow(or_fires), "\n")
cat("Frenchglen fires:", nrow(frenchglen_fires), "\n")
cat("Key fires to label:", nrow(or_key_labels), "\n")

# =============================================================================
# NATGEO COLOR PALETTE + THEME
# =============================================================================

natgeo_yellow    <- "#FFCE00"
natgeo_yellow_dk <- "#E8B800"
parchment        <- "#F5F0E1"
parchment_dark   <- "#EDE5D0"
ink_black        <- "#1A1A1A"
ink_brown        <- "#3D2B1F"
ink_gray         <- "#5C5C5C"
water_blue       <- "#C6D8E0"

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

# =============================================================================
# MAIN MAP
# =============================================================================

message("Building NatGeo-style Oregon map...")

main_map <- ggplot() +
  
  # County choropleth
  geom_sf(data = or_map_data %>% filter(!has_fires),
          fill = parchment_dark, color = alpha(ink_brown, 0.3),
          linewidth = 0.15) +
  geom_sf(data = or_map_data %>% filter(has_fires),
          aes(fill = mean_dist),
          color = alpha(ink_brown, 0.3), linewidth = 0.15) +
  scale_fill_gradientn(
    colors   = earth_colors,
    name     = "Mean Distance to\nNearest Station (km)",
    limits   = c(0, 150),
    breaks   = c(0, 25, 50, 75, 100, 125),
    labels   = c("0", "25", "50", "75", "100", "125+"),
    oob      = scales::squish,
    na.value = parchment_dark
  ) +
  
  # Fire perimeters
  geom_sf(data = or_fires %>% filter(dist_nearest_km < 50),
          fill = alpha("#5B7E5E", 0.3), color = NA) +
  geom_sf(data = or_fires %>%
            filter(dist_nearest_km >= 50, dist_nearest_km < 100),
          fill = alpha("#B07D42", 0.4),
          color = alpha("#8B4513", 0.5), linewidth = 0.1) +
  geom_sf(data = or_fires %>% filter(dist_nearest_km >= 100),
          fill = alpha("#8B1A1A", 0.5),
          color = "#5C1A0A", linewidth = 0.15) +
  
  # State border
  geom_sf(data = or_state,
          fill = NA, color = ink_black, linewidth = 0.9) +
  
  # County borders
  geom_sf(data = or_counties,
          fill = NA, color = alpha(ink_brown, 0.25), linewidth = 0.1) +
  
  # Frenchglen connector lines
  geom_segment(
    data = frenchglen_lines,
    aes(x = stn_lon, y = stn_lat,
        xend = fire_lon, yend = fire_lat),
    color = alpha(natgeo_yellow_dk, 0.35),
    linewidth = 0.25
  ) +
  
  # Stations
  geom_sf(data = or_stations,
          color = alpha(ink_brown, 0.5), size = 0.8, shape = 17) +
  
  # Frenchglen
  geom_sf(data = frenchglen,
          color = ink_black, size = 5, shape = 2) +
  geom_sf(data = frenchglen,
          color = natgeo_yellow, size = 4.5, shape = 17) +
  
  # Frenchglen label
  ggrepel::geom_label_repel(
    data = frenchglen %>%
      st_coordinates() %>%
      as_tibble() %>%
      bind_cols(frenchglen %>% st_drop_geometry()),
    aes(x = X, y = Y,
        label = paste0("FRENCHGLEN FIRE GUARD STATION\n",
                       "Pop. ~12  |  148 fires  |  516,867 acres")),
    size               = 2.8,
    fontface           = "bold",
    family             = "serif",
    fill               = alpha(natgeo_yellow, 0.9),
    color              = ink_black,
    label.size         = 0.3,
    label.padding      = unit(0.25, "lines"),
    box.padding        = unit(1.5, "lines"),
    min.segment.length = 0,
    segment.color      = natgeo_yellow_dk,
    segment.size       = 0.5,
    seed               = 42,
    force              = 5
  ) +
  
  # Key fire labels
  ggrepel::geom_label_repel(
    data = or_key_labels,
    aes(x = lon, y = lat,
        label = paste0(toupper(attr_IncidentName), "\n",
                       scales::comma(round(attr_IncidentSize)), " ac  |  ",
                       round(dist_nearest_km), " km")),
    size               = 2.2,
    fontface           = "bold",
    family             = "serif",
    fill               = alpha(parchment, 0.9),
    color              = ink_brown,
    label.size         = 0.2,
    label.padding      = unit(0.15, "lines"),
    box.padding        = unit(0.7, "lines"),
    min.segment.length = 0,
    segment.color      = ink_brown,
    segment.size       = 0.25,
    max.overlaps       = 15,
    seed               = 42,
    force              = 5
  ) +
  
  # County names for worst counties
  geom_sf_text(
    data = or_map_data %>%
      filter(!is.na(median_dist)) %>%
      filter(median_dist >= 40 | total_acres >= 200000),
    aes(label = toupper(NAME)),
    size   = 2.5,
    family = "serif",
    fontface = "italic",
    color  = alpha(ink_brown, 0.6)
  ) +
  
  # Scale bar
  ggspatial::annotation_scale(
    location    = "bl",
    width_hint  = 0.18,
    text_cex    = 0.7,
    text_family = "serif",
    line_width  = 0.4,
    height      = unit(0.12, "cm"),
    pad_x       = unit(0.3, "cm"),
    pad_y       = unit(0.3, "cm")
  ) +
  
  theme_natgeo() +
  theme(
    legend.position = c(0.14, 0.32)
  ) +
  coord_sf(
    xlim   = c(-124.6, -116.5),
    ylim   = c(41.9, 46.3),
    expand = FALSE
  )

# =============================================================================
# INSET: Oregon location within US West Coast
# =============================================================================

usa_sf <- st_as_sf(maps::map("state", plot = FALSE, fill = TRUE)) %>%
  st_transform(4326)

wc_highlight <- usa_sf %>%
  filter(ID %in% c("california", "oregon", "washington"))

or_highlight <- usa_sf %>% filter(ID == "oregon")

inset_map <- ggplot() +
  geom_sf(data = usa_sf,
          fill = parchment_dark, color = "white", linewidth = 0.2) +
  geom_sf(data = wc_highlight,
          fill = alpha(ink_brown, 0.3), color = "white", linewidth = 0.3) +
  geom_sf(data = or_highlight,
          fill = natgeo_yellow, color = ink_black, linewidth = 0.5) +
  theme_void() +
  theme(
    plot.background = element_rect(fill = parchment,
                                   color = ink_brown, linewidth = 0.6)
  ) +
  coord_sf(xlim = c(-125, -104), ylim = c(31, 50))

# =============================================================================
# STAT CALLOUT BOXES
# =============================================================================

stat_comparison <- ggplot() +
  annotate("text", x = 0.5, y = 0.92,
           label = "FIRES BEYOND 50KM FROM NEAREST STATION",
           size = 3.5, fontface = "bold", family = "serif",
           color = ink_black) +
  annotate("text", x = 0.5, y = 0.72,
           label = "OREGON",
           size = 4.5, fontface = "bold", family = "serif",
           color = "#8B1A1A") +
  annotate("text", x = 0.5, y = 0.58,
           label = "30.1%",
           size = 9, fontface = "bold", family = "serif",
           color = "#8B1A1A") +
  annotate("text", x = 0.2, y = 0.35,
           label = "CALIFORNIA\n1.5%",
           size = 3.2, family = "serif", fontface = "bold",
           color = ink_gray, lineheight = 0.9) +
  annotate("text", x = 0.8, y = 0.35,
           label = "WASHINGTON\n1.9%",
           size = 3.2, family = "serif", fontface = "bold",
           color = ink_gray, lineheight = 0.9) +
  annotate("segment", x = 0.1, xend = 0.9, y = 0.45, yend = 0.45,
           color = alpha(ink_brown, 0.3), linewidth = 0.3) +
  annotate("text", x = 0.5, y = 0.15,
           label = "1,196 Oregon fires | 2020\u20132025",
           size = 2.5, family = "serif", color = ink_gray) +
  scale_x_continuous(limits = c(0, 1)) +
  scale_y_continuous(limits = c(0, 1)) +
  theme_void() +
  theme(
    plot.background = element_rect(fill = parchment,
                                   color = ink_brown, linewidth = 0.4),
    plot.margin = margin(6, 6, 6, 6)
  )

stat_frenchglen <- ggplot() +
  annotate("text", x = 0.5, y = 0.92,
           label = "FRENCHGLEN FIRE GUARD STATION",
           size = 3.2, fontface = "bold", family = "serif",
           color = ink_black) +
  annotate("text", x = 0.5, y = 0.80,
           label = "Harney County, Oregon",
           size = 2.5, family = "serif", color = ink_gray) +
  annotate("text", x = 0.08, y = 0.52, hjust = 0,
           label = paste0(
             "Population  . . . . . . . . . . . . ~12\n",
             "Fires as nearest station  . . . .  148\n",
             "Acres in coverage zone  . . 516,867\n",
             "Mean response distance  . . 107 km\n",
             "Est. response time  . . . . . . 114 min"
           ),
           size = 2.8, family = "serif", color = ink_brown,
           lineheight = 1.4) +
  annotate("text", x = 0.5, y = 0.10,
           label = "Backed by Frenchglen RFPA",
           size = 2.5, family = "serif", fontface = "italic",
           color = ink_gray) +
  scale_x_continuous(limits = c(0, 1)) +
  scale_y_continuous(limits = c(0, 1)) +
  theme_void() +
  theme(
    plot.background = element_rect(fill = parchment,
                                   color = ink_brown, linewidth = 0.4),
    plot.margin = margin(6, 6, 6, 6)
  )

coverage_stats <- fires_summary_df %>%
  filter(state == "Oregon") %>%
  mutate(
    cat = case_when(
      dist_km >= 100 ~ "EXTREME (100+ km)",
      dist_km >= 50  ~ "CRITICAL (50\u2013100 km)",
      dist_km >= 25  ~ "POOR (25\u201350 km)",
      dist_km >= 10  ~ "MODERATE (10\u201325 km)",
      TRUE           ~ "GOOD (<10 km)"
    )
  ) %>%
  count(cat) %>%
  mutate(pct = round(n / sum(n) * 100, 1)) %>%
  arrange(desc(n))

stat_coverage <- ggplot() +
  annotate("text", x = 0.5, y = 0.93,
           label = "OREGON COVERAGE BREAKDOWN",
           size = 3.2, fontface = "bold", family = "serif",
           color = ink_black) +
  annotate("text", x = 0.08, y = 0.55, hjust = 0,
           label = paste0(
             paste0(coverage_stats$cat, "  . . .  ",
                    coverage_stats$pct, "%"),
             collapse = "\n"
           ),
           size = 2.5, family = "serif", color = ink_brown,
           lineheight = 1.5) +
  annotate("text", x = 0.5, y = 0.10,
           label = "Perimeter edge to nearest station",
           size = 2.2, family = "serif", fontface = "italic",
           color = ink_gray) +
  scale_x_continuous(limits = c(0, 1)) +
  scale_y_continuous(limits = c(0, 1)) +
  theme_void() +
  theme(
    plot.background = element_rect(fill = parchment,
                                   color = ink_brown, linewidth = 0.4),
    plot.margin = margin(6, 6, 6, 6)
  )

# =============================================================================
# TITLE BAR
# =============================================================================

title_bar <- ggplot() +
  annotate("rect", xmin = 0, xmax = 1, ymin = 0, ymax = 1,
           fill = natgeo_yellow) +
  annotate("text", x = 0.03, y = 0.55,
           label = "OREGON\u2019S WILDFIRE RESPONSE GAP",
           size = 7, fontface = "bold", family = "serif",
           color = ink_black, hjust = 0) +
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
             "30% of Oregon\u2019s wildfires start more than 50 kilometers ",
             "from the nearest fire station \u2014 compared to less than 2% ",
             "in California and Washington. The gap is filled by Rangeland ",
             "Fire Protection Associations: legally recognized volunteer ",
             "networks of ranchers protecting 17.5 million acres."
           ),
           size = 3.5, family = "serif", color = ink_brown,
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
           fill = alpha("#5B7E5E", 0.5)) +
  annotate("text", x = 0.07, y = 0.5, label = "<50 km",
           size = 2.5, hjust = 0, family = "serif", color = ink_brown) +
  annotate("rect", xmin = 0.18, xmax = 0.21, ymin = 0.25, ymax = 0.75,
           fill = alpha("#B07D42", 0.6)) +
  annotate("text", x = 0.22, y = 0.5, label = "50\u2013100 km",
           size = 2.5, hjust = 0, family = "serif", color = ink_brown) +
  annotate("rect", xmin = 0.36, xmax = 0.39, ymin = 0.25, ymax = 0.75,
           fill = alpha("#8B1A1A", 0.7)) +
  annotate("text", x = 0.40, y = 0.5, label = ">100 km",
           size = 2.5, hjust = 0, family = "serif", color = ink_brown) +
  annotate("point", x = 0.55, y = 0.5, shape = 17,
           size = 2, color = ink_brown) +
  annotate("text", x = 0.57, y = 0.5, label = "Fire station",
           size = 2.5, hjust = 0, family = "serif", color = ink_brown) +
  annotate("point", x = 0.72, y = 0.5, shape = 17,
           size = 2.5, color = natgeo_yellow) +
  annotate("text", x = 0.74, y = 0.5, label = "Frenchglen station",
           size = 2.5, hjust = 0, family = "serif", color = ink_brown) +
  annotate("text", x = 0.5, y = 0.92,
           label = "FIRE PERIMETERS BY DISTANCE TO NEAREST STATION",
           size = 2.2, fontface = "bold", family = "serif",
           color = ink_brown) +
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
             "DATA: NIFC WFIGS fire perimeters + OpenStreetMap fire stations  |  ",
             "1,196 final perimeters 2020\u20132025  |  ",
             "Straight-line distances, perimeter edge to station  |  ",
             "Analysis by B. Groves  |  ",
             format(Sys.Date(), "%B %Y")
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
# COMPOSITE LAYOUT
# =============================================================================

message("Assembling NatGeo layout...")

# Right sidebar
right_sidebar <- cowplot::plot_grid(
  stat_comparison,
  stat_frenchglen,
  stat_coverage,
  inset_map,
  ncol = 1,
  rel_heights = c(0.28, 0.30, 0.25, 0.17)
)

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

out_file <- paste0(wc_output_dir, "oregon_natgeo_",
                   format(Sys.Date(), "%Y%m%d"), ".png")

ggsave(
  out_file,
  plot   = full_layout,
  width  = 18,
  height = 14,
  dpi    = 300,
  bg     = parchment
)

cat("NatGeo-style map saved to:", out_file, "\n")

file.copy(out_file, "output/figures/oregon_natgeo.png", overwrite = TRUE)
cat("Copied to output/figures/oregon_natgeo.png\n")