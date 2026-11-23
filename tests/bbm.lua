-- Run all automated Lua tests from the repository root: lua5.4 tests/bbm.lua
local suites = {
    "widescreen",
    "statusnames",
    "itemstats",
    "monsterhealthbar",
    "shimmer_preferences",
    "options",
}

for _, name in ipairs(suites) do
    dofile(table.concat({ "tests", name .. ".lua" }, package.config:sub(1, 1)))
    print("PASS: " .. name)
end
