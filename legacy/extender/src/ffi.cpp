// legacy/extender/src/ffi.cpp
//
// C ABI facade (legacy_extender.h) over the C++ core. Rules of this file:
//   - nothing C++ crosses the boundary: only the plain lgx_* structs and ints
//   - no exception ever escapes (every entry point is noexcept + guarded)
//   - no global state: each query re-reads the .dat, so it is always coherent
//     with what legacy_app last wrote

#include "legacy_extender.hpp"

#include <algorithm>
#include <cstring>
#include <utility>

namespace {

using namespace Legacy;

// Runs fn(); an exception becomes LGX_ERR_UNEXPECTED instead of unwinding
// into the caller's language runtime.
template <typename Fn>
int guarded(Fn&& fn) noexcept
{
    try {
        return std::forward<Fn>(fn)();
    } catch (...) {
        return LGX_ERR_UNEXPECTED;
    }
}

int code_of(const Error& e) noexcept
{
    return static_cast<int>(e.code);
}

// Loads the .dat and derives the calendar report.
Result<Report> load_report(int window)
{
    auto ledger = LedgerClient::load_data();
    if (!ledger) {
        return std::unexpected(std::move(ledger.error()));
    }
    return Analytics::analyze(*ledger, window);
}

// Copies into the caller's array. *count is always the REQUIRED length, so a
// caller can size its array with max = 0 (LGX_ERR_CAPACITY) and call again.
template <typename T>
int copy_out(const std::vector<T>& src, T* out, std::size_t max, std::size_t* count) noexcept
{
    *count = src.size();
    if (src.size() > max) {
        return LGX_ERR_CAPACITY;
    }
    if (!src.empty()) {
        std::memcpy(out, src.data(), src.size() * sizeof(T));
    }
    return LGX_OK;
}

void copy_text(const std::string& text, char* dst, std::size_t size) noexcept
{
    if (!dst || size == 0) {
        return;
    }
    const std::size_t n = std::min(text.size(), size - 1);
    std::memcpy(dst, text.data(), n);
    dst[n] = '\0';
}

} // namespace

extern "C" {

const char* lgx_version(void)
{
    return LGX_VERSION;
}

const char* lgx_strerror(int status)
{
    return status_text(status);
}

int lgx_home(char* buf, size_t size)
{
    return guarded([&]() -> int {
        if (!buf || size == 0) {
            return LGX_ERR_ARG;
        }
        auto home = LedgerClient::get_home();
        if (!home) {
            return code_of(home.error());
        }
        if (home->size() >= size) {
            return LGX_ERR_CAPACITY;
        }
        copy_text(*home, buf, size);
        return LGX_OK;
    });
}

int lgx_refresh(char* log, size_t log_size)
{
    return guarded([&]() -> int {
        if (log && log_size) {
            log[0] = '\0';
        }
        auto run = LedgerClient::run_app();
        if (!run) {
            copy_text(run.error().detail, log, log_size);
            return code_of(run.error());
        }
        copy_text(run->log, log, log_size);
        return static_cast<int>(run->status);
    });
}

int lgx_monthly_series(int32_t window, lgx_month* out, size_t max, size_t* count)
{
    return guarded([&]() -> int {
        if (!count || (!out && max)) {
            return LGX_ERR_ARG;
        }
        *count = 0;
        auto report = load_report(window);
        if (!report) {
            return code_of(report.error());
        }
        return copy_out(report->months, out, max, count);
    });
}

int lgx_yearly_report(lgx_year* out, size_t max, size_t* count)
{
    return guarded([&]() -> int {
        if (!count || (!out && max)) {
            return LGX_ERR_ARG;
        }
        *count = 0;
        auto report = load_report(3); // the window does not affect yearly data
        if (!report) {
            return code_of(report.error());
        }
        return copy_out(report->years, out, max, count);
    });
}

int lgx_ledger_summary(lgx_summary* out)
{
    return guarded([&]() -> int {
        if (!out) {
            return LGX_ERR_ARG;
        }
        auto report = load_report(3);
        if (!report) {
            return code_of(report.error());
        }
        *out = report->stats;
        return LGX_OK;
    });
}

int lgx_project(int32_t basis_months, int32_t horizon, lgx_projection* out, size_t max, size_t* count)
{
    return guarded([&]() -> int {
        if (!count || (!out && max)) {
            return LGX_ERR_ARG;
        }
        *count = 0;
        auto report = load_report(3);
        if (!report) {
            return code_of(report.error());
        }
        auto projection = Analytics::project(report->months, basis_months, horizon);
        if (!projection) {
            return code_of(projection.error());
        }
        return copy_out(*projection, out, max, count);
    });
}

int lgx_growth_bp(int64_t from_cents, int64_t to_cents, int64_t* out_bp)
{
    return guarded([&]() -> int {
        if (!out_bp) {
            return LGX_ERR_ARG;
        }
        auto growth = Analytics::growth_bp(from_cents, to_cents);
        if (!growth) {
            return code_of(growth.error());
        }
        *out_bp = *growth;
        return LGX_OK;
    });
}

} // extern "C"
