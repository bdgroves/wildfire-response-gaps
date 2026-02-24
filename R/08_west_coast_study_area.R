# =============================================================================
# 08_west_coast_study_area.R
# Load CA, OR, WA county and state boundaries from US Census
#
# Depends on: 01_setup.R, 07_west_coast_setup.R
# =============================================================================

# Safety check - ensure dependencies are loaded
if (!exists("target_crs")) {
  message("Running dependency scripts first...")
  source("R/01_setup.R")
  source("R/07_west_coast_setup.R")
}

message("Loading West Coast county and state boundaries...")

westcoast_counties <- map(c("CA", "OR", "WA"), function(s) {
  counties(state = s, cb = TRUE) %>%
    st_transform(4326) %>%
    mutate(state_abbr = s)
}) %>%
  list_rbind()

westcoast_states <- states(cb = TRUE) %>%
  filter(STUSPS %in% c("CA", "OR", "WA")) %>%
  st_transform(4326)

cat("Counties loaded:", nrow(westcoast_counties), "\n")
cat("States:         ", paste(westcoast_states$NAME, collapse = ", "), "\n")