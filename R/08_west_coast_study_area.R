# =============================================================================
# 08_west_coast_study_area.R
# Load CA, OR, WA county and state boundaries from US Census
#
# Depends on: 01_setup.R, 07_west_coast_setup.R
# =============================================================================

message("Loading West Coast county and state boundaries...")

# County boundaries - all three states
# map_dfr applies the function to each state and row-binds results
westcoast_counties <- map_dfr(c("CA", "OR", "WA"), function(s) {
  counties(state = s, cb = TRUE) %>%
    st_transform(4326) %>%
    mutate(state_abbr = s)
})

# State boundaries
westcoast_states <- states(cb = TRUE) %>%
  filter(STUSPS %in% c("CA", "OR", "WA")) %>%
  st_transform(4326)

cat("Counties loaded:", nrow(westcoast_counties), "\n")
cat("States:         ", paste(westcoast_states$NAME, collapse = ", "), "\n")