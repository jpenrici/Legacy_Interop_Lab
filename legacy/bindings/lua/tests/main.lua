-- legacy/bindings/lua/tests/main.lua
--
-- Smoke test of the Lua bindings: Lua 5.4, no GUI. Exit status 0 = everything ok.
--
--     lua5.4 bin/dist/lua/main.lua        (from any directory)
--
-- It runs the COBOL ledger and checks properties that hold for ANY data, so it
-- keeps working when the input CSV changes.

-- Find our own modules next to this script, whatever the working directory.
local here = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
package.cpath = here .. "/?.so;" .. package.cpath

local ledger = require("binding")

local checks, failures = 0, 0
local function check(condition, message)
checks = checks + 1
if not condition then
    failures = failures + 1
    print("  FAIL " .. message)
    end
    end

    print("Version:", ledger.version())

    -- 1. the COBOL ledger ------------------------------------------------------
    print("Running a COBOL refresh...")
    local ok, result = pcall(ledger.refresh)
    if not ok then
        print("Refresh failed: " .. tostring(result))
        if type(result) == "table" and result.log ~= "" then
            print(result.log)
            end
            os.exit(1)
            end
            print(result.rejected and "Refresh done (some input lines were rejected)" or "Refresh done")

            -- 2. the calendar series -----------------------------------------------------
            print("Reading the monthly series (6-month window)...")
            local months = ledger.monthly_series(6)
            check(#months >= 1, "the series is not empty")

            print("  month     balance      running  moving avg  growth")
            local running, previous = 0, nil
            for _, m in ipairs(months) do
                print(string.format("  %s %11s %12s %11s  %s", m.period, ledger.format_cents(m.balance_cents),
                                    ledger.format_cents(m.cumulative_cents), ledger.format_cents(m.moving_avg_cents), ledger.format_bp(m.growth_bp)))

                -- invariants of a calendar series
                running = running + m.balance_cents
                check(m.cumulative_cents == running, m.period .. ": running balance is the sum of the balances")
                check(m.balance_cents == m.debit_cents - m.credit_cents, m.period .. ": balance = debit - credit")
                check(m.window_used >= 1 and m.window_used <= 6, m.period .. ": moving-average window in range")
                if previous then
                    local expected = previous.year * 12 + previous.month
                    check(m.year * 12 + m.month - 1 == expected, m.period .. ": follows " .. previous.period .. " without holes")
                    else
                        check(m.growth_bp == nil, m.period .. ": no growth for the first month")
                        end
                        previous = m
                        end

                        -- 3. errors are objects ------------------------------------------------------
                        local failed, err = pcall(ledger.monthly_series, 0) -- a window of 0 is out of range
                        check(not failed, "window 0 is rejected")
                        check(type(err) == "table" and err.status == -22, "the error carries the status (-22, out of range)")
                        check(getmetatable(err) == ledger.LedgerError, "the error is a LedgerError")

                        -- 4. formatting needs no floats ---------------------------------------------
                        check(ledger.format_cents(-48935) == "-489.35", "format_cents(-48935)")
                        check(ledger.format_cents(1234567) == "12,345.67", "format_cents(1234567)")
                        check(ledger.format_bp(11648) == "+116.48%", "format_bp(11648)")
                        check(ledger.format_bp(nil) == "", "format_bp(nil)")

                        print(string.format("\n%d checks, %d failed", checks, failures))
                        os.exit(failures == 0 and 0 or 1)
