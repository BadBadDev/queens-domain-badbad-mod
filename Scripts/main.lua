-- UE4SS entry point: loads BBM modules, shares settings and binds hooks as game classes become available.
local dir = assert(debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])"))
local B = { dir = dir, warned = {}, reset = {} }

function B.log(s)
    print("[BBM] " .. s .. "\n")
end
function B.warn(key, s)
    if not B.warned[key] then
        B.warned[key] = true
        B.log(key .. ": " .. tostring(s))
    end
end

function B.valid(o)
    return o ~= nil and o:IsValid()
end
function B.lib(path)
    local o = StaticFindObject(path)
    assert(B.valid(o), path .. " not loaded")
    return o
end

function B.widget(owner, kind)
    local w = StaticConstructObject(B.lib("/Script/UMG." .. kind), owner.WidgetTree)
    assert(B.valid(w), "Could not create " .. kind)
    return w
end
if not LoopInGameThreadWithDelay then
    B.log("Requires UE4SS with LoopInGameThreadWithDelay; no features started.")
    return
end
local hooks = {}

function B.hook(path, fn)
    if not hooks[path] then
        hooks[path] = { callbacks = {} }
    end
    table.insert(hooks[path].callbacks, fn)
    return function()
        return hooks[path].bound == true
    end
end

local function bindAvailableGameHooks()
    for path, h in pairs(hooks) do
        if not h.bound then
            local ok, err = pcall(function()
                if not B.valid(StaticFindObject(path)) then
                    return
                end
                local function dispatchHookCallbacks(...)
                    for i, cb in ipairs(h.callbacks) do
                        local good, why = pcall(cb, ...)
                        if not good then
                            B.warn(path .. "#" .. i, why)
                        end
                    end
                end
                if path:sub(1, 8) == "/Script/" then
                    RegisterHook(path, function() end, dispatchHookCallbacks)
                else
                    RegisterHook(path, dispatchHookCallbacks)
                end
                h.bound = true
            end)
            if not ok then
                B.warn("bind " .. path, err)
            end
        end
    end
end
B.config = assert(loadfile(dir .. "config.lua"))()
assert(loadfile(dir .. "options.lua"))(B)

local optional = {
    graphics = "graphics",
    drag = "drag",
    statusnames = "statusNames",
    travelstride = "travelStride",
    quicksave = "quickSave",
}
for _, name in ipairs({
    "graphics",
    "monsterhealthbar",
    "drag",
    "shimmer",
    "videopreview",
    "iteminfo",
    "widescreen",
    "travelstride",
    "statusnames",
    "quicksave",
}) do
    if not optional[name] or B.config[optional[name]] then
        local ok, err = pcall(function()
            assert(loadfile(dir .. name .. ".lua"))(B)
        end)
        if not ok then
            B.warn("starting " .. name, err)
        end
    end
end

RegisterInitGameStatePostHook(function()
    for _, fn in ipairs(B.reset) do
        local ok, err = pcall(fn)
        if not ok then
            B.warn("world reset", err)
        end
    end
end)
LoopInGameThreadWithDelay(1000, bindAvailableGameHooks)
B.log("BadBad Mod loaded")
