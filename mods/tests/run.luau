--!strict
-- From the repo root: `lune run mods/tests/run.luau` (the lib/ modules: validation, CSS generation, panel).
local check = require("./check")
require("./test_schema")
require("./test_css")
require("./test_panel")
print(`all {check.count} checks passed`)
