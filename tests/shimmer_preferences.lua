-- Checks shimmer strength selection and restart persistence without writing a real preference file.
local noop = require("tests.support").noop

local stored, captured
local env = setmetatable({
    LoopInGameThreadWithDelay = noop,
    RegisterInitGameStatePostHook = noop,
    print = noop,
    io = {
        open = function(_, mode)
            if mode == "r" and not stored then
                return nil
            end
            return {
                read = function()
                    return stored
                end,
                write = function(_, v)
                    stored = v
                    return true
                end,
                close = function()
                    return true
                end,
            }
        end,
    },
    loadfile = function(path)
        if path:match("config%.lua$") then
            return function()
                return {}
            end
        end
        return function(api)
            captured = api
        end
    end,
}, { __index = _G })
local function boot()
    assert(loadfile("Scripts" .. package.config:sub(1, 1) .. "main.lua", "t", env))()
end
boot()
assert(captured.shimmer == "low")
captured.setShimmer("medium")
assert(stored == "medium")
boot()
assert(captured.shimmer == "medium")
captured.setShimmer("high")
assert(stored == "high")
captured.setShimmer("low")
assert(stored == "low")
