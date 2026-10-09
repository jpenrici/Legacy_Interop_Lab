-- legacy/bindings/lua/src/bindings.lua

local core = require("lua_extender_core")
local M = {}

M.version = core.version

function M.strerror(status)
return core.strerror(status)
end

function M.refresh()
local status, log = core.refresh()
if status < 0 and status ~= 3 then -- Example treating LGX_WARN_REJECTED as OK
    error("COBOL refresh error (" .. status .. "): " .. core.strerror(status))
    end
    return true, log
    end

    function M.monthly_series(window)
    window = window or 12
    local status, result = core.monthly_series(window)
    if status ~= 0 then
        error("Error retrieving monthly series (" .. status .. "): " .. core.strerror(status))
        end
        return result
        end

        return M

