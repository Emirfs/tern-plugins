--!strict
-- From the repository root: `lune run omp-usage/tests/run.luau` (lib/ modules and the block end to end).
local check = require("./check")
require("./test_usage")
require("./test_text")
require("./test_layout")
require("./test_host")
print(`all {check.count} checks passed`)
