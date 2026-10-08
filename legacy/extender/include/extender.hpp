// legacy/extender/include/extender.hpp
//
// C++23 core of the legacy extender. Two layers:
//
//   LedgerClient   talks to the C bridge (lib_c_api): runs the COBOL ledger
//                  and loads its output. I/O lives here only.
//   Analytics      pure calculations over the loaded records: calendar series,
//                  moving average, growth, yearly report, summary, projection.
//                  No I/O, so it is testable with synthetic data.
//
// The C ABI for other languages (extender.h) is a thin facade over
// this (src/ffi.cpp). Money is integer cents, growth is in basis points.

#pragma once

#include "bridge.h"
#include "extender.h"

#include <cstddef>
#include <cstdint>
#include <expected>
#include <span>
#include <string>
#include <vector>

namespace Legacy {

// Status codes; the numbers are the ones of the C ABI (lgx_status).
enum class StatusCode : int {
    Ok = LGX_OK,
    CobolInputError = LGX_ERR_COBOL_INPUT,
    CobolOutputError = LGX_ERR_COBOL_OUTPUT,
    WarningRejected = LGX_WARN_REJECTED,
    CobolOverflow = LGX_ERR_COBOL_OVERFLOW,
    NotFound = LGX_ERR_NOT_FOUND,
    SpawnFailed = LGX_ERR_SPAWN,
    SignalKilled = LGX_ERR_SIGNAL,
    DataError = LGX_ERR_DATA,
    ArgumentError = LGX_ERR_ARG,
    CapacityError = LGX_ERR_CAPACITY,
    HomeError = LGX_ERR_HOME,
    Unexpected = LGX_ERR_UNEXPECTED,
    NoData = LGX_ERR_NO_DATA,
    ArithmeticOverflow = LGX_ERR_OVERFLOW,
    OutOfRange = LGX_ERR_RANGE,
};

// Text for any status code (the C ABI and the bridge ones); never null.
[[nodiscard]] auto status_text(int status) noexcept -> const char*;

// Extender version (the bridge has its own: LedgerClient::version()).
[[nodiscard]] auto extender_version() -> std::string;

struct Error {
    StatusCode code;
    std::string message;
    std::string detail; // extra context, e.g. the cobol_app log

    [[nodiscard]] static auto from_c(int status, std::string detail = {}) -> Error;
};

template <typename T>
using Result = std::expected<T, Error>;

// Plain C structs shared with the C ABI: no conversion at the boundary.
using Record = lg_record;
using Summary = lg_summary;
using Month = lgx_month;
using Year = lgx_year;
using Stats = lgx_summary;
using Projection = lgx_projection;

// Outcome of running cobol_app: Ok, or WarningRejected (data is valid).
struct RunReport {
    StatusCode status;
    std::string log;
};

// Everything the COBOL ledger produced.
struct Ledger {
    std::vector<Record> records; // 'M' and 'Y' records, in file order
    Summary summary {}; // trailer: totals and line counts
    std::string log; // cobol_app output (empty when only loaded)
    StatusCode status { StatusCode::Ok }; // Ok or WarningRejected
};

class LedgerClient {
public:
    LedgerClient() = delete; // static utility class

    // Version of the C bridge library.
    [[nodiscard]] static auto version() -> std::string;

    // Resolved <home> directory of the legacy tree.
    [[nodiscard]] static auto get_home() -> Result<std::string>;

    // Runs cobol_app. Exit codes 1, 2 and 4 are errors (code + log in the
    // Error); only 0 and 3 (some lines rejected) succeed.
    [[nodiscard]] static auto run_app() -> Result<RunReport>;

    // Parses the .dat file. The record array grows until everything fits.
    [[nodiscard]] static auto load_data(std::size_t initial_capacity = 256) -> Result<Ledger>;

    // run_app() then load_data(); the .dat is only read when the run succeeded.
    [[nodiscard]] static auto process(std::size_t initial_capacity = 256) -> Result<Ledger>;

    // Formats cents as "-1234.56".
    [[nodiscard]] static auto format_cents(std::int64_t cents) -> Result<std::string>;
};

struct Report {
    std::vector<Month> months; // calendar series, gaps filled
    std::vector<Year> years;
    Stats stats {};
};

namespace Analytics {

    // (to - from) / |from| in basis points, rounded half away from zero.
    // from == 0 -> OutOfRange; int64 overflow -> ArithmeticOverflow.
    [[nodiscard]] auto growth_bp(std::int64_t from, std::int64_t to) -> Result<std::int64_t>;

    // Calendar series from the 'M' records: validates order and that the running
    // balance adds up, fills months without entries, and checks the totals against
    // the COBOL trailer. window: 1..LGX_MAX_WINDOW.
    [[nodiscard]] auto monthly_series(std::span<const Record> records, const Summary& trailer,
        int window) -> Result<std::vector<Month>>;

    // Yearly totals derived from the series and cross-checked against the 'Y'
    // records COBOL wrote.
    [[nodiscard]] auto yearly_report(std::span<const Month> series,
        std::span<const Record> records) -> Result<std::vector<Year>>;

    [[nodiscard]] auto summarize(std::span<const Month> series, const Summary& trailer) -> Result<Stats>;

    // Flat projection of the running balance (see extender.h).
    [[nodiscard]] auto project(std::span<const Month> series, int basis_months,
        int horizon) -> Result<std::vector<Projection>>;

    // All of the above for a loaded ledger.
    [[nodiscard]] auto analyze(const Ledger& ledger, int window = 3) -> Result<Report>;

} // namespace Analytics

} // namespace Legacy
