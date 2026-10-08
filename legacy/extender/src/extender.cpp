// legacy/extender/src/extender.cpp

#include "extender.hpp"

#include <algorithm>
#include <array>
#include <limits.h> // PATH_MAX

namespace Legacy {

// The C++ codes must stay equal to the C bridge ones they mirror.
static_assert(static_cast<int>(StatusCode::NotFound) == LG_ERR_NOT_FOUND);
static_assert(static_cast<int>(StatusCode::SpawnFailed) == LG_ERR_SPAWN);
static_assert(static_cast<int>(StatusCode::SignalKilled) == LG_ERR_SIGNAL);
static_assert(static_cast<int>(StatusCode::DataError) == LG_ERR_DATA);
static_assert(static_cast<int>(StatusCode::ArgumentError) == LG_ERR_ARG);
static_assert(static_cast<int>(StatusCode::CapacityError) == LG_ERR_CAPACITY);
static_assert(static_cast<int>(StatusCode::HomeError) == LG_ERR_HOME);
static_assert(static_cast<int>(StatusCode::Unexpected) == LG_ERR_UNEXPECTED);
static_assert(static_cast<int>(StatusCode::WarningRejected) == LG_WARN_REJECTED);
static_assert(static_cast<int>(StatusCode::CobolOverflow) == LG_ERR_COBOL_OVERFLOW);

auto status_text(int status) noexcept -> const char*
{
    switch (status) {
    case LGX_ERR_NO_DATA:
        return "the ledger has no monthly records";
    case LGX_ERR_OVERFLOW:
        return "calculation would overflow a 64-bit integer";
    case LGX_ERR_RANGE:
        return "argument out of range";
    default:
        return lg_strerror(status);
    }
}

auto extender_version() -> std::string
{
    return LGX_VERSION;
}

auto Error::from_c(int status, std::string detail) -> Error
{
    return { static_cast<StatusCode>(status), status_text(status), std::move(detail) };
}

auto LedgerClient::version() -> std::string
{
    return lg_version();
}

auto LedgerClient::get_home() -> Result<std::string>
{
    std::array<char, PATH_MAX> buf {}; // the bridge resolves paths up to PATH_MAX
    const int res = lg_home(buf.data(), buf.size());
    if (res != LG_OK) {
        return std::unexpected(Error::from_c(res));
    }
    return std::string(buf.data());
}

auto LedgerClient::run_app() -> Result<RunReport>
{
    std::array<char, 4096> log_buf {};
    const int res = lg_run(log_buf.data(), log_buf.size());
    std::string log(log_buf.data());

    // 0 = ok, 3 = done with rejected lines. Everything else is a failure:
    // 1, 2, 4 are cobol_app errors, negative values are bridge errors.
    if (res != LG_OK && res != LG_WARN_REJECTED) {
        return std::unexpected(Error::from_c(res, std::move(log)));
    }
    return RunReport { static_cast<StatusCode>(res), std::move(log) };
}

auto LedgerClient::load_data(std::size_t initial_capacity) -> Result<Ledger>
{
    constexpr std::size_t kMaxRecords = std::size_t { 1 } << 20;
    std::size_t capacity = std::clamp<std::size_t>(initial_capacity, 1, kMaxRecords);

    for (;;) {
        Ledger out;
        out.records.resize(capacity);
        std::size_t count = 0;

        const int res = lg_load(out.records.data(), out.records.size(), &count, &out.summary);
        if (res == LG_ERR_CAPACITY && capacity < kMaxRecords) {
            capacity = std::min(capacity * 2, kMaxRecords); // too small: grow and retry
            continue;
        }
        if (res != LG_OK) {
            return std::unexpected(Error::from_c(res));
        }
        out.records.resize(count);
        out.status = out.summary.lines_rejected > 0 ? StatusCode::WarningRejected : StatusCode::Ok;
        return out;
    }
}

auto LedgerClient::process(std::size_t initial_capacity) -> Result<Ledger>
{
    auto run = run_app();
    if (!run) {
        return std::unexpected(std::move(run.error())); // never read a stale .dat
    }
    auto data = load_data(initial_capacity);
    if (!data) {
        return data;
    }
    data->log = std::move(run->log);
    data->status = run->status;
    return data;
}

auto LedgerClient::format_cents(std::int64_t cents) -> Result<std::string>
{
    std::array<char, 64> buf {};
    const int res = lg_format_cents(cents, buf.data(), buf.size());
    if (res != LG_OK) {
        return std::unexpected(Error::from_c(res));
    }
    return std::string(buf.data());
}

} // namespace Legacy
