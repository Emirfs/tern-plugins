--!strict
-- Depo kökünden: `lune run omp-usage/tests/run.luau` (lib/ modülleri ve blok uçtan uca).
local check = require("./check")
require("./test_usage")
require("./test_text")
require("./test_layout")
require("./test_host")
print(`all {check.count} checks passed`)
