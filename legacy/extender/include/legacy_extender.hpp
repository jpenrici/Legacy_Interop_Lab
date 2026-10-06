// legacy/extender/include/legagy_wrapper.hpp

#pragma once

#include "api.h"
#include <expected>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace Legacy {

// Status or error wrapper matching the C API status codes
enum class StatusCode {
    Ok = LG_OK,
    CobolInputError = LG_ERR_COBOL_INPUT,
    CobolOutputError = LG_ERR_COBOL_OUTPUT,
    WarningRejected = LG_WARN_REJECTED,
    CobolOverflow = LG_ERR_COBOL_OVERFLOW,
    NotFound = LG_ERR_NOT_FOUND,
    SpawnFailed = LG_ERR_SPAWN,
    SignalKilled = LG_ERR_SIGNAL,
    DataError = LG_ERR_DATA,
    ArgumentError = LG_ERR_ARG,
    CapacityError = LG_ERR_CAPACITY,
    HomeError = LG_ERR_HOME,
    Unexpected = LG_ERR_UNEXPECTED
};

// Error descriptor
struct Error {
    StatusCode code;
    std::string message;

    static Error from_c(int status_code)
    {
        return { static_cast<StatusCode>(status_code), lg_strerror(status_code) };
    }
};

using Record = lg_record;
using Summary = lg_summary;

template <typename T>
using Result = std::expected<T, Error>;

class LedgerClient {
public:
    LedgerClient() = delete; // Static utility class

    // Library version
    [[nodiscard]] static auto version() -> std::string;

    // Resolves and returns the environment <home> directory
    [[nodiscard]] static auto get_home() -> Result<std::string>;

    // Runs the legacy_app and captures its log output
    [[nodiscard]] static auto run_app() -> Result<std::string>;

    // Parses the .dat ledger file into modern containers
    [[nodiscard]] static auto load_data(size_t max_records = 1024) -> Result<std::pair<std::vector<Record>, Summary>>;

    // Runs process (run + load) sequentially
    [[nodiscard]] static auto process(size_t max_records = 1024) -> Result<std::pair<std::vector<Record>, Summary>>;

    // Formats raw ledger cents into a readable string (e.g., "-1234.56")
    [[nodiscard]] static auto format_cents(int64_t cents) -> Result<std::string>;

    // TODO – EXTEND OTHER FUNCTIONALITIES
};

} // namespace Legacy
