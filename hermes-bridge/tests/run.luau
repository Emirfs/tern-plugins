--!strict
-- From the repo root: `lune run hermes-bridge/tests/run.luau` (lib/bridge, then window.luau against a stub).
local check = require("./check")
require("./test_bridge")
require("./test_window")
print(`all {check.count} checks passed`)
