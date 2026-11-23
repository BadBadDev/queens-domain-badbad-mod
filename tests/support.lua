-- Minimal UE4SS stand-ins; each test gets its own hooks, module globals, and clock.
local support = {}
local scriptsDir = "Scripts" .. package.config:sub(1, 1)

function support.object(fields)
    local object = fields or {}
    object.IsValid = function()
        return true
    end
    object.GetAddress = function(self)
        return self
    end
    return object
end

function support.ref(value)
    return {
        get = function()
            return value
        end,
    }
end

function support.hudWidget(x)
    return support.object({
        RenderTransform = { Translation = { X = x, Y = 15 } },
        SetRenderTranslation = function(self, position)
            self.RenderTransform.Translation = position
        end,
    })
end

function support.noop() end

function support.new()
    local test = { now = 0, hooks = {} }
    test.env = setmetatable({
        FText = function(text)
            return text
        end,
        os = setmetatable({
            clock = function()
                return test.now
            end,
        }, { __index = os }),
    }, { __index = _G })
    test.api = {
        dir = scriptsDir,
        valid = function(object)
            return object and object:IsValid()
        end,
        hook = function(path, callback)
            test.hooks[path] = callback
            test.hooks[path:match(":([^:]+)$")] = callback
        end,
        reset = {},
        config = {},
    }
    function test.loadModule(name)
        return assert(loadfile(scriptsDir .. name .. ".lua", "t", test.env))(test.api)
    end
    return test
end

return support
