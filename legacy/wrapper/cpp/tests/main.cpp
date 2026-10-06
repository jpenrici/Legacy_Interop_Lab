// legacy/wrapper/cpp/tests/main.cpp

#include "legacy_wrapper.hpp"
#include <iostream>

auto main() -> int
{
    std::cout << "API Version: " << Legacy::LedgerClient::version() << "\n";

    if (auto home_res = Legacy::LedgerClient::get_home(); home_res) {
        std::cout << "Home Directory: " << *home_res << "\n";
    } else {
        std::cerr << "Failed to get home: " << home_res.error().message << "\n";
        return 1;
    }

    // Process ledger using C++23 expected handling
    auto result = Legacy::LedgerClient::process();
    if (!result) {
        std::cerr << "Ledger processing failed: " << result.error().message << "\n";
        return 1;
    }

    // Unpack records and summary using structured bindings
    auto& [records, summary] = *result;

    std::cout << "Lines Read: " << summary.lines_read << "\n";
    std::cout << "Lines Accepted: " << summary.lines_accepted << "\n\n";

    std::cout << "--- Ledger Records ---\n";
    for (const auto& rec : records) {
        auto formatted_balance = Legacy::LedgerClient::format_cents(rec.balance_cents);
        std::string balance_str = formatted_balance ? *formatted_balance : "ERR";

        std::cout << "Year: " << rec.year
                  << " | Month: " << rec.month
                  << " | Balance: " << balance_str << "\n";
    }

    return 0;
}
