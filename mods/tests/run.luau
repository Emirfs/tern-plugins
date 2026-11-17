--!strict
-- Depo kökünden: `lune run mods/tests/run.luau` (lib/ modülleri: doğrulama, CSS üretimi, panel).
local check = require("./check")
require("./test_schema")
require("./test_css")
require("./test_panel")
print(`all {check.count} checks passed`)
