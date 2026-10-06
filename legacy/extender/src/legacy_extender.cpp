// legacy/extender/src/legagy_wrapper.cpp

#include "legacy_extender.hpp"
#include <array>

namespace Legacy {

auto LedgerClient::version() -> std::string
{
    return lg_version();
}

auto LedgerClient::get_home() -> Result<std::string>
{
    std::array<char, 512> buf {};
    int res = lg_home(buf.data(), buf.size());
    if (res != LG_OK) {
        return std::unexpected(Error::from_c(res));
    }
    return std::string(buf.data());
}

auto LedgerClient::run_app() -> Result<std::string>
{
    std::array<char, 2048> log_buf {};
    int res = lg_run(log_buf.data(), log_buf.size());

    // Negative values are library errors; 0..4 are app exit/warning codes
    if (res < 0) {
        return std::unexpected(Error::from_c(res));
    }
    return std::string(log_buf.data());
}

auto LedgerClient::load_data(size_t max_records) -> Result<std::pair<std::vector<Record>, Summary>>
{
    std::vector<Record> records(max_records);
    Summary summary {};
    size_t count = 0;

    int res = lg_load(records.data(), records.size(), &count, &summary);
    if (res != LG_OK && res != LG_WARN_REJECTED) {
        return std::unexpected(Error::from_c(res));
    }

    records.resize(count);
    return std::pair { std::move(records), summary };
}

auto LedgerClient::process(size_t max_records) -> Result<std::pair<std::vector<Record>, Summary>>
{
    std::vector<Record> records(max_records);
    Summary summary {};
    size_t count = 0;
    std::array<char, 2048> log_buf {};

    int res = lg_process(records.data(), records.size(), &count, &summary, log_buf.data(), log_buf.size());
    if (res != LG_OK && res != LG_WARN_REJECTED) {
        return std::unexpected(Error::from_c(res));
    }

    records.resize(count);
    return std::pair { std::move(records), summary };
}

auto LedgerClient::format_cents(int64_t cents) -> Result<std::string>
{
    std::array<char, 64> buf {};
    int res = lg_format_cents(cents, buf.data(), buf.size());
    if (res != LG_OK) {
        return std::unexpected(Error::from_c(res));
    }
    return std::string(buf.data());
}

} // namespace Legacy
