-- legacy/bindings/lua/tests/main.lua

local lgx = require("binding")

print("Version:", lgx.version())

-- Usage example (make sure to set $LEGACY_HOME if necessary)
print("Running a COBOL refresh...")
local ok, log = pcall(lgx.refresh)
if ok then
    print("Refresh executed successfully!")
    else
        print("Warning/Error on refresh:", log)
        end

        print("Searching for a monthly series (6-month window)...")
        local series = lgx.monthly_series(6)

        for i, m in ipairs(series) do
            -- Convert cents to a display-ready dollar format.
            local balance_usd = m.balance_cents / 100.0
            print(string.format("Data: %04d/%02d | Monthly Balance: $%.2f | Entries: %d",
                                m.year, m.month, balance_usd, m.entries))
            end
