--!strict
-- From the repo root: `lune run git-graph/tests/run.luau` (lane layout, parsers, end to end with real git).
local check = require("./check")
require("./test_lanes")
require("./test_parse")
require("./test_layout")
require("./test_git")
require("./test_host")
print(`all {check.count} checks passed`)
