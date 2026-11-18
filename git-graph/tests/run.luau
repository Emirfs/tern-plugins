--!strict
-- Depo kökünden: `lune run git-graph/tests/run.luau` (şerit yerleşimi, ayrıştırıcılar, gerçek git ile uçtan uca).
local check = require("./check")
require("./test_lanes")
require("./test_parse")
require("./test_layout")
require("./test_git")
require("./test_host")
print(`all {check.count} checks passed`)
