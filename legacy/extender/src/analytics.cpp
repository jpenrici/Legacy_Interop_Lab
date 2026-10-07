// legacy/extender/src/analytics.cpp
//
// Pure calculations over the records COBOL produced. No I/O.
// All arithmetic is on int64 cents with overflow checks: a result is either
// exact (rounded half away from zero where a division is involved) or an error.

#include "legacy_extender.hpp"

#include <algorithm>
#include <limits>

namespace Legacy::Analytics {

namespace {

    using i64 = std::int64_t;

    constexpr i64 kBasisPoints = 10000;

    auto fail(StatusCode code, const char* detail) -> std::unexpected<Error>
    {
        return std::unexpected(Error::from_c(static_cast<int>(code), detail));
    }

    // Checked arithmetic: true on success, false on int64 overflow.
    [[nodiscard]] bool checked_add(i64 a, i64 b, i64& r) noexcept { return !__builtin_add_overflow(a, b, &r); }
    [[nodiscard]] bool checked_sub(i64 a, i64 b, i64& r) noexcept { return !__builtin_sub_overflow(a, b, &r); }
    [[nodiscard]] bool checked_mul(i64 a, i64 b, i64& r) noexcept { return !__builtin_mul_overflow(a, b, &r); }

    // num / den (den > 0) rounded half away from zero. Cannot overflow: for
    // den >= 2 the quotient is at most half of the int64 range.
    [[nodiscard]] i64 div_round(i64 num, i64 den) noexcept
    {
        i64 q = num / den;
        const i64 r = num % den; // has the sign of num
        const i64 abs_r = r < 0 ? -r : r;
        if (abs_r >= den - abs_r) { // |remainder| >= den/2
            q += num < 0 ? -1 : 1;
        }
        return q;
    }

} // namespace

auto growth_bp(i64 from, i64 to) -> Result<i64>
{
    if (from == 0) {
        return fail(StatusCode::OutOfRange, "growth from zero is undefined");
    }
    if (from == std::numeric_limits<i64>::min()) {
        return fail(StatusCode::ArithmeticOverflow, "growth base out of range");
    }
    i64 diff = 0;
    i64 scaled = 0;
    if (!checked_sub(to, from, diff) || !checked_mul(diff, kBasisPoints, scaled)) {
        return fail(StatusCode::ArithmeticOverflow, "growth difference too large");
    }
    return div_round(scaled, from < 0 ? -from : from);
}

auto monthly_series(std::span<const Record> records, const Summary& trailer, int window)
    -> Result<std::vector<Month>>
{
    if (window < 1 || window > LGX_MAX_WINDOW) {
        return fail(StatusCode::OutOfRange, "window must be 1..120");
    }

    std::vector<Month> out;
    i64 sum_debit = 0;
    i64 sum_credit = 0;
    i64 sum_entries = 0;
    i64 prev_cum = 0;
    i64 prev_idx = -1; // year * 12 + (month - 1) of the previous month

    for (const Record& r : records) {
        if (r.kind != 'M') {
            continue;
        }
        if (r.month < 1 || r.month > 12 || r.year < 1) {
            return fail(StatusCode::DataError, "invalid year/month in a monthly record");
        }
        const i64 idx = i64 { r.year } * 12 + (r.month - 1);
        if (prev_idx >= 0 && idx <= prev_idx) {
            return fail(StatusCode::DataError, "monthly records out of chronological order");
        }

        // Months without entries do not exist in the COBOL output: fill them.
        for (i64 gap = prev_idx + 1; prev_idx >= 0 && gap < idx; ++gap) {
            Month m {};
            m.year = static_cast<std::int32_t>(gap / 12);
            m.month = static_cast<std::int32_t>(gap % 12 + 1);
            m.cumulative_cents = prev_cum; // nothing happened: the balance carries over
            out.push_back(m);
        }

        // Independent check of COBOL's running balance.
        i64 expected = 0;
        if (!checked_add(prev_cum, r.balance_cents, expected)) {
            return fail(StatusCode::ArithmeticOverflow, "running balance");
        }
        if (expected != r.cumulative_cents) {
            return fail(StatusCode::DataError, "running balance does not add up");
        }

        Month m {};
        m.year = r.year;
        m.month = r.month;
        m.debit_cents = r.debit_cents;
        m.credit_cents = r.credit_cents;
        m.balance_cents = r.balance_cents;
        m.cumulative_cents = r.cumulative_cents;
        m.entries = r.entries;
        out.push_back(m);

        if (!checked_add(sum_debit, r.debit_cents, sum_debit) || !checked_add(sum_credit, r.credit_cents, sum_credit)
            || !checked_add(sum_entries, r.entries, sum_entries)) {
            return fail(StatusCode::ArithmeticOverflow, "totals");
        }
        prev_cum = r.cumulative_cents;
        prev_idx = idx;
    }

    if (out.empty()) {
        return fail(StatusCode::NoData, "no monthly records");
    }
    if (sum_debit != trailer.debit_cents || sum_credit != trailer.credit_cents
        || sum_entries != trailer.lines_accepted || prev_cum != trailer.balance_cents) {
        return fail(StatusCode::DataError, "monthly records do not match the trailer totals");
    }

    // Moving average of the monthly balance, and month-over-month growth.
    const auto w = static_cast<std::size_t>(window);
    i64 window_sum = 0;
    for (std::size_t i = 0; i < out.size(); ++i) {
        if (!checked_add(window_sum, out[i].balance_cents, window_sum)
            || (i >= w && !checked_sub(window_sum, out[i - w].balance_cents, window_sum))) {
            return fail(StatusCode::ArithmeticOverflow, "moving average");
        }
        const std::size_t n = std::min(i + 1, w);
        out[i].moving_avg_cents = div_round(window_sum, static_cast<i64>(n));
        out[i].window_used = static_cast<std::int32_t>(n);

        if (i > 0 && out[i - 1].cumulative_cents != 0) {
            auto g = growth_bp(out[i - 1].cumulative_cents, out[i].cumulative_cents);
            if (!g) {
                return std::unexpected(std::move(g.error()));
            }
            out[i].growth_bp = *g;
            out[i].growth_valid = 1;
        }
    }
    return out;
}

auto yearly_report(std::span<const Month> series, std::span<const Record> records)
    -> Result<std::vector<Year>>
{
    std::vector<Year> out;
    for (const Month& m : series) {
        if (out.empty() || out.back().year != m.year) {
            Year y {};
            y.year = m.year;
            out.push_back(y);
        }
        Year& y = out.back();
        i64 entries = y.entries;
        if (!checked_add(y.debit_cents, m.debit_cents, y.debit_cents)
            || !checked_add(y.credit_cents, m.credit_cents, y.credit_cents)
            || !checked_add(entries, m.entries, entries)) {
            return fail(StatusCode::ArithmeticOverflow, "yearly totals");
        }
        y.entries = static_cast<std::int32_t>(entries);
        ++y.months;
        y.cumulative_cents = m.cumulative_cents;
    }

    for (std::size_t i = 0; i < out.size(); ++i) {
        Year& y = out[i];
        if (!checked_sub(y.debit_cents, y.credit_cents, y.balance_cents)) {
            return fail(StatusCode::ArithmeticOverflow, "yearly balance");
        }
        y.avg_monthly_cents = div_round(y.balance_cents, y.months);
        if (i > 0 && out[i - 1].balance_cents != 0) {
            auto g = growth_bp(out[i - 1].balance_cents, y.balance_cents);
            if (!g) {
                return std::unexpected(std::move(g.error()));
            }
            y.growth_bp = *g;
            y.growth_valid = 1;
        }
    }

    // What COBOL wrote for each year must equal what we derived.
    std::size_t year_records = 0;
    for (const Record& r : records) {
        if (r.kind != 'Y') {
            continue;
        }
        ++year_records;
        const auto it = std::ranges::find(out, r.year, &Year::year);
        if (it == out.end() || it->debit_cents != r.debit_cents || it->credit_cents != r.credit_cents
            || it->balance_cents != r.balance_cents || it->cumulative_cents != r.cumulative_cents
            || it->entries != r.entries) {
            return fail(StatusCode::DataError, "a yearly record differs from the monthly data");
        }
    }
    const auto active_years = std::ranges::count_if(out, [](const Year& y) { return y.entries > 0; });
    if (static_cast<std::size_t>(active_years) != year_records) {
        return fail(StatusCode::DataError, "yearly records do not match the years with entries");
    }
    return out;
}

auto summarize(std::span<const Month> series, const Summary& trailer) -> Result<Stats>
{
    if (series.empty()) {
        return fail(StatusCode::NoData, "no monthly records");
    }
    Stats s {};
    s.debit_cents = trailer.debit_cents;
    s.credit_cents = trailer.credit_cents;
    s.balance_cents = trailer.balance_cents;
    s.months = static_cast<std::int32_t>(series.size());
    s.lines_read = trailer.lines_read;
    s.lines_accepted = trailer.lines_accepted;
    s.lines_rejected = trailer.lines_rejected;

    s.best_cents = s.worst_cents = series.front().balance_cents;
    s.best_year = s.worst_year = series.front().year;
    s.best_month = s.worst_month = series.front().month;
    for (const Month& m : series) { // strict comparison: ties keep the earliest month
        if (m.entries > 0) {
            ++s.active_months;
        }
        if (m.balance_cents > s.best_cents) {
            s.best_cents = m.balance_cents;
            s.best_year = m.year;
            s.best_month = m.month;
        }
        if (m.balance_cents < s.worst_cents) {
            s.worst_cents = m.balance_cents;
            s.worst_year = m.year;
            s.worst_month = m.month;
        }
    }
    s.avg_monthly_cents = div_round(s.balance_cents, s.months);
    return s;
}

auto project(std::span<const Month> series, int basis_months, int horizon)
    -> Result<std::vector<Projection>>
{
    if (basis_months < 1 || basis_months > LGX_MAX_BASIS || horizon < 1 || horizon > LGX_MAX_HORIZON) {
        return fail(StatusCode::OutOfRange, "basis_months and horizon must be 1..120");
    }
    if (series.empty()) {
        return fail(StatusCode::NoData, "no monthly records");
    }

    const std::size_t n = std::min(static_cast<std::size_t>(basis_months), series.size());
    i64 sum = 0;
    for (const Month& m : series.last(n)) {
        if (!checked_add(sum, m.balance_cents, sum)) {
            return fail(StatusCode::ArithmeticOverflow, "projection basis");
        }
    }
    const i64 avg = div_round(sum, static_cast<i64>(n));

    std::vector<Projection> out;
    out.reserve(static_cast<std::size_t>(horizon));
    std::int32_t year = series.back().year;
    std::int32_t month = series.back().month;
    i64 cumulative = series.back().cumulative_cents;
    for (int h = 0; h < horizon; ++h) {
        if (++month > 12) {
            month = 1;
            ++year;
        }
        if (!checked_add(cumulative, avg, cumulative)) {
            return fail(StatusCode::ArithmeticOverflow, "projected balance");
        }
        out.push_back(Projection { avg, cumulative, year, month });
    }
    return out;
}

auto analyze(const Ledger& ledger, int window) -> Result<Report>
{
    auto months = monthly_series(ledger.records, ledger.summary, window);
    if (!months) {
        return std::unexpected(std::move(months.error()));
    }
    auto years = yearly_report(*months, ledger.records);
    if (!years) {
        return std::unexpected(std::move(years.error()));
    }
    auto stats = summarize(*months, ledger.summary);
    if (!stats) {
        return std::unexpected(std::move(stats.error()));
    }
    return Report { std::move(*months), std::move(*years), *stats };
}

} // namespace Legacy::Analytics
