# =============================================================================
# 02_study_area.R
# Define the Texas Panhandle study area using US Census county boundaries
# Depends on: 01_setup.R
# =============================================================================

# Download Texas county boundaries from US Census (simplified, cb = TRUE)
tx_counties <- counties(state = "TX", cb = TRUE) %>%
  st_transform(4326)

# The 26 counties that make up the Texas Panhandle
panhandle_county_names <- c(
  "Dallam",     "Sherman",    "Hansford",  "Ochiltree",    "Lipscomb",
  "Hartley",    "Moore",      "Hutchinson","Roberts",      "Hemphill",
  "Oldham",     "Potter",     "Carson",    "Gray",         "Wheeler",
  "Deaf Smith", "Randall",    "Armstrong", "Donley",       "Collingsworth",
  "Parmer",     "Castro",     "Swisher",   "Briscoe",      "Hall",
  "Childress"
)

panhandle_counties_sf <- tx_counties %>%
  filter(NAME %in% panhandle_county_names) %>%
  st_make_valid()

cat("Panhandle counties loaded:", nrow(panhandle_counties_sf), "of 26 expected\n")