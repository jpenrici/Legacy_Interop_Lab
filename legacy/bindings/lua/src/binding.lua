-- legacy/bindings/lua/src/bindings.lua
--
-- The Lua face of the COBOL ledger and its C++ extender (Lua 5.4).
--
--     local ledger = require("binding")
--
--     local result = ledger.refresh()                   -- runs the COBOL program once
--     for _, m in ipairs(ledger.monthly_series(3)) do   -- cheap, no process
--       print(m.period, ledger.format_cents(m.balance_cents), ledger.format_bp(m.growth_bp))
--     end
--
-- Money is integer cents and growth is integer basis points, as in the C ABI:
-- never floats. Failures are raised as a LedgerError object (see below); a
-- warning (some input lines were rejected) is not a failure.

local core = require("lua_extender_core")

local M = {}

-- Statuses of the C ABI (lgx_status) that are not errors.
local OK = 0
local WARN_REJECTED = 3

M.version = core.version
M.strerror = core.strerror

-- --------------------------------------------------------------- errors

-- Raised with error(); catch it with pcall and look at its fields:
--   status   the lgx_status number      message  its text
--   log      the output of the COBOL program (when that is what failed)
local LedgerError = {}
LedgerError.__index = LedgerError
LedgerError.__tostring = function(e)
return string.format("%s (status %d)", e.message, e.status)
end
M.LedgerError = LedgerError

local function raise(status, log)
local err = { status = status, message = core.strerror(status), log = log or "" }
error(setmetatable(err, LedgerError), 0)
end

-- --------------------------------------------------------------- queries

-- Runs the COBOL ledger. Returns { rejected = boolean, log = string }.
-- Raises LedgerError for anything but success or "some lines rejected".
function M.refresh()
local status, log = core.refresh()
if status ~= OK and status ~= WARN_REJECTED then
    raise(status, log)
    end
    return { rejected = (status == WARN_REJECTED), log = log }
    end

    -- The calendar series: months without entries are filled in. `window` is the
    -- moving-average length in months (1..120, default 3). Each month is a table
    -- with year, month, entries, debit_cents, credit_cents, balance_cents,
-- cumulative_cents, moving_avg_cents, window_used, growth_bp (nil when
-- undefined), and the helpers period ("2024-03") and is_gap.
function M.monthly_series(window)
local status, months = core.monthly_series(window or 3)
if status ~= OK then
    raise(status)
    end
    for _, m in ipairs(months) do
        m.period = string.format("%04d-%02d", m.year, m.month)
        m.is_gap = (m.entries == 0)
        end
        return months
        end

        -- ------------------------------------------------------------ formatting

        -- cents -> "-1,234.56". Integer arithmetic only.
        function M.format_cents(cents)
        local sign = cents < 0 and "-" or ""
        local magnitude = math.abs(cents)
        local whole = tostring(magnitude // 100):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
        return string.format("%s%s.%02d", sign, whole, magnitude % 100)
        end

        -- basis points -> "+116.48%", "-4.53%", "0.00%"; "" when undefined (nil).
        function M.format_bp(bp)
        if bp == nil then
            return ""
            end
            if bp == 0 then
                return "0.00%"
                end
                local magnitude = math.abs(bp)
                return string.format("%s%d.%02d%%", bp < 0 and "-" or "+", magnitude // 100, magnitude % 100)
                end

                return M
