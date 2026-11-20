--!strict
-- The pane's user-facing text. Format strings use `string.format` placeholders;
-- the view and the tests read it as one flat table (`L`).

return {
	title = "omp usage",
	title_count = "omp usage · %d accounts",
	pct = "%d%%",
	-- window names; the short form is for the narrow list
	hours = "%d hours",
	days = "%d days",
	hours_short = "%dh",
	days_short = "%dd",
	-- time until the next refresh
	until_now = "now",
	until_lt_min = "<1m",
	until_min = "%dm",
	until_hour = "%dh%02dm",
	until_day = "%dd%02dh",
	-- aggregation
	unknown_account = "unknown account",
	issue_no_report = "no usage report",
	issue_disabled = "disabled: %s",
	-- omp run errors
	err_not_found = "omp is not on this machine's PATH",
	err_spawn = "omp failed to start: %s",
	err_none = "no result",
	err_timeout = "omp did not answer within 60 seconds",
	err_status = "omp exited with %d: %s",
	err_output = "unexpected omp output: %s",
	stale = "showing data from %s",
	-- view
	resets_credit = " +%d resets",
	total = "total",
	n_accounts = " %d accounts",
	col_account = "Account",
	col_resets = "resets",
	not_reported = "not reported",
	left = " left",
	resets_in = "resets in %s",
	total_left = " · total left %s",
	profiles = "%d profiles",
	refreshing = " · refreshing…",
	updated = " · updated %s",
	cached = " (cached)",
	hint = " · r: refresh",
	loading = "Reading usage from omp profiles…",
	no_profiles = "No omp profile found (`~/.omp/agent` or `~/.omp/profiles/*`). Press **r** to retry.",
	none_read = "No profile returned usage; details below. Press **r** to retry.",
	-- window half
	cmd_open = "Open omp usage (all accounts)",
	not_loaded = "The omp usage block is not loaded on this host",
	not_loaded_detail = "Check the plugin with `tern plugin list`.",
}
